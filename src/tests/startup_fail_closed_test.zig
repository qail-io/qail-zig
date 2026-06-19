//! Startup protocol fail-closed tests.
//!
//! Validates fail-closed behavior for malformed or out-of-order backend
//! messages during connection startup/authentication.

const std = @import("std");
const net = @import("../runtime/net.zig");
const Connection = @import("../driver/connection.zig").Connection;
const AuthOptions = @import("../driver/auth_options.zig").AuthOptions;

const Mode = enum {
    parameter_status_before_auth,
    backend_key_before_auth,
    ready_before_auth,
    ready_in_transaction_after_auth,
    ready_failed_after_auth,
    auth_method_switch,
    auth_ok_before_sasl_final,
    auth_after_ok,
};

const ServerCtx = struct {
    server: *net.Server,
    mode: Mode,
};

const StartupResult = struct {
    err: anyerror,
};

fn writeU32(writer: anytype, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try writer.writeAll(&buf);
}

fn readNoEof(stream: net.Stream, buf: []u8) !void {
    var read_len: usize = 0;
    while (read_len < buf.len) {
        const n = try net.readStream(stream, buf[read_len..]);
        if (n == 0) return error.EndOfStream;
        read_len += n;
    }
}

fn writeByte(stream: net.Stream, byte: u8) !void {
    const buf = [_]u8{byte};
    try net.writeAllStream(stream, &buf);
}

fn readStartup(stream: net.Stream) !void {
    var len_buf: [4]u8 = undefined;
    try readNoEof(stream, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len < 8) return error.InvalidStartupMessage;

    var remaining: usize = @intCast(len - 4);
    var buf: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        const n = try net.readStream(stream, buf[0..chunk]);
        if (n == 0) return error.EndOfStream;
        remaining -= n;
    }
}

fn readFrontendMessage(stream: net.Stream) !u8 {
    var type_buf: [1]u8 = undefined;
    try readNoEof(stream, &type_buf);

    var len_buf: [4]u8 = undefined;
    try readNoEof(stream, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len < 4) return error.InvalidFrontendMessage;

    var remaining: usize = @intCast(len - 4);
    var buf: [256]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, buf.len);
        const n = try net.readStream(stream, buf[0..chunk]);
        if (n == 0) return error.EndOfStream;
        remaining -= n;
    }

    return type_buf[0];
}

fn sendAuth(stream: net.Stream, code: u32, extra: []const u8) !void {
    try writeByte(stream, 'R');
    try writeU32(stream, @intCast(8 + extra.len));
    try writeU32(stream, code);
    if (extra.len > 0) try net.writeAllStream(stream, extra);
}

fn sendParameterStatus(stream: net.Stream, name: []const u8, value: []const u8) !void {
    try writeByte(stream, 'S');
    try writeU32(stream, @intCast(4 + name.len + 1 + value.len + 1));
    try net.writeAllStream(stream, name);
    try writeByte(stream, 0);
    try net.writeAllStream(stream, value);
    try writeByte(stream, 0);
}

fn sendBackendKeyData(stream: net.Stream, process_id: u32, secret_key: u32) !void {
    try writeByte(stream, 'K');
    try writeU32(stream, 12);
    try writeU32(stream, process_id);
    try writeU32(stream, secret_key);
}

fn sendReadyForQuery(stream: net.Stream, status: u8) !void {
    try writeByte(stream, 'Z');
    try writeU32(stream, 5);
    try writeByte(stream, status);
}

fn serverThread(ctx: *ServerCtx) void {
    defer ctx.server.deinit();
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    if (readStartup(conn.stream)) |_| {} else |_| return;

    switch (ctx.mode) {
        .parameter_status_before_auth => {
            sendParameterStatus(conn.stream, "server_version", "16.0") catch {};
        },
        .backend_key_before_auth => {
            sendBackendKeyData(conn.stream, 1234, 5678) catch {};
        },
        .ready_before_auth => {
            sendReadyForQuery(conn.stream, 'I') catch {};
        },
        .ready_in_transaction_after_auth => {
            sendAuth(conn.stream, 0, &.{}) catch {};
            sendReadyForQuery(conn.stream, 'T') catch {};
        },
        .ready_failed_after_auth => {
            sendAuth(conn.stream, 0, &.{}) catch {};
            sendReadyForQuery(conn.stream, 'E') catch {};
        },
        .auth_method_switch => {
            sendAuth(conn.stream, 3, &.{}) catch {};
            _ = readFrontendMessage(conn.stream) catch return;
            sendAuth(conn.stream, 5, &.{ 1, 2, 3, 4 }) catch {};
        },
        .auth_ok_before_sasl_final => {
            const sasl_list = "SCRAM-SHA-256\x00\x00";
            sendAuth(conn.stream, 10, sasl_list) catch {};
            _ = readFrontendMessage(conn.stream) catch return;
            sendAuth(conn.stream, 0, &.{}) catch {};
        },
        .auth_after_ok => {
            sendAuth(conn.stream, 0, &.{}) catch {};
            sendAuth(conn.stream, 3, &.{}) catch {};
        },
    }
}

fn runStartupScript(mode: Mode, password: ?[]const u8) !StartupResult {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = ServerCtx{ .server = &server, .mode = mode };
    var thread = try std.Thread.spawn(.{}, serverThread, .{&ctx});
    defer thread.join();

    var conn = try Connection.connect(std.testing.allocator, "127.0.0.1", port);
    defer conn.close();

    conn.startupWithParamsAndAuth("test_user", "test_db", password, &.{}, AuthOptions{}) catch |err| {
        return .{ .err = err };
    };

    return error.UnexpectedSuccess;
}

test "startup rejects ParameterStatus before AuthenticationOk" {
    const res = try runStartupScript(.parameter_status_before_auth, null);
    try std.testing.expectEqual(error.ParameterStatusBeforeAuthOk, res.err);
}

test "startup rejects BackendKeyData before AuthenticationOk" {
    const res = try runStartupScript(.backend_key_before_auth, null);
    try std.testing.expectEqual(error.BackendKeyBeforeAuthOk, res.err);
}

test "startup rejects ReadyForQuery before AuthenticationOk" {
    const res = try runStartupScript(.ready_before_auth, null);
    try std.testing.expectEqual(error.StartupCompletedWithoutAuthOk, res.err);
}

test "startup rejects non-idle ReadyForQuery after AuthenticationOk" {
    const in_transaction = try runStartupScript(.ready_in_transaction_after_auth, null);
    try std.testing.expectEqual(error.StartupCompletedWithNonIdleStatus, in_transaction.err);

    const failed = try runStartupScript(.ready_failed_after_auth, null);
    try std.testing.expectEqual(error.StartupCompletedWithNonIdleStatus, failed.err);
}

test "startup rejects auth method switch mid-handshake" {
    const res = try runStartupScript(.auth_method_switch, "secret");
    try std.testing.expectEqual(error.AuthenticationMethodSwitch, res.err);
}

test "startup rejects AuthenticationOk before SASL final" {
    const res = try runStartupScript(.auth_ok_before_sasl_final, "secret");
    try std.testing.expectEqual(error.AuthenticationOkBeforeSaslFinal, res.err);
}

test "startup rejects authentication challenge after AuthenticationOk" {
    const res = try runStartupScript(.auth_after_ok, "secret");
    try std.testing.expectEqual(error.AuthenticationAfterOk, res.err);
}
