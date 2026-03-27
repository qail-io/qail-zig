// I/O Backend Policy + Selection
//
// Single location for transport backend policy and selection.
// This keeps runtime/backend routing isolated so future transport and std I/O
// migrations are localized to this file.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat/mod.zig");
const net = compat.net;
const process = compat.process;
const posix = std.posix;
const linux = std.os.linux;

/// Available I/O backends for plain TCP transport.
pub const Backend = enum {
    /// Linux io_uring for high-performance async I/O.
    io_uring,
    /// Portable blocking I/O.
    sync,
};

/// Runtime policy for selecting plain TCP transport backend.
pub const Policy = enum {
    auto,
    sync,
    io_uring,
};

/// Environment variable controlling plain TCP backend policy.
pub const IO_BACKEND_ENV_VAR = "QAIL_PG_IO_BACKEND";

/// Compile-time preferred backend based on target OS.
pub const backend: Backend = switch (builtin.os.tag) {
    .linux => .io_uring,
    else => .sync,
};

/// Human-readable name for compile-time preferred backend.
pub const name: []const u8 = backendName(backend);

/// Check if io_uring is available at runtime (Linux only).
pub fn isIoUringAvailable() bool {
    if (builtin.os.tag != .linux) return false;

    const IoUring = std.os.linux.IoUring;
    var ring = IoUring.init(1, 0) catch return false;
    ring.deinit();
    return true;
}

/// Auto-detect the best available runtime backend.
pub fn detect() Backend {
    if (builtin.os.tag == .linux and isIoUringAvailable()) return .io_uring;
    return .sync;
}

/// Parse backend policy from string value.
///
/// Accepted values:
/// - `auto`
/// - `sync`, `tokio`, `blocking`
/// - `io_uring`
pub fn parsePolicy(value: []const u8) ?Policy {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "sync")) return .sync;
    if (std.ascii.eqlIgnoreCase(value, "tokio")) return .sync;
    if (std.ascii.eqlIgnoreCase(value, "blocking")) return .sync;
    if (std.ascii.eqlIgnoreCase(value, "io_uring")) return .io_uring;
    return null;
}

/// Read backend policy from `QAIL_PG_IO_BACKEND`.
///
/// Missing or invalid values fall back to `.auto`.
pub fn policyFromEnv(allocator: std.mem.Allocator) Policy {
    const raw = process.getEnvVarOwned(allocator, IO_BACKEND_ENV_VAR) catch return .auto;
    defer allocator.free(raw);
    return parsePolicy(raw) orelse .auto;
}

/// Resolve actual backend from policy.
///
/// `io_uring` policy fails closed to `.sync` when unavailable.
pub fn detectWithPolicy(policy: Policy) Backend {
    return switch (policy) {
        .sync => .sync,
        .auto => detect(),
        .io_uring => if (isIoUringAvailable()) .io_uring else .sync,
    };
}

/// Resolve actual backend using environment policy.
pub fn detectWithEnv(allocator: std.mem.Allocator) Backend {
    return detectWithPolicy(policyFromEnv(allocator));
}

/// Human-readable backend name.
pub fn backendName(selected: Backend) []const u8 {
    return switch (selected) {
        .io_uring => "io_uring",
        .sync => "sync (blocking)",
    };
}

const IoUringStream = if (builtin.os.tag == .linux) struct {
    const Self = @This();

    fd: posix.fd_t,
    ring: linux.IoUring,
    closed: bool = false,

    pub fn initFromNet(stream: net.Stream) !Self {
        const ring = try linux.IoUring.init(32, 0);
        return .{
            .fd = stream.handle,
            .ring = ring,
            .closed = false,
        };
    }

    pub fn close(self: *Self) void {
        if (self.closed) return;
        self.closed = true;
        self.ring.deinit();
        posix.close(self.fd);
    }

    pub fn read(self: *Self, buffer: []u8) !usize {
        _ = try self.ring.recv(0xA11CE001, self.fd, .{ .buffer = buffer }, 0);
        return try completeOne(self);
    }

    pub fn write(self: *Self, bytes: []const u8) !usize {
        _ = try self.ring.send(0xA11CE002, self.fd, bytes, posix.MSG.NOSIGNAL);
        return try completeOne(self);
    }

    pub fn writeAll(self: *Self, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }

    fn completeOne(self: *Self) !usize {
        _ = try self.ring.submit_and_wait(1);
        const cqe = try self.ring.copy_cqe();

        if (cqe.res < 0) return error.IoUringOperationFailed;
        return @intCast(cqe.res);
    }
} else struct {
    pub fn initFromNet(_: net.Stream) !@This() {
        return error.IoUringUnsupported;
    }

    pub fn close(_: *@This()) void {}

    pub fn read(_: *@This(), _: []u8) !usize {
        return error.IoUringUnsupported;
    }

    pub fn write(_: *@This(), _: []const u8) !usize {
        return error.IoUringUnsupported;
    }

    pub fn writeAll(_: *@This(), _: []const u8) !void {
        return error.IoUringUnsupported;
    }
};

