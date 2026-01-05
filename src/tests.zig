const std = @import("std");
const testing = std.testing;
const TrackedAllocator = @import("root.zig").TrackedAllocator;

test "TrackedAllocator: test getCurrentUsage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 100);
    defer allocator.free(bytes);

    try testing.expectEqual(@as(usize, 100), tracked.current_bytes);

}
