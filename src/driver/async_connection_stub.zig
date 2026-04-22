// Async PostgreSQL Connection (Windows stub)
//
// The poll-based async driver is currently POSIX-only. This stub keeps the
// public API buildable on Windows until a native WinSock implementation lands.

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const auth_options_mod = @import("auth_options.zig");

const BackendMessage = protocol.BackendMessage;

pub const AuthOptions = auth_options_mod.AuthOptions;

pub const AsyncConnection = struct {
    allocator: std.mem.Allocator,
    default_timeout_ms: i32 = 30_000,
    ready: bool = false,
    in_transaction: bool = false,
    process_id: u32 = 0,
    secret_key: u32 = 0,
    cancel_key_len: u16 = 0,
    cancel_key: [256]u8 = [_]u8{0} ** 256,

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        timeout_ms: i32,
    ) !AsyncConnection {
        _ = host;
        _ = port;
        _ = timeout_ms;
        _ = allocator;
        return error.UnsupportedPlatform;
    }

    pub fn close(self: *AsyncConnection) void {
        _ = self;
    }

    pub fn sendWithTimeout(
        self: *AsyncConnection,
        bytes: []const u8,
        timeout_ms: i32,
    ) !void {
        _ = self;
        _ = bytes;
        _ = timeout_ms;
        return error.UnsupportedPlatform;
    }

    pub fn send(self: *AsyncConnection, bytes: []const u8) !void {
        return self.sendWithTimeout(bytes, self.default_timeout_ms);
    }

    pub fn recvWithTimeout(
        self: *AsyncConnection,
        buf: []u8,
        timeout_ms: i32,
    ) !usize {
        _ = self;
        _ = buf;
        _ = timeout_ms;
        return error.UnsupportedPlatform;
    }

    pub const MessageResult = struct {
        msg_type: BackendMessage,
        payload: []const u8,
    };

    pub fn readMessage(self: *AsyncConnection) !MessageResult {
        _ = self;
        return error.UnsupportedPlatform;
    }

    pub fn readMessageWithTimeout(
        self: *AsyncConnection,
        timeout_ms: i32,
    ) !MessageResult {
        _ = self;
        _ = timeout_ms;
        return error.UnsupportedPlatform;
    }

    pub fn startup(
        self: *AsyncConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
    ) !void {
        return self.startupWithAuthOptions(user, database, password, .{});
    }

    pub fn startupWithAuthOptions(
        self: *AsyncConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        auth_options: AuthOptions,
    ) !void {
        _ = self;
        _ = user;
        _ = database;
        _ = password;
        _ = auth_options;
        return error.UnsupportedPlatform;
    }
};

test "AsyncConnection stub compiles on unsupported platforms" {
    _ = AsyncConnection;
}
