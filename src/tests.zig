const std = @import("std");
const testing = std.testing;
const TrackedAllocator = @import("root.zig").TrackedAllocator;

test "zero byte allocation - not tracked" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const zero_bytes = try allocator.alloc(u8, 0);
    defer allocator.free(zero_bytes);

    // Should not be tracked
    try testing.expectEqual(@as(usize, 0), tracked.total_allocations);
    try testing.expectEqual(@as(usize, 0), tracked.total_bytes);
    try testing.expectEqual(@as(usize, 0), tracked.active_allocations);
}

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

test "getTotalAllocAndFrees frees defered" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_100 = try allocator.alloc(u8, 100);
    const bytes_200 = try allocator.alloc(u8, 200);
    defer allocator.free(bytes_200);

    allocator.free(bytes_100);

    const result = tracked.getTotalAllocAndFrees();
    try testing.expectEqual(@as(usize, 2), result[0]);
    try testing.expectEqual(@as(usize, 1), result[1]);
}

test "getActiveAlloc initially 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(usize, 0), tracked.getActiveAlloc());
}

test "getActiveAlloc - multiple allocations no frees" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_100 = try allocator.alloc(u8, 100);
    const bytes_200 = try allocator.alloc(u8, 200);
    const bytes_300 = try allocator.alloc(u8, 300);
    defer allocator.free(bytes_100);
    defer allocator.free(bytes_200);
    defer allocator.free(bytes_300);

    try testing.expectEqual(@as(usize, 3), tracked.getActiveAlloc());
}

test "getActiveAlloc - some allocations freed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_100 = try allocator.alloc(u8, 100);
    const bytes_200 = try allocator.alloc(u8, 200);
    const bytes_300 = try allocator.alloc(u8, 300);

    allocator.free(bytes_100);
    allocator.free(bytes_200);
    defer allocator.free(bytes_300);

    try testing.expectEqual(@as(usize, 1), tracked.getActiveAlloc());
}

test "getActiveAlloc - all allocations freed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const a = try allocator.alloc(u8, 100);
    const b = try allocator.alloc(u8, 200);

    allocator.free(a);
    allocator.free(b);

    try testing.expectEqual(@as(usize, 0), tracked.getActiveAlloc());
}

test "getAvgAlloc initially 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(f64, 0.0), tracked.getAvgAlloc());
}

test "getAvgAlloc single allocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_100 = try allocator.alloc(u8, 100);
    allocator.free(bytes_100);

    const avg_alloc = tracked.getAvgAlloc();

    try testing.expectEqual(@as(f64, 100.0), avg_alloc);
}

test "zero byte allocation - does not affect average" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const a = try allocator.alloc(u8, 100);
    const b = try allocator.alloc(u8, 200);
    const zero = try allocator.alloc(u8, 0);

    defer allocator.free(a);
    defer allocator.free(b);
    defer allocator.free(zero);

    // Average should be (100 + 200) / 2 = 150, not affected by 0-byte alloc
    try testing.expectEqual(@as(f64, 150.0), tracked.getAvgAlloc());
    try testing.expectEqual(@as(usize, 2), tracked.total_allocations);
}

test "getAvgAlloc - various allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var total_bytes: usize = 0;
    var allocations: std.ArrayList([]u8) = .empty;
    defer {
        for (allocations.items) |bytes| {
            allocator.free(bytes);
        }
        allocations.deinit(gpa.allocator());
    }

    for (0..10000) |_| {
        const size = random.intRangeAtMost(usize, 1, 10000);
        const bytes = try allocator.alloc(u8, size);
        try allocations.append(gpa.allocator(), bytes);
        total_bytes += size;
    }

    const expected_avg = @as(f64, @floatFromInt(total_bytes)) / 10000.0;
    const actual_avg = tracked.getAvgAlloc();

    try testing.expectApproxEqRel(expected_avg, actual_avg, 0.0001);
}

test "getFragRatio initially 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(f64, 0), tracked.getFragRatio());
}

test "getFragRatio defered single allocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_100 = try allocator.alloc(u8, 100);
    defer allocator.free(bytes_100);

    try testing.expectEqual(@as(f64, 1.0), tracked.getFragRatio());
}

