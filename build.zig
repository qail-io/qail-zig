const std = @import("std");
const builtin = @import("builtin");

const QAIL_VERSION = "0.10.1";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Ensure lib directory exists
    std.fs.cwd().makeDir("lib") catch {};

    // Check if library exists
    const lib_path = "lib/libqail_php.a";
    const lib_exists = blk: {
        std.fs.cwd().access(lib_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!lib_exists) {
        // Determine remote name based on target
        const remote_name = getRemoteName(target);

        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  📦 QAIL Library not found                                    ║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("📥 Run this command to download:\n\n", .{});
        std.debug.print("   curl -sL 'https://github.com/qail-rs/qail/releases/download/v{s}/{s}' | gunzip > {s}\n\n", .{ QAIL_VERSION, remote_name, lib_path });
        std.debug.print("Or build from source:\n\n", .{});
        std.debug.print("   git clone https://github.com/qail-rs/qail\n", .{});
        std.debug.print("   cd qail && cargo build --release -p qail-php\n", .{});
        std.debug.print("   cp target/release/libqail_php.a {s}\n\n", .{lib_path});
        @panic("Library not found. Please download using the command above.");
    }

    // Main benchmark executable
    const exe = b.addExecutable(.{
        .name = "qail-zig-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.addLibraryPath(.{ .cwd_relative = "lib" });
    exe.linkSystemLibrary("qail_php");
    exe.linkSystemLibrary("c");
    if (target.result.os.tag != .windows) {
        exe.linkSystemLibrary("resolv");
    }
    exe.linkSystemLibrary("c++");
    b.installArtifact(exe);

    // I/O benchmark
    const bench_io = b.addExecutable(.{
        .name = "qail-zig-bench-io",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_io.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_io.addLibraryPath(.{ .cwd_relative = "lib" });
    bench_io.linkSystemLibrary("qail_php");
    bench_io.linkSystemLibrary("c");
    if (target.result.os.tag != .windows) {
        bench_io.linkSystemLibrary("resolv");
    }
    bench_io.linkSystemLibrary("c++");
    b.installArtifact(bench_io);

    // Run steps
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run encoding benchmark");
    run_step.dependOn(&run_cmd.step);

    const run_io = b.addRunArtifact(bench_io);
    run_io.step.dependOn(b.getInstallStep());
    const run_io_step = b.step("bench-io", "Run I/O benchmark");
    run_io_step.dependOn(&run_io.step);
}

fn getRemoteName(target: std.Build.ResolvedTarget) []const u8 {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    if (os == .macos) {
        if (arch == .aarch64) return "libqail-darwin-arm64.a.gz";
        return "libqail-darwin-x64.a.gz";
    } else if (os == .linux) {
        if (arch == .aarch64) return "libqail-linux-arm64.a.gz";
        return "libqail-linux-x64.a.gz";
    } else if (os == .windows) {
        return "libqail-win-x64.lib.zip";
    }
    return "libqail-linux-x64.a.gz";
}
