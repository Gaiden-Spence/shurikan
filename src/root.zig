const std = @import("std");
const print = std.debug.print;

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

        print("The current usage of bytes are: {d}.\n", .{self.current_bytes});
        print("The total bytes allocated are: {d}.\n", .{self.total_bytes});
        print("The peak usage is {d}.\n", .{self.peak_usage});
        print("The total bytes that have been freed are: {d}.\n", .{self.bytes_freed});
        print("The total operations are: {d} allocs and {d} frees.\n", .{self.total_allocations});
        print("The active allocations are: {d}.\n", .{self.active_allocations});
        print("The average alloaction is {d:.2}.\n", .{avg_allocation});
    }
};