test "getFragRatio defered multiple allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_100 = try allocator.alloc(u8, 100);
    const bytes_1000 = try allocator.alloc(u8, 1000);
    const bytes_5000 = try allocator.alloc(u8, 5000);
    const bytes_10000 = try allocator.alloc(u8, 10000);

    allocator.free(bytes_100);
    allocator.free(bytes_5000);
    defer allocator.free(bytes_10000);
    defer allocator.free(bytes_1000);

    const expected_ratio = @as(f64, 11000.0 / 16100.0);

    try testing.expectApproxEqRel(expected_ratio, tracked.getFragRatio(), 0.0001);
}

test "getAvgLifeTime - no deallocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 100);
    defer allocator.free(bytes);

    try testing.expectEqual(@as(f64, 0.0), tracked.getAvgLifeTime());
}

test "getAvgLifeTime - single allocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 100);
    std.Thread.sleep(100 * std.time.ns_per_ms);
    allocator.free(bytes);

    const avg_lifetime = tracked.getAvgLifeTime();

    // Should be at least 100ms (accounting for some overhead)
    try testing.expect(avg_lifetime >= 100.0);
}

test "getAvgLifeTime - multiple allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const a = try allocator.alloc(u8, 100);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    allocator.free(a);

    const b = try allocator.alloc(u8, 200);
    std.Thread.sleep(150 * std.time.ns_per_ms);
    allocator.free(b);

    const avg_lifetime = tracked.getAvgLifeTime();

    // Average should be around (50 + 150) / 2 = 100ms
    try testing.expect(avg_lifetime >= 100.0);
    try testing.expect(avg_lifetime <= 110.0); // Small tolerance for overhead
}

test "getAllocBucket initial values 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(usize, 0), tracked.getAllocBucket(0));
    try testing.expectEqual(@as(usize, 0), tracked.getAllocBucket(1));
    try testing.expectEqual(@as(usize, 0), tracked.getAllocBucket(2));
    try testing.expectEqual(@as(usize, 0), tracked.getAllocBucket(3));
    try testing.expectEqual(@as(usize, 0), tracked.getAllocBucket(4));
}

test "getAllocBucket multiple allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    for (0..1000) |_| {
        const bytes_tiny = try allocator.alloc(u8, 2);
        const bytes_small = try allocator.alloc(u8, 100);
        const bytes_medium = try allocator.alloc(u8, 1000);
        const bytes_large = try allocator.alloc(u8, 5000);
        const bytes_giant = try allocator.alloc(u8, 70000);

        allocator.free(bytes_tiny);
        allocator.free(bytes_small);
        allocator.free(bytes_medium);
        allocator.free(bytes_large);
        allocator.free(bytes_giant);
    }

    try testing.expectEqual(@as(usize, 1000), tracked.getAllocBucket(0));
    try testing.expectEqual(@as(usize, 1000), tracked.getAllocBucket(1));
    try testing.expectEqual(@as(usize, 1000), tracked.getAllocBucket(2));
    try testing.expectEqual(@as(usize, 1000), tracked.getAllocBucket(3));
    try testing.expectEqual(@as(usize, 1000), tracked.getAllocBucket(4));
}

test "getAllocBucket boundary allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_tiny_rb = try allocator.alloc(u8, 64);
    const bytes_small_rb = try allocator.alloc(u8, 256);
    const bytes_medium_rb = try allocator.alloc(u8, 4096);
    const bytes_large_rb = try allocator.alloc(u8, 65536);
    const bytes_giant_rb = try allocator.alloc(u8, 65537);

    const bytes_tiny_lb = try allocator.alloc(u8, 1);
    const bytes_small_lb = try allocator.alloc(u8, 65);
    const bytes_medium_lb = try allocator.alloc(u8, 257);
    const bytes_large_lb = try allocator.alloc(u8, 4097);

    allocator.free(bytes_tiny_rb);
    allocator.free(bytes_small_rb);
    allocator.free(bytes_medium_rb);
    allocator.free(bytes_large_rb);
    allocator.free(bytes_giant_rb);

    allocator.free(bytes_tiny_lb);
    allocator.free(bytes_small_lb);
    allocator.free(bytes_medium_lb);
    allocator.free(bytes_large_lb);

    try testing.expectEqual(@as(usize, 2), tracked.getAllocBucket(0));
    try testing.expectEqual(@as(usize, 2), tracked.getAllocBucket(1));
    try testing.expectEqual(@as(usize, 2), tracked.getAllocBucket(2));
    try testing.expectEqual(@as(usize, 2), tracked.getAllocBucket(3));
    try testing.expectEqual(@as(usize, 1), tracked.getAllocBucket(4));
}

