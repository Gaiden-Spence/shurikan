const std = @import("std");
const testing = std.testing;
const TrackedAllocator = @import("root.zig").TrackedAllocator;

test "test FixedBufferAllocator out of memeory" {
    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var tracked_fba = TrackedAllocator.init(fba.allocator());
    defer tracked_fba.memory_logs.deinit();

    const fba_allocator = tracked_fba.allocator();

    const result = fba_allocator.alloc(u8, 10000);

    try testing.expectError(error.OutOfMemory, result);
}

test "test getCurrentUsage multiple allocators" {
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

test "getBytesFreed - no allocations returns zero" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(usize, 0), tracked.getBytesFreed());
}

test "test getBytesFreed multiple allocators" {
    //Test General Purpose ALlocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 10000);
    allocator.free(bytes);

    const present_freed_bytes = tracked.getBytesFreed();

    //Test Arena Allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var tracked_arena = TrackedAllocator.init(arena.allocator());
    const arena_allocator = tracked_arena.allocator();

    const arena_bytes = try arena_allocator.alloc(u8, 10000);
    arena_allocator.free(arena_bytes);

    const arena_bytes1 = try arena_allocator.alloc(u8, 1000);
    arena_allocator.free(arena_bytes1);

    const present_freed_bytes_arena = tracked_arena.getBytesFreed();

    // Test FixedBufferAllocator
    var buffer: [25000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var tracked_fba = TrackedAllocator.init(fba.allocator());
    defer tracked_fba.memory_logs.deinit();

    const fba_allocator = tracked_fba.allocator();

    const fba_bytes = try fba_allocator.alloc(u8, 10000);
    fba_allocator.free(fba_bytes);

    const fba_bytes1 = try fba_allocator.alloc(u8, 10024);
    fba_allocator.free(fba_bytes1);

    const freed_fba_bytes = tracked_fba.getCurrentUsage();

    try testing.expectEqual(@as(usize, 10000), present_freed_bytes);
    try testing.expectEqual(@as(usize, 11000), present_freed_bytes_arena);
    try testing.expectEqual(@as(usize, 0), freed_fba_bytes);
}

test "getBytesFreed - free in reverse order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const a = try allocator.alloc(u8, 100);
    const b = try allocator.alloc(u8, 200);
    const c = try allocator.alloc(u8, 300);

    allocator.free(c);
    allocator.free(b);
    allocator.free(a);

    try testing.expectEqual(@as(usize, 600), tracked.getBytesFreed());
}

test "test getTotalBytes total greater than current" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();
    const bytes = try allocator.alloc(u8, 100);
    allocator.free(bytes);

    const bytes1 = try allocator.alloc(u8, 1000);
    allocator.free(bytes1);

    const present_bytes = tracked.getCurrentUsage();
    const total_bytes = tracked.getTotalBytes();

    try testing.expectEqual(@as(usize, 0), present_bytes);
    try testing.expectEqual(@as(usize, 1100), total_bytes);
}
