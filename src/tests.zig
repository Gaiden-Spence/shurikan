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

test "resize tracking updates correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    var bytes = try allocator.alloc(u8, 100);
    const initial_total = tracked.getTotalBytes();

    if (allocator.resize(bytes, 200)) {
        bytes.len = 200;
        try testing.expectEqual(initial_total + 100, tracked.getTotalBytes());
    }

    allocator.free(bytes);
}

test "realloc updates memory logs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    var bytes = try allocator.alloc(u8, 100);
    const old_addr = @intFromPtr(bytes.ptr);

    bytes = try allocator.realloc(bytes, 200);
    const new_addr = @intFromPtr(bytes.ptr);

    if (tracked.memory_logs.get(new_addr)) |info| {
        try testing.expectEqual(@as(usize, 200), info.size);
    } else {
        try testing.expect(false);
    }

    if (old_addr != new_addr) {
        try testing.expect(tracked.memory_logs.get(old_addr) == null);
    }

    allocator.free(bytes);
}

test "realloc tracking shrinks correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    var bytes = try allocator.alloc(u8, 1000);
    const initial_current = tracked.getCurrentUsage();

    bytes = try allocator.realloc(bytes, 100);

    try testing.expectEqual(initial_current - 900, tracked.getCurrentUsage());

    allocator.free(bytes);
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

    try testing.expect(total_bytes > present_bytes);
}

test "test getTotalBytes initial case 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(usize, 0), tracked.getTotalBytes());
}

test "getPeakUsage - no peak returns 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(usize, 0), tracked.getPeakUsage());
}

test "getPeakUsage - multiple peaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    for (0..10000) |i| {
        const bytes = try allocator.alloc(u8, i);
        allocator.free(bytes);
    }

    try testing.expectEqual(@as(usize, 9999), tracked.getPeakUsage());
}

test "getTotalAllocAndFrees are 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const frees_and_allocs = tracked.getTotalAllocAndFrees();

    try testing.expectEqual(@as(usize, 0), frees_and_allocs[0]);
    try testing.expectEqual(@as(usize, 0), frees_and_allocs[1]);
}

test "getTotalAllocAndFrees single allocation and free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_10000 = try allocator.alloc(u8, 10000);
    allocator.free(bytes_10000);

    const frees_and_allocs_single = tracked.getTotalAllocAndFrees();

    try testing.expectEqual(@as(usize, 1), frees_and_allocs_single[0]);
    try testing.expectEqual(@as(usize, 1), frees_and_allocs_single[1]);
}

test "getTotalAllocAndFrees multiple alloc and frees" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    for (0..10000) |i| {
        const bytes_var = try allocator.alloc(u8, i);
        allocator.free(bytes_var);
    }

    const frees_and_allocs = tracked.getTotalAllocAndFrees();

    try testing.expectEqual(@as(usize, 9999), frees_and_allocs[0]);
    try testing.expectEqual(@as(usize, 9999), frees_and_allocs[1]);
}

test "getTotalAllocAndFrees frees occur end of scope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const a = try allocator.alloc(u8, 100);
    const b = try allocator.alloc(u8, 200);
    defer allocator.free(b);

    allocator.free(a);

    const result = tracked.getTotalAllocAndFrees();
    try testing.expectEqual(@as(usize, 2), result[0]);
    try testing.expectEqual(@as(usize, 1), result[1]);
}
