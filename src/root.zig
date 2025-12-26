const std = @import("std");

const histogram_tag_bucket = enum { Tiny, Small, Medium, Large, Giant };
const memory_log_info = struct { timestamp: i64, size: usize, location: usize };
const log = std.log.scoped(.memory_tracker);

// Simple memory tracking allocator wrapper
pub const TrackedAllocator = struct {
    parent: std.mem.Allocator,

    total_bytes: usize = 0,
    current_bytes: usize = 0,
    bytes_freed: usize = 0,
    peak_usage: usize = 0,

    total_allocations: usize = 0,
    total_deallocations: usize = 0,
    active_allocations: usize = 0,
    null_allocations: usize = 0,
    first_allocation_timestamp: i64 = 0,
    last_allocation_timestamp: i64 = 0, //

    array_bucket: [5]usize = [_]usize{0} ** 5,

    memory_logs: std.AutoHashMap(usize, memory_log_info),
    total_lifetime: i64 = 0,
    lifetime_count: usize = 0,
    min_lifetime: i64 = 0,
    max_lifetime: i64 = 0,

    pub fn init(parent: std.mem.Allocator) TrackedAllocator {
        return .{
            .parent = parent,
            .memory_logs = std.AutoHashMap(usize, memory_log_info).init(parent),
        };
    }

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));

        //Get track byteusage
        self.total_bytes += len;
        self.current_bytes += len;

        if (self.current_bytes > self.peak_usage) {
            self.peak_usage = self.current_bytes;
        }

        //Track allocations
        self.total_allocations += 1;
        self.active_allocations += 1;

        //Track Histogram allocations
        switch (len) {
            0...64 => self.array_bucket[0] += 1,
            65...256 => self.array_bucket[1] += 1,
            257...4096 => self.array_bucket[2] += 1,
            4097...65536 => self.array_bucket[3] += 1,
            else => self.array_bucket[4] += 1,
        }

        //Track Memory Logs
        const ptr = self.parent.rawAlloc(len, ptr_align, ret_addr);
        if (ptr) |p| {
            const addr = @intFromPtr(p);
            self.memory_logs.put(addr, .{ .timestamp = std.time.milliTimeStamp(), .size = len, .location = ret_addr }) catch {};
        } else {
            self.null_allocations += 1;
        }

        //Track timestamps
        if (self.total_allocations == 1) {
            self.first_allocation_timestamp = std.time.milliTimeStamp();
        }

        self.last_allocation_timestamp = std.milliTimeStamp();

        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, buf_align, ret_addr);

        const addr = @intFromPtr(buf.ptr);
        if (self.memory_logs.get(addr)) |info| {
            const current_time = std.time.milliTimeStamp();
            const lifetime = current_time - info.timestamp;

            // Track lifetime statistics
            self.total_lifetime += lifetime;
            self.lifetime_count += 1;

            if (lifetime < self.min_lifetime or self.min_lifetime == 0) {
                self.min_lifetime = lifetime;
            }
            if (lifetime > self.max_lifetime) {
                self.max_lifetime = lifetime;
            }

            // Remove from tracking
            _ = self.memory_logs.remove(addr);
        }

        self.parent.rawFree(buf, buf_align, ret_addr);

        self.bytes_freed += buf.len;
        self.current_bytes -= buf.len;

        self.total_deallocations += 1;
        self.active_allocations -= 1;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(buf, buf_align, new_len, ret_addr);
    }

    pub fn getCurrentUsage(self: *TrackedAllocator) void {
        log.info("The current usage of bytes are: {d}.\n", .{self.current_bytes});
    }

    pub fn getTotalBytes(self: *TrackedAllocator) void {
        log.info("The total bytes allocated are: {d}.\n", .{self.total_bytes});
    }

    pub fn getPeakUsage(self: *TrackedAllocator) void {
        log.info("The peak usage is {d} bytes.\n", .{self.peak_usage});
    }

    pub fn getBytesFreed(self: *TrackedAllocator) void {
        log.info("The total bytes that have been freed are: {d}.\n", .{self.bytes_freed});
    }

    pub fn getTotalAllocAndFrees(self: *TrackedAllocator) void {
        log.info("The total operations are: {d} allocs and {d} frees.\n", .{ self.total_allocation, self.total_deallocations });
    }

    pub fn getActiveAlloc(self: *TrackedAllocator) void {
        log.info("The active allocations are: {d}.\n", .{self.active_allocations});
    }

    pub fn getAvgAlloc(self: *TrackedAllocator) void {
        const avg_allocation = @as(f64, @floatFromInt(self.total_bytes)) / @as(f64, @floatFromInt(self.total_allocations));
        log.info("The average alloaction is {d:.2}.\n", .{avg_allocation});
    }

    pub fn getFragRatio(self: *TrackedAllocator) void {
        const frag_ratio = @as(f64, @floatFromInt(self.current_bytes)) / @as(f64, @floatFromInt(self.total_bytes));
        log.info("The fragmentation ratio is {d:.2}\n", .{frag_ratio});
    }

    pub fn getLifeTimeStats(self: TrackedAllocator) void {
        if (self.lifetime_count > 0) {
            const avg_lifetime = @as(f64, @floatFromInt(self.total_lifetime)) / @as(f64, @floatFromInt(self.lifetime_count));
            log.info("\nLifetime Statistics:\n", .{});
            log.info("Average lifetime: {d:.2} seconds\n", .{avg_lifetime});
            log.info("Shortest lifetime: {d} seconds\n", .{self.min_lifetime});
            log.info("Longest lifetime: {d} seconds\n", .{self.max_lifetime});
        }
    }

    pub fn makeHistogram(self: *TrackedAllocator) void {
        for (std.enums.values(histogram_tag_bucket)) |bucket| {
            const array_bucket_str = @tagName(bucket);
            const array_bucket_index_val = @as(usize, @intFromEnum(bucket));

            const bucket_allocation = self.array_bucket[array_bucket_index_val];
            const bucket_pct = @as(f64, @floatFromInt(bucket_allocation)) / @as(f64, @floatFromInt(self.total_allocations)) * 100;

            log.info("The bucket {s} makes is {d:.4}% of allocations ", .{ array_bucket_str, bucket_pct });
            const bar_length = @as(usize, @intFromFloat((bucket_pct / 100) * 40));

            for (0..bar_length) |_| {
                log.info("█", .{});
            }
            log.info("\n", .{});
        }
    }

    pub fn getMemoryLogs(self: *TrackedAllocator) void {
        var mem_log_iterator = self.memory_logs.iterator();

        while (mem_log_iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            const val_struct = entry.value_ptr.*;

            log.info("Memory Address: 0x{x}, Value: {any}\n", .{ key, val_struct });
        }
    }

    pub fn getNullAlloc(self: *TrackedAllocator) void {
        log.info("The total number of null allocations are {d}.\n", .{self.null_allocations});
    }

    pub fn getChurnRate(self: *TrackedAllocator) void {
        const time_diff: i64 = self.last_allocation_timestamp - self.last_allocation_timestamp;
        const churn_rate = @as(f64, @floatFromInt(time_diff)) / @as(f64, @floatFromInt(self.total_allocations));

        log.info("The churn rate your memory is {d} sec.\n", .{churn_rate});
    }

    pub fn getAllocFailRt(self: *TrackedAllocator) void {
        const alloc_failure_pct = @as(f64, @floatFromInt(self.null_allocations)) / @as(f64, @floatFromInt(self.total_allocations)) * 100;
        log.info("The allocation failurerate is {d:.4}%.\n", .{alloc_failure_pct});
    }

    pub fn getAvgDealloc(self: *TrackedAllocator) void {
        const avg_dealloc = @as(f64, @floatFromInt(self.bytes_freed)) / @as(f64, @floatFromInt(self.total_deallocations)) * 100;
        log.info("The avg dealloaction is {d:.2} bytes.\n", .{avg_dealloc});
    }

    pub fn getEfficiency(self: *TrackedAllocator) void {
        const eff_ratio = @as(f64, @floatFromInt(self.bytes_freed)) / @as(f64, @floatFromInt(self.current_bytes));
        log.info("The efficiency ratio is {d:.4}.\n", .{eff_ratio});
    }

    pub fn logAllStats(self: *TrackedAllocator) !void {
        getCurrentUsage(self);
        getTotalBytes(self);
        getPeakUsage(self);
        getBytesFreed(self);
        getTotalAllocAndFrees(self);
        getActiveAlloc(self);
        getAvgAlloc(self);
        getFragRatio(self);
        getNullAlloc(self);

        getLifeTimeStats(self);

        makeHistogram(self);

        getChurnRate(self);
        getAllocFailRt(self);
    }
};
