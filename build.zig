const std = @import("std");
const builtin = @import("builtin");

const QAIL_VERSION = "0.10.1";
const GITHUB_RELEASE_BASE = "https://github.com/qail-rs/qail/releases/download/v" ++ QAIL_VERSION ++ "/";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Ensure lib directory exists
    std.fs.cwd().makeDir("lib") catch {};

    // Get the correct library name for this platform
    const lib_info = getLibInfo(target);
    const lib_path = "lib/" ++ lib_info.local_name;

    // Check if library exists, if not download it
    const lib_exists = blk: {
        std.fs.cwd().access(lib_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!lib_exists) {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  📦 QAIL Library not found - downloading...                   ║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});

        const download_url = GITHUB_RELEASE_BASE ++ lib_info.remote_name;
        std.debug.print("📥 Downloading: {s}\n", .{download_url});
        std.debug.print("📁 To: {s}\n\n", .{lib_path});

        // Download using curl (most reliable cross-platform)
        downloadLib(b.allocator, download_url, lib_path, lib_info.is_gzipped) catch |err| {
            std.debug.print("\n❌ Download failed: {any}\n", .{err});
            std.debug.print("\n📋 Manual installation:\n", .{});
            std.debug.print("   1. Download from: {s}\n", .{download_url});
            std.debug.print("   2. Extract to: {s}\n", .{lib_path});
            std.debug.print("\n   Or build from source:\n", .{});
            std.debug.print("   git clone https://github.com/qail-rs/qail\n", .{});
            std.debug.print("   cd qail && cargo build --release -p qail-php\n", .{});
            std.debug.print("   cp target/release/libqail_php.a {s}\n\n", .{lib_path});
            @panic("Library download failed");
        };

        std.debug.print("✅ Downloaded successfully!\n\n", .{});
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

const LibInfo = struct {
    local_name: []const u8,
    remote_name: []const u8,
    is_gzipped: bool,
};

fn getLibInfo(target: std.Build.ResolvedTarget) LibInfo {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    if (os == .macos) {
        if (arch == .aarch64) {
            return .{ .local_name = "libqail_php.a", .remote_name = "libqail-darwin-arm64.a.gz", .is_gzipped = true };
        }
        return .{ .local_name = "libqail_php.a", .remote_name = "libqail-darwin-x64.a.gz", .is_gzipped = true };
    } else if (os == .linux) {
        if (arch == .aarch64) {
            return .{ .local_name = "libqail_php.a", .remote_name = "libqail-linux-arm64.a.gz", .is_gzipped = true };
        }
        return .{ .local_name = "libqail_php.a", .remote_name = "libqail-linux-x64.a.gz", .is_gzipped = true };
    } else if (os == .windows) {
        return .{ .local_name = "qail_php.lib", .remote_name = "libqail-win-x64.lib.zip", .is_gzipped = false };
    }

    // Fallback to linux x64
    return .{ .local_name = "libqail_php.a", .remote_name = "libqail-linux-x64.a.gz", .is_gzipped = true };
}

fn downloadLib(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8, is_gzipped: bool) !void {
    // Use curl for downloading (available on all platforms)
    if (is_gzipped) {
        // curl | gunzip > file
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "sh", "-c", std.fmt.allocPrint(allocator, "curl -sL '{s}' | gunzip > '{s}'", .{ url, dest_path }) catch unreachable },
        });
        _ = result;
    } else {
        // curl -o file
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "curl", "-sL", "-o", dest_path, url },
        });
        _ = result;
    }

    // Verify download succeeded
    std.fs.cwd().access(dest_path, .{}) catch {
        return error.DownloadFailed;
    };
}
