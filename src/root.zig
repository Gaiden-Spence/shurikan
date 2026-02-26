const std = @import("std");

const histogram_tag_bucket = enum { Tiny, Small, Medium, Large, Giant };
const memory_log_info = struct { timestamp: i64, size: usize, location: usize };
const log = std.log.scoped(.memory_tracker);

///zero byte allocations will not be tracked
pub const TrackedAllocator = struct {
    parent: std.mem.Allocator,

    total_bytes: usize = 0, //total bytes used
    current_bytes: usize = 0,
    bytes_freed: usize = 0,
    peak_usage: usize = 0,

    total_allocations: usize = 0,
    total_deallocations: usize = 0,
    active_allocations: usize = 0,
    null_allocations: usize = 0,
    first_allocation_timestamp: i64 = 0, //unix timecode
    last_allocation_timestamp: i64 = 0,

    alloc_array_bucket: [5]usize = [_]usize{0} ** 5,
    bytes_array_bucket: [5]usize = [_]usize{0} ** 5,

    memory_logs: std.AutoHashMap(usize, memory_log_info),
    largest_allocation: ?memory_log_info = null,
    mutex: std.Thread.Mutex = .{},

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

    ///Allocates a new block of 'len' bytes with specified alignment.
    ///
    /// Args:
    ///     ctx: opaque pointer cast to '*TrackedAllocator'.
    ///     len: number of bytes to allocate
    ///     ptr_align: required alignment for the allocation.
    ///     ret_addr: return address used for debugging.
    ///
    /// Returns:
    ///     a pointer to the allocated memory, or null if the allocation failed
    ///
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const ptr = self.parent.rawAlloc(len, ptr_align, ret_addr);

        if (ptr == null) {
            self.null_allocations += 1;
            return null;
        }

        if (len == 0) {
            return ptr;
        }

        //Get track byteusage
        self.total_bytes += len;
        self.current_bytes += len;

        if (self.current_bytes > self.peak_usage) {
            self.peak_usage = self.current_bytes;
        }

        //Track allocations
        self.total_allocations += 1;
        self.active_allocations += 1;

        //Track Histogram bucket allocations and bytes
        switch (len) {
            1...64 => {
                self.alloc_array_bucket[0] += 1;
                self.bytes_array_bucket[0] += len;
            },

            65...256 => {
                self.alloc_array_bucket[1] += 1;
                self.bytes_array_bucket[1] += len;
            },
            257...4096 => {
                self.alloc_array_bucket[2] += 1;
                self.bytes_array_bucket[2] += len;
            },

            4097...65536 => {
                self.alloc_array_bucket[3] += 1;
                self.bytes_array_bucket[3] += len;
            },

            else => {
                self.alloc_array_bucket[4] += 1;
                self.bytes_array_bucket[4] += len;
            },
        }

        //Track Memory Logs{
        const addr = @intFromPtr(ptr.?);
        self.memory_logs.put(addr, .{ .timestamp = std.time.milliTimestamp(), .size = len, .location = ret_addr }) catch {};

        //Track timestamps
        if (self.total_allocations == 1) {
            self.first_allocation_timestamp = std.time.milliTimestamp();
        }

        self.last_allocation_timestamp = std.time.milliTimestamp();

        //Track largest allocation
        if (self.largest_allocation == null or len > self.largest_allocation.?.size) {
            self.largest_allocation = .{ .timestamp = std.time.milliTimestamp(), .size = len, .location = ret_addr };
        }

        return ptr;
    }

    /// Attempts to resize an existing allocation in place without moving memory.
    ///
    /// Args:
    ///   ctx: Opaque pointer cast to `*TrackedAllocator`.
    ///   buf: The existing allocation to resize.
    ///   buf_align: Alignment of the existing allocation.
    ///   new_len: The desired new size in bytes.
    ///   ret_addr: Return address used for debugging.
    ///
    /// Returns:
    ///   True if the resize succeeded, false otherwise.
    ///
    /// Notes:
    ///     Makes no tracking changes if the parent allocator cannot fulfill the resize.
    ///
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        if (buf.len == 0 and new_len == 0) {
            return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
        }

        const success = self.parent.rawResize(buf, buf_align, new_len, ret_addr);
        if (success) {
            const old_len = buf.len;
            const addr = @intFromPtr(buf.ptr);

            // Update byte tracking
            if (new_len > old_len) {
                const growth = new_len - old_len;
                self.total_bytes += growth;
                self.current_bytes += growth;
            } else {
                const shrinkage = old_len - new_len;
                self.current_bytes -= shrinkage;
            }

            // Update peak if needed
            if (self.current_bytes > self.peak_usage) {
                self.peak_usage = self.current_bytes;
            }

            // Update memory logs with new size
            if (self.memory_logs.getPtr(addr)) |info| {
                info.size = new_len;
            }
        }

        return success;
    }

    /// Frees an existing allocation and forwards it to the parent allocator.
    ///
    /// Args:
    ///   ctx: Opaque pointer cast to `*TrackedAllocator`.
    ///   buf: The allocation to free.
    ///   buf_align: Alignment of the allocation.
    ///   ret_addr: Return address used for debugging.
    ///
    /// Notes:
    ///     Zero byte slices are forwarded to the parent but not tracked.
    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        if (buf.len == 0) {
            self.parent.rawFree(buf, buf_align, ret_addr);
            return;
        }

        const addr = @intFromPtr(buf.ptr);
        const actual_size = if (self.memory_logs.get(addr)) |info| blk: {
            const current_time = std.time.milliTimestamp();
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
            break :blk info.size;
        } else buf.len;

        self.parent.rawFree(buf, buf_align, ret_addr);

        self.bytes_freed += actual_size;
        self.current_bytes -= actual_size;

        self.total_deallocations += 1;
        self.active_allocations -= 1;
    }
    /// Attempts to remap an existing allocation to a new size via the parent allocator,
    /// potentially moving memory to a new address.
    ///
    /// Args:
    ///   ctx: Opaque pointer cast to `*TrackedAllocator`.
    ///   buf: The existing allocation to remap.
    ///   buf_align: Alignment of the existing allocation.
    ///   new_len: The desired new size in bytes.
    ///   ret_addr: Return address used for debugging.
    ///
    /// Returns:
    ///   A pointer to the remapped memory, or null if the remap failed or is unsupported.
    ///
    /// Notes:
    /// Makes no tracking changes if the parent allocator does not support remap
    /// or cannot fulfill the request.
    ///
    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        const old_addr = @intFromPtr(buf.ptr);
        const old_len = buf.len;

        const new_ptr = self.parent.rawRemap(buf, buf_align, new_len, ret_addr);

        if (new_ptr) |p| {
            const new_addr = @intFromPtr(p);

            // Update byte tracking (similar to resize)
            if (new_len > old_len) {
                const growth = new_len - old_len;
                self.total_bytes += growth;
                self.current_bytes += growth;
            } else {
                const shrinkage = old_len - new_len;
                self.current_bytes -= shrinkage;
            }

            if (self.current_bytes > self.peak_usage) {
                self.peak_usage = self.current_bytes;
            }

            // Remove old tracking and add new (address may have changed)
            if (self.memory_logs.fetchRemove(old_addr)) |old_entry| {
                self.memory_logs.put(new_addr, .{
                    .timestamp = old_entry.value.timestamp, // Keep original timestamp
                    .size = new_len,
                    .location = ret_addr,
                }) catch {};
            }
        }

        return new_ptr;
    }
    ///This function gets how many bytes are in usage
    ///
    /// Args:
    ///     None
    ///
    /// Returns:
    ///     The number of bytes actively allocated and not freed.
    ///
    pub fn getCurrentUsage(self: *TrackedAllocator) usize {
        return self.current_bytes;
    }

    pub fn getTotalBytes(self: *TrackedAllocator) usize {
        return self.total_bytes;
    }

    pub fn getPeakUsage(self: *TrackedAllocator) usize {
        return self.peak_usage;
    }

    pub fn getBytesFreed(self: *TrackedAllocator) usize {
        return self.bytes_freed;
    }

    pub fn getTotalAllocAndFrees(self: *TrackedAllocator) struct { usize, usize } {
        return .{ self.total_allocations, self.total_deallocations };
    }

    pub fn getActiveAlloc(self: *TrackedAllocator) usize {
        return self.active_allocations;
    }

    pub fn getAvgAlloc(self: *TrackedAllocator) f64 {
        if (self.total_allocations == 0) return 0.0;
        const avg_alloc = @as(f64, @floatFromInt(self.total_bytes)) / @as(f64, @floatFromInt(self.total_allocations));
        return avg_alloc;
    }

    pub fn getFragRatio(self: *TrackedAllocator) f64 {
        if (self.total_bytes == 0) return 0.0;
        const frag_ratio = @as(f64, @floatFromInt(self.current_bytes)) / @as(f64, @floatFromInt(self.total_bytes));
        return frag_ratio;
    }

    pub fn getAvgLifeTime(self: *TrackedAllocator) f64 {
        if (self.lifetime_count > 0) {
            const avg_lifetime = @as(f64, @floatFromInt(self.total_lifetime)) / @as(f64, @floatFromInt(self.lifetime_count));
            return avg_lifetime;
        } else {
            return 0.0;
        }
    }

    pub fn getAllocBucket(self: *TrackedAllocator, index_bucket: usize) usize {
        return self.alloc_array_bucket[index_bucket];
    }

    pub fn getBytesBucket(self: *TrackedAllocator, bytes_bucket: usize) usize {
        return self.bytes_array_bucket[bytes_bucket];
    }

    pub fn makeAllocHistogram(self: *TrackedAllocator) void {
        for (std.enums.values(histogram_tag_bucket)) |bucket| {
            const array_bucket_str = @tagName(bucket);
            const array_bucket_index_val = @as(usize, @intFromEnum(bucket));

            const bucket_allocation = self.alloc_array_bucket[array_bucket_index_val];
            const bucket_pct = @as(f64, @floatFromInt(bucket_allocation)) / @as(f64, @floatFromInt(self.total_allocations)) * 100;

            log.info("The bucket {s} makes is {d:.4}% of allocations ", .{ array_bucket_str, bucket_pct });
            const bar_length = @as(usize, @intFromFloat((bucket_pct / 100) * 40));

            var bar_buffer: [40]u8 = undefined;
            @memset(&bar_buffer, '█');

            log.info("{s}\n", .{bar_buffer[0..bar_length]});
        }
    }

    pub fn makeByteHistogram(self: *TrackedAllocator) void {
        for (std.enums.values(histogram_tag_bucket)) |bucket| {
            const array_bucket_str = @tagName(bucket);
            const array_bucket_index_val = @as(usize, @intFromEnum(bucket));

            const bucket_allocation = self.bytes_array_bucket[array_bucket_index_val];
            const bucket_pct = @as(f64, @floatFromInt(bucket_allocation)) / @as(f64, @floatFromInt(self.total_bytes)) * 100;

            log.info("The bucket {s} makes up {d:.4}% for all bytes.", .{ array_bucket_str, bucket_pct });
            const bar_length = @as(usize, @intFromFloat((bucket_pct / 100) * 40));

            var bar_buffer: [40]u8 = undefined;
            @memset(&bar_buffer, '█');

            log.info("{s}\n", .{bar_buffer[0..bar_length]});
        }
    }

    pub fn getMemoryLogs(self: *TrackedAllocator) std.AutoHashMap(usize, memory_log_info) {
        return self.memory_logs;
    }

    pub fn getChurnRate(self: *TrackedAllocator) f64 {
        if (self.total_allocations == 0) return 0.0;
        const time_diff: i64 = self.last_allocation_timestamp - self.first_allocation_timestamp;
        const churn_rate = @as(f64, @floatFromInt(time_diff)) / @as(f64, @floatFromInt(self.total_allocations));
        return churn_rate;
    }

    pub fn getAvgDealloc(self: *TrackedAllocator) f64 {
        if (self.total_deallocations == 0) return 0.0;
        const avg_dealloc = @as(f64, @floatFromInt(self.bytes_freed)) / @as(f64, @floatFromInt(self.total_deallocations));
        return avg_dealloc;
    }

    pub fn getEfficiency(self: *TrackedAllocator) f64 {
        if (self.total_bytes == 0) return 0.0;
        const eff_ratio = @as(f64, @floatFromInt(self.bytes_freed)) / @as(f64, @floatFromInt(self.total_bytes)) * 100;
        return eff_ratio;
    }

    pub fn getTopAlloc(self: *TrackedAllocator) ?usize {
        if (self.largest_allocation) |top| {
            return top.size;
        }
        return null;
    }

    pub fn percentileMemory(self: *TrackedAllocator, pct: f64) !f64 {
        if (pct < 0 or pct > 100) {
            return error.InvalidPercentile;
        }

        const temp_alloc = self.parent;

        var percentile_array: std.ArrayList(usize) = .empty;
        defer percentile_array.deinit(temp_alloc);

        var mem_log_iterator = self.memory_logs.iterator();

        while (mem_log_iterator.next()) |entry| {
            const val_struct = entry.value_ptr.*;
            try percentile_array.append(temp_alloc, val_struct.size);
        }

        if (percentile_array.items.len == 0) {
            return error.EmptyArray;
        }

        const percentile = try percentileCalculation(self, percentile_array.items, pct);
        return percentile;
    }

    fn percentileCalculation(self: *TrackedAllocator, values: []usize, pct: f64) !f64 {
        const n = values.len;

        if (n == 0) {
            return error.EmptyArray;
        }

        if (n == 1) {
            return @floatFromInt(values[0]);
        }

        // Calculate the position in the sorted array
        const index = (pct / 100.0) * @as(f64, @floatFromInt(n - 1));

        if (index == @floor(index)) {
            // Exact index, no interpolation needed
            const k = @as(usize, @intFromFloat(index));
            const value = try quickSelect(self, values, k);
            return @floatFromInt(value);
        }

        // Need to interpolate between two values
        const lower_idx = @as(usize, @intFromFloat(@floor(index)));
        const upper_idx = lower_idx + 1;

        if (upper_idx >= n) {
            const value = try quickSelect(self, values, n - 1);
            return @floatFromInt(value);
        }

        // Get lower value
        const lower_value = try quickSelect(self, values, lower_idx);

        // Get upper value (upper_idx is adjacent to lower_idx after partitioning)
        const upper_value = try quickSelect(self, values, upper_idx);

        // Interpolate
        const weight = index - @floor(index);
        const interpolated = @as(f64, @floatFromInt(lower_value)) * (1.0 - weight) +
            @as(f64, @floatFromInt(upper_value)) * weight;

        return interpolated;
    }

    //helper function to sort array
    fn quickSelect(self: *TrackedAllocator, arr: []usize, k: usize) !usize {
        if (arr.len == 0) {
            return error.EmptyArray;
        }

        if (arr.len == 1) {
            return arr[0];
        }

        const temp_alloc = self.parent;

        var smaller: std.ArrayList(usize) = .empty;
        defer smaller.deinit(temp_alloc);
        try smaller.ensureTotalCapacity(temp_alloc, arr.len);

        var equal: std.ArrayList(usize) = .empty;
        defer equal.deinit(temp_alloc);
        try equal.ensureTotalCapacity(temp_alloc, arr.len);

        var larger: std.ArrayList(usize) = .empty;
        defer larger.deinit(temp_alloc);
        try larger.ensureTotalCapacity(temp_alloc, arr.len);

        // Choose pivot (middle element is often a good choice)
        const pivot = arr[arr.len / 2];

        for (arr) |x| {
            if (x < pivot) {
                smaller.appendAssumeCapacity(x);
            } else if (x == pivot) {
                equal.appendAssumeCapacity(x);
            } else {
                larger.appendAssumeCapacity(x);
            }
        }

        if (k < smaller.items.len) {
            return quickSelect(self, smaller.items, k);
        } else if (k < smaller.items.len + equal.items.len) {
            return pivot;
        } else {
            return quickSelect(self, larger.items, k - smaller.items.len - equal.items.len);
        }
    }

    pub fn logAllStats(self: *TrackedAllocator) !void {

        //Baseline Analytics
        log.info("The current usage of bytes are: {d}.\n", .{self.getCurrentUsage()});
        log.info("The total bytes allocated are: {d}.\n", .{self.getTotalBytes()});
        log.info("The peak usage is {d} bytes.\n", .{self.getPeakUsage()});
        log.info("The total bytes that have been freed are: {d}.\n", .{self.getBytesFreed()});
        log.info("The total operations are: {d} allocs and {d} frees.\n", .{self.getTotalAllocAndFrees()});
        log.info("The average alloaction is {d:.2}.\n", .{self.getAvgAlloc()});
        log.info("The fragmentation ratio is {d:.2}\n", .{self.getFragRatio()});
        log.info("The churn rate for your memory is {d} sec.\n", .{self.getChurnRate()});
        log.info("The avg dealloaction is {d:.2} bytes.\n", .{self.getAvgDealloc()});
        log.info("The efficiency ratio is {d:.4}.\n", .{self.getEfficiency()});
        log.info("The active allocations are: {d}.\n", .{self.active_allocations});

        if (self.getTopAlloc()) |top| {
            log.info("The largest allocation contains these attributes {any}\n", .{top});
        } else {
            log.info("No allocations tracked yet.\n", .{});
        }

        //Allocation Statistics
        log.info("\nLifetime Statistics:\n", .{});
        log.info("Average lifetime: {d:.2} seconds\n", .{self.getAvgLifeTime()});
        log.info("Shortest lifetime: {d} seconds\n", .{self.min_lifetime});
        log.info("Longest lifetime: {d} seconds\n", .{self.max_lifetime});

        //Allocation Histogram
        log.info("\nAlloc Histogram.\n", .{});
        makeAllocHistogram(self);

        log.info("\nBytes Histogram.\n", .{});
        makeByteHistogram(self);

        //Memory Logs
        var mem_log_iterator = self.memory_logs.iterator();

        while (mem_log_iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            const val_struct = entry.value_ptr.*;

            log.info("Memory Address: 0x{x}, Value: {any}\n", .{ key, val_struct });
        }
    }
};
