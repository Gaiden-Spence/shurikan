const std = @import("std");
const testing = std.testing;
const TrackedAllocator = @import("root.zig").TrackedAllocator;

test "test getCurrentUsage" {
    //Test GPA
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

    //Test Arena Allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var tracked_arena = TrackedAllocator.init(arena.allocator());
    const arena_allocator = tracked_arena.allocator();

    const arena_bytes = try arena_allocator.alloc(u8, 100);
    defer arena_allocator.free(arena_bytes);

    const present_arena_bytes = tracked_arena.getCurrentUsage();

    //Test Fixed Buffer Allocator
    //Test FixedBufferAllocator
    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var tracked_fba = TrackedAllocator.init(fba.allocator());
    defer tracked_fba.memory_logs.deinit();

    const fba_allocator = tracked_fba.allocator();

    const fba_bytes = try fba_allocator.alloc(u8, 100);
    defer fba_allocator.free(fba_bytes);

    const present_fba_bytes = tracked_fba.getCurrentUsage();

    try testing.expectEqual(@as(usize, 100), present_fba_bytes);
    try testing.expectEqual(@as(usize, 100), present_arena_bytes);
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
