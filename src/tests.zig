const std = @import("std");
const testing = std.testing;
const TrackedAllocator = @import("root.zig").TrackedAllocator;

test "test getCurrentUsage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 100);
    defer allocator.free(bytes);

    const bytes_1000 = try allocator.alloc(u8, 1000);
    defer allocator.free(bytes_1000);

    const bytes_10000 = try allocator.alloc(u8, 10000);
    defer allocator.free(bytes_10000);

    const present_bytes = tracked.getCurrentUsage();

    try testing.expectEqual(@as(usize, 11100), present_bytes);
}

test "test getBytesFreed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator);
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 100);
    defer allocator.free(bytes);

    try testing.expectEqual(@as(usize, 100), tracked.bytes_freed);
}