test "getBytesBucket initial values 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    try testing.expectEqual(@as(usize, 0), tracked.getBytesBucket(0));
    try testing.expectEqual(@as(usize, 0), tracked.getBytesBucket(1));
    try testing.expectEqual(@as(usize, 0), tracked.getBytesBucket(2));
    try testing.expectEqual(@as(usize, 0), tracked.getBytesBucket(3));
    try testing.expectEqual(@as(usize, 0), tracked.getBytesBucket(4));
}

test "getBytesBucket boundary allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_tiny_rb = try allocator.alloc(u8, 64);
    const bytes_small_rb = try allocator.alloc(u8, 256);
    const bytes_medium_rb = try allocator.alloc(u8, 4096);
    const bytes_large_rb = try allocator.alloc(u8, 65536);
    const bytes_giant_rb = try allocator.alloc(u8, 65537);

    const bytes_tiny_lb = try allocator.alloc(u8, 1);
    const bytes_small_lb = try allocator.alloc(u8, 65);
    const bytes_medium_lb = try allocator.alloc(u8, 257);
    const bytes_large_lb = try allocator.alloc(u8, 4097);

    allocator.free(bytes_tiny_rb);
    allocator.free(bytes_small_rb);
    allocator.free(bytes_medium_rb);
    allocator.free(bytes_large_rb);
    allocator.free(bytes_giant_rb);

    allocator.free(bytes_tiny_lb);
    allocator.free(bytes_small_lb);
    allocator.free(bytes_medium_lb);
    allocator.free(bytes_large_lb);

    try testing.expectEqual(@as(usize, 65), tracked.getBytesBucket(0));
    try testing.expectEqual(@as(usize, 321), tracked.getBytesBucket(1));
    try testing.expectEqual(@as(usize, 4353), tracked.getBytesBucket(2));
    try testing.expectEqual(@as(usize, 69633), tracked.getBytesBucket(3));
    try testing.expectEqual(@as(usize, 65537), tracked.getBytesBucket(4));
}

test "getBytesBucket multiple allocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    for (0..1000) |_| {
        const bytes_tiny = try allocator.alloc(u8, 2);
        const bytes_small = try allocator.alloc(u8, 100);
        const bytes_medium = try allocator.alloc(u8, 1000);
        const bytes_large = try allocator.alloc(u8, 5000);
        const bytes_giant = try allocator.alloc(u8, 70000);

        allocator.free(bytes_tiny);
        allocator.free(bytes_small);
        allocator.free(bytes_medium);
        allocator.free(bytes_large);
        allocator.free(bytes_giant);
    }

    try testing.expectEqual(@as(usize, 2000), tracked.getBytesBucket(0));
    try testing.expectEqual(@as(usize, 100000), tracked.getBytesBucket(1));
    try testing.expectEqual(@as(usize, 1000000), tracked.getBytesBucket(2));
    try testing.expectEqual(@as(usize, 5000000), tracked.getBytesBucket(3));
    try testing.expectEqual(@as(usize, 70000000), tracked.getBytesBucket(4));
}

test "zero byte allocation - not in histogram" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const zero = try allocator.alloc(u8, 0);
    defer allocator.free(zero);

    // No buckets should have any allocations
    for (0..5) |i| {
        try testing.expectEqual(@as(usize, 0), tracked.getAllocBucket(i));
        try testing.expectEqual(@as(usize, 0), tracked.getBytesBucket(i));
    }
}

test "getMemoryLogs initially length 0" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const mem_logs = tracked.getMemoryLogs();

    try testing.expectEqual(0, mem_logs.count());
}

test "getMemoryLogs enrtry removed after freeing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracked = TrackedAllocator.init(gpa.allocator());
    defer tracked.memory_logs.deinit();

    const allocator = tracked.allocator();

    const bytes_10000 = try allocator.alloc(u8, 10000);
    allocator.free(bytes_10000);

    const mem_logs = tracked.getMemoryLogs();
    try testing.expectEqual(0, mem_logs.count());
}

