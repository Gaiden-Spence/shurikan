const std = @import("std");
const print = std.debug.print;

const histogram_tag_bucket = enum { Tiny, Small, Medium, Large, Giant };

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

    array_bucket: [5]usize = [_]usize{0} ** 5,

    pub fn init(parent: std.mem.Allocator) TrackedAllocator {
        return .{ .parent = parent };
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

        self.total_bytes += len;
        self.current_bytes += len;

        if (self.current_bytes > self.peak_usage) {
            self.peak_usage = self.current_bytes;
        }

        self.total_allocations += 1;
        self.active_allocations += 1;

        switch (len) {
            0...64 => self.array_bucket[0] += 1,
            65...256 => self.array_bucket[1] += 1,
            257...4096 => self.array_bucket[2] += 1,
            4097...65536 => self.array_bucket[3] += 1,
            else => self.array_bucket[4] += 1,
        }

        return self.parent.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
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

    pub fn printStats(self: *TrackedAllocator) !void {
        
        const avg_allocation = @as(f64, @floatFromInt(self.total_bytes)) / @as(f64, @floatFromInt(self.total_allocations));
        const frag_ratio = @as(f64, @floatFromInt(self.current_bytes)) / @as(f64, @floatFromInt(self.total_bytes));

        print("The current usage of bytes are: {d}.\n", .{self.current_bytes});
        print("The total bytes allocated are: {d}.\n", .{self.total_bytes});
        print("The peak usage is {d}.\n", .{self.peak_usage});
        print("The total bytes that have been freed are: {d}.\n", .{self.bytes_freed});
        print("The total operations are: {d} allocs and {d} frees.\n", .{self.total_allocations});
        print("The active allocations are: {d}.\n", .{self.active_allocations});
        print("The average alloaction is {d:.2}.\n", .{avg_allocation});
        print("The fragmentation ratio is {d:.2}\n", .{frag_ratio});

        for (std.enums.values(histogram_tag_bucket)) |bucket| {
            const array_bucket_str = @tagName(bucket);
            const array_bucket_index_val = @as(usize, @intFromEnum(bucket));
            
            const bucket_allocation = self.array_bucket[array_bucket_index_val];
            const bucket_pct = @as(f64, @floatFromInt(bucket_allocation)) / @as(f64, @floatFromInt(self.total_allocations)) * 100;
            
            print("The bucket {s} makes is {d:.4}% of allocations ", .{ array_bucket_str, bucket_pct });
            const bar_length = @as(usize, @intFromFloat((bucket_pct / 100) * 40));
            
            for (0..bar_length) |_| {
                print("█", .{});
            }
            print("\n", .{});
        }
    }
};