/// Backend-routed stream abstraction.
pub const Stream = union(enum) {
    sync: net.Stream,
    io_uring: IoUringStream,

    pub fn close(self: *Stream) void {
        switch (self.*) {
            .sync => |stream| stream.close(),
            .io_uring => |*stream| stream.close(),
        }
    }

    pub fn read(self: *Stream, buffer: []u8) !usize {
        return switch (self.*) {
            .sync => |stream| net.readStream(stream, buffer),
            .io_uring => |*stream| stream.read(buffer),
        };
    }

    pub fn write(self: *Stream, bytes: []const u8) !usize {
        return switch (self.*) {
            .sync => |stream| net.writeStream(stream, bytes),
            .io_uring => |*stream| stream.write(bytes),
        };
    }

    pub fn writeAll(self: *Stream, bytes: []const u8) !void {
        switch (self.*) {
            .sync => |stream| try net.writeAllStream(stream, bytes),
            .io_uring => |*stream| try stream.writeAll(bytes),
        }
    }
};

/// Result of backend-routed connect operation.
pub const ConnectResult = struct {
    stream: Stream,
    backend: Backend,
};

/// Connect TCP stream using selected backend.
pub fn connectToAddress(selected: Backend, address: net.Address) !ConnectResult {
    return switch (selected) {
        .sync => .{
            .stream = .{ .sync = try net.tcpConnectToAddress(address) },
            .backend = .sync,
        },
        .io_uring => blk: {
            const stream = try net.tcpConnectToAddress(address);
            const uring_stream = IoUringStream.initFromNet(stream) catch {
                break :blk .{
                    .stream = .{ .sync = stream },
                    .backend = .sync,
                };
            };
            break :blk .{
                .stream = .{ .io_uring = uring_stream },
                .backend = .io_uring,
            };
        },
    };
}

/// Connect TCP stream with timeout using selected backend.
pub fn connectToIp4WithTimeout(selected: Backend, host: []const u8, port: u16, timeout_ms: i32) !ConnectResult {
    return switch (selected) {
        .sync => .{
            .stream = .{ .sync = try net.tcpConnectToIp4WithTimeout(host, port, timeout_ms) },
            .backend = .sync,
        },
        .io_uring => blk: {
            const stream = try net.tcpConnectToIp4WithTimeout(host, port, timeout_ms);
            const uring_stream = IoUringStream.initFromNet(stream) catch {
                break :blk .{
                    .stream = .{ .sync = stream },
                    .backend = .sync,
                };
            };
            break :blk .{
                .stream = .{ .io_uring = uring_stream },
                .backend = .io_uring,
            };
        },
    };
}

test "policy parse" {
    try std.testing.expectEqual(@as(?Policy, .auto), parsePolicy("auto"));
    try std.testing.expectEqual(@as(?Policy, .sync), parsePolicy("sync"));
    try std.testing.expectEqual(@as(?Policy, .sync), parsePolicy("TOKIO"));
    try std.testing.expectEqual(@as(?Policy, .io_uring), parsePolicy("io_uring"));
    try std.testing.expect(parsePolicy("invalid") == null);
}

test "backend detection" {
    const detected = detect();
    try std.testing.expect(detected == .io_uring or detected == .sync);
}

test "policy detection" {
    try std.testing.expectEqual(@as(Backend, .sync), detectWithPolicy(.sync));
    const forced = detectWithPolicy(.io_uring);
    try std.testing.expect(forced == .io_uring or forced == .sync);
}

test "backend name" {
    try std.testing.expect(backendName(.sync).len > 0);
}
