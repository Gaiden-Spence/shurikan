const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main module
    _ = b.addModule("your_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Documentation
    const docs = b.addSystemCommand(&[_][]const u8{
        "zig",
        "test",
        "-femit-docs",
        b.pathFromRoot("src/root.zig"),
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_success = b.addSystemCommand(&.{ "echo", "\x1b[32mAll tests passed!\x1b[0m" });
    test_success.step.dependOn(&run_tests.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&test_success.step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    b.installArtifact(bench);
}
