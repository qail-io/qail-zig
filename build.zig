const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==================== Library Module ====================
    // The main QAIL Zig library (pure Zig, no FFI)
    const qail_mod = b.addModule("qail", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ==================== Test Step ====================
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Enable strict mode: treat warnings as errors
    lib_tests.root_module.error_tracing = true;

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // ==================== Example Executable ====================
    const example = b.addExecutable(.{
        .name = "qail-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qail", .module = qail_mod },
            },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run example");
    run_step.dependOn(&run_example.step);

    // ==================== Benchmark Executable ====================
    const bench = b.addExecutable(.{
        .name = "qail-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "qail", .module = qail_mod },
            },
        }),
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmark");
    bench_step.dependOn(&run_bench.step);

    // ==================== Integration Test Executable ====================
    const integration = b.addExecutable(.{
        .name = "qail-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "qail", .module = qail_mod },
            },
        }),
    });
    b.installArtifact(integration);

    const run_integration = b.addRunArtifact(integration);
    run_integration.step.dependOn(b.getInstallStep());
    const integration_step = b.step("integration", "Run integration test");
    integration_step.dependOn(&run_integration.step);

    // ==================== Stress Test Executable ====================
    const stress = b.addExecutable(.{
        .name = "qail-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stress_test.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "qail", .module = qail_mod },
            },
        }),
    });
    b.installArtifact(stress);

    const run_stress = b.addRunArtifact(stress);
    run_stress.step.dependOn(b.getInstallStep());
    const stress_step = b.step("stress", "Run 50M roundtrip stress test");
    stress_step.dependOn(&run_stress.step);

    // ==================== Fair Benchmark Executable ====================
    const fair = b.addExecutable(.{
        .name = "qail-fair",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fair_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "qail", .module = qail_mod },
            },
        }),
    });
    b.installArtifact(fair);

    const run_fair = b.addRunArtifact(fair);
    run_fair.step.dependOn(b.getInstallStep());
    const fair_step = b.step("fair", "Run fair Rust-matching benchmark");
    fair_step.dependOn(&run_fair.step);

    // ==================== Check Step (fast compile check) ====================
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const check_step = b.step("check", "Fast compile check");
    check_step.dependOn(&check.step);
}
