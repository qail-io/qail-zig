//! Replication protocol fail-closed tests.
//!
//! Exercises `START_REPLICATION` fail-closed behavior against malformed or
//! out-of-order backend responses using a real TCP connection.

const std = @import("std");
const net = @import("../runtime/net.zig");
const Connection = @import("../driver/connection.zig").Connection;
const AuthOptions = @import("../driver/auth_options.zig").AuthOptions;
const driver_mod = @import("../driver/driver.zig");
const PgDriver = driver_mod.PgDriver;
const Notification = driver_mod.Notification;
const ReplicationStreamStart = driver_mod.ReplicationStreamStart;

const Mode = enum {
    ready_for_query,
    unexpected_backend_key,
    unsupported_copy_format,
    unsupported_column_formats,
    error_response,
    notification_then_copy_both,
    copy_done_after_copy_both,
    stream_error_after_copy_both,
    unexpected_backend_key_after_copy_both,
    invalid_copy_data_after_copy_both,
    notification_then_keepalive_after_copy_both,
    xlog_data_after_copy_both,
    regressed_xlog_data_after_copy_both,
};

const ServerCtx = struct {
    server: *net.Server,
    mode: Mode,
};

const StartSuccess = struct {
    driver: PgDriver,
    start: ReplicationStreamStart,
};

const FrontendCopyData = struct {
    payload: [34]u8 = undefined,
    len: usize = 0,
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

fn sendMessage(stream: net.Stream, tag: u8, payload: []const u8) !void {
    try writeByte(stream, tag);
    try writeU32(stream, @intCast(payload.len + 4));
    if (payload.len > 0) try net.writeAllStream(stream, payload);
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

fn readStartReplicationQuery(stream: net.Stream) !void {
    var tag_buf: [1]u8 = undefined;
    try readNoEof(stream, &tag_buf);
    if (tag_buf[0] != 'Q') return error.InvalidFrontendMessage;

    var len_buf: [4]u8 = undefined;
    try readNoEof(stream, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len < 5) return error.InvalidFrontendMessage;

    const payload_len: usize = @intCast(len - 4);
    var payload_buf: [512]u8 = undefined;
    if (payload_len > payload_buf.len) return error.InvalidFrontendMessage;
    try readNoEof(stream, payload_buf[0..payload_len]);

    if (payload_buf[payload_len - 1] != 0) return error.InvalidFrontendMessage;
    const query = payload_buf[0 .. payload_len - 1];
    if (!std.mem.startsWith(u8, query, "START_REPLICATION SLOT slot_main LOGICAL 0/16B6C50")) {
        return error.InvalidFrontendMessage;
    }
}

fn sendAuthenticationOk(stream: net.Stream) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, 0, .big);
    try sendMessage(stream, 'R', &payload);
}

fn sendBackendKeyData(stream: net.Stream, process_id: u32, secret_key: u32) !void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], process_id, .big);
    std.mem.writeInt(u32, payload[4..8], secret_key, .big);
    try sendMessage(stream, 'K', &payload);
}

fn sendReadyForQuery(stream: net.Stream, status: u8) !void {
    const payload = [_]u8{status};
    try sendMessage(stream, 'Z', &payload);
}

fn sendCopyData(stream: net.Stream, payload: []const u8) !void {
    try sendMessage(stream, 'd', payload);
}

fn sendCopyDone(stream: net.Stream) !void {
    try sendMessage(stream, 'c', &.{});
}

fn sendCopyBothResponse(stream: net.Stream, format: u8, column_formats: []const u16) !void {
    if (column_formats.len > 8) unreachable;

    var payload: [3 + (2 * 8)]u8 = undefined;
    payload[0] = format;
    std.mem.writeInt(i16, payload[1..3], @intCast(column_formats.len), .big);

    var pos: usize = 3;
    for (column_formats) |column_format| {
        var column_buf: [2]u8 = undefined;
        std.mem.writeInt(i16, &column_buf, @intCast(column_format), .big);
        @memcpy(payload[pos .. pos + 2], &column_buf);
        pos += 2;
    }

    try sendMessage(stream, 'W', payload[0..pos]);
}

fn sendErrorResponse(stream: net.Stream, message: []const u8) !void {
    if (message.len > 128) unreachable;

    var payload: [160]u8 = undefined;
    var pos: usize = 0;

    payload[pos] = 'S';
    pos += 1;
    @memcpy(payload[pos .. pos + "ERROR".len], "ERROR");
    pos += "ERROR".len;
    payload[pos] = 0;
    pos += 1;

    payload[pos] = 'C';
    pos += 1;
    @memcpy(payload[pos .. pos + "XX000".len], "XX000");
    pos += "XX000".len;
    payload[pos] = 0;
    pos += 1;

    payload[pos] = 'M';
    pos += 1;
    @memcpy(payload[pos .. pos + message.len], message);
    pos += message.len;
    payload[pos] = 0;
    pos += 1;

    payload[pos] = 0;
    pos += 1;

    try sendMessage(stream, 'E', payload[0..pos]);
}

fn sendNotification(stream: net.Stream, process_id: i32, channel: []const u8, payload_text: []const u8) !void {
    if (channel.len + payload_text.len > 200) unreachable;

    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    var process_id_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &process_id_buf, process_id, .big);
    @memcpy(payload[pos .. pos + 4], &process_id_buf);
    pos += 4;

    @memcpy(payload[pos .. pos + channel.len], channel);
    pos += channel.len;
    payload[pos] = 0;
    pos += 1;

    @memcpy(payload[pos .. pos + payload_text.len], payload_text);
    pos += payload_text.len;
    payload[pos] = 0;
    pos += 1;

    try sendMessage(stream, 'A', payload[0..pos]);
}

fn sendKeepalive(stream: net.Stream, wal_end: u64, server_time_micros: i64, reply_requested: bool) !void {
    var payload: [18]u8 = undefined;
    payload[0] = 'k';
    std.mem.writeInt(u64, payload[1..9], wal_end, .big);
    std.mem.writeInt(i64, payload[9..17], server_time_micros, .big);
    payload[17] = if (reply_requested) 1 else 0;
    try sendCopyData(stream, &payload);
}

fn sendInvalidKeepalive(stream: net.Stream) !void {
    var payload: [18]u8 = undefined;
    payload[0] = 'k';
    std.mem.writeInt(u64, payload[1..9], 0x20, .big);
    std.mem.writeInt(i64, payload[9..17], 1234, .big);
    payload[17] = 2;
    try sendCopyData(stream, &payload);
}

fn sendXLogData(stream: net.Stream, wal_start: u64, wal_end: u64, server_time_micros: i64, data: []const u8) !void {
    if (data.len > 64) unreachable;

    var payload: [25 + 64]u8 = undefined;
    payload[0] = 'w';
    std.mem.writeInt(u64, payload[1..9], wal_start, .big);
    std.mem.writeInt(u64, payload[9..17], wal_end, .big);
    std.mem.writeInt(i64, payload[17..25], server_time_micros, .big);
    @memcpy(payload[25 .. 25 + data.len], data);
    try sendCopyData(stream, payload[0 .. 25 + data.len]);
}

fn readFrontendCopyData(stream: net.Stream, capture: *FrontendCopyData) !void {
    var tag_buf: [1]u8 = undefined;
    try readNoEof(stream, &tag_buf);
    if (tag_buf[0] != 'd') return error.InvalidFrontendMessage;

    var len_buf: [4]u8 = undefined;
    try readNoEof(stream, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len < 5) return error.InvalidFrontendMessage;

    const payload_len: usize = @intCast(len - 4);
    if (payload_len > capture.payload.len) return error.InvalidFrontendMessage;
    try readNoEof(stream, capture.payload[0..payload_len]);
    capture.len = payload_len;
}

fn serverThread(ctx: *ServerCtx) void {
    defer ctx.server.deinit();
    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    readStartup(conn.stream) catch return;
    sendAuthenticationOk(conn.stream) catch return;
    sendBackendKeyData(conn.stream, 1234, 5678) catch return;
    sendReadyForQuery(conn.stream, 'I') catch return;

    readStartReplicationQuery(conn.stream) catch return;

    switch (ctx.mode) {
        .ready_for_query => sendReadyForQuery(conn.stream, 'I') catch {},
        .unexpected_backend_key => sendBackendKeyData(conn.stream, 9999, 1111) catch {},
        .unsupported_copy_format => sendCopyBothResponse(conn.stream, 1, &.{}) catch {},
        .unsupported_column_formats => sendCopyBothResponse(conn.stream, 0, &[_]u16{0}) catch {},
        .error_response => sendErrorResponse(conn.stream, "START_REPLICATION rejected") catch {},
        .notification_then_copy_both => {
            sendNotification(conn.stream, 42, "repl_status", "streaming") catch {};
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
        },
        .copy_done_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendCopyDone(conn.stream) catch {};
        },
        .stream_error_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendErrorResponse(conn.stream, "replication stream failed") catch {};
        },
        .unexpected_backend_key_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendBackendKeyData(conn.stream, 7777, 8888) catch {};
        },
        .invalid_copy_data_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendInvalidKeepalive(conn.stream) catch {};
        },
        .notification_then_keepalive_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendNotification(conn.stream, 52, "repl_stream", "keepalive") catch {};
            sendKeepalive(conn.stream, 0x20, 9876, true) catch {};
        },
        .xlog_data_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendXLogData(conn.stream, 0x20, 0x30, 1111, "wal") catch {};
        },
        .regressed_xlog_data_after_copy_both => {
            sendCopyBothResponse(conn.stream, 0, &.{}) catch {};
            sendXLogData(conn.stream, 0x08, 0x0f, 1111, "wal") catch {};
        },
    }
}

fn startLogicalReplication(mode: Mode) !StartSuccess {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = ServerCtx{ .server = &server, .mode = mode };
    var thread = try std.Thread.spawn(.{}, serverThread, .{&ctx});
    defer thread.join();

    var conn = try Connection.connect(std.testing.allocator, "127.0.0.1", port);
    var driver: ?PgDriver = null;
    errdefer {
        if (driver) |*pg| {
            pg.deinit();
        } else {
            conn.close();
        }
    }

    try conn.startupWithParamsAndAuth("test_user", "test_db", null, &.{}, AuthOptions{});

    driver = PgDriver.init(conn, std.testing.allocator);
    driver.?.replication_mode_enabled = true;

    const start = try driver.?.startLogicalReplication("slot_main", "0/16B6C50", &.{});
    return .{
        .driver = driver.?,
        .start = start,
    };
}

fn expectStartReplicationError(mode: Mode, expected: anyerror) !void {
    var res = startLogicalReplication(mode) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer res.start.deinit();
    defer res.driver.deinit();
    return error.UnexpectedSuccess;
}

fn freeNotifications(notifications: []Notification) void {
    for (notifications) |*notification| {
        notification.deinit();
    }
    std.testing.allocator.free(notifications);
}

fn expectRecvReplicationError(mode: Mode, expected: anyerror) !void {
    var res = try startLogicalReplication(mode);
    defer res.start.deinit();
    defer res.driver.deinit();

    res.driver.last_replication_wal_end = 0x10;

    try std.testing.expectError(expected, res.driver.recvReplicationMessage());
    try std.testing.expect(!res.driver.replication_stream_active);
    try std.testing.expect(res.driver.last_replication_wal_end == null);
}

test "START_REPLICATION rejects ReadyForQuery response" {
    try expectStartReplicationError(.ready_for_query, error.InvalidReplicationResponse);
}

test "START_REPLICATION rejects unexpected backend frames" {
    try expectStartReplicationError(.unexpected_backend_key, error.UnexpectedReplicationMessage);
}

test "START_REPLICATION rejects unsupported CopyBoth format" {
    try expectStartReplicationError(.unsupported_copy_format, error.UnsupportedReplicationFormat);
}

test "START_REPLICATION rejects column format descriptors" {
    try expectStartReplicationError(.unsupported_column_formats, error.UnsupportedReplicationFormat);
}

test "START_REPLICATION surfaces backend error response" {
    try expectStartReplicationError(.error_response, error.QueryError);
}

test "START_REPLICATION buffers notifications before CopyBoth" {
    var res = try startLogicalReplication(.notification_then_copy_both);
    defer res.start.deinit();
    defer res.driver.deinit();

    try std.testing.expectEqual(@as(u8, 0), res.start.format);
    try std.testing.expectEqual(@as(usize, 0), res.start.column_formats.len);

    const notifications = try res.driver.pollNotifications();
    defer freeNotifications(notifications);

    try std.testing.expectEqual(@as(usize, 1), notifications.len);
    try std.testing.expectEqual(@as(i32, 42), notifications[0].process_id);
    try std.testing.expectEqualStrings("repl_status", notifications[0].channel);
    try std.testing.expectEqualStrings("streaming", notifications[0].payload);
}

test "recvReplicationMessage ends stream on CopyDone" {
    try expectRecvReplicationError(.copy_done_after_copy_both, error.ReplicationStreamEnded);
}

test "recvReplicationMessage ends stream on backend error response" {
    try expectRecvReplicationError(.stream_error_after_copy_both, error.QueryError);
}

test "recvReplicationMessage ends stream on unexpected backend frame" {
    try expectRecvReplicationError(.unexpected_backend_key_after_copy_both, error.UnexpectedReplicationMessage);
}

test "recvReplicationMessage rejects malformed CopyData and clears stream state" {
    try expectRecvReplicationError(.invalid_copy_data_after_copy_both, error.InvalidReplicationCopyData);
}

test "recvReplicationMessage buffers notifications before keepalive" {
    var res = try startLogicalReplication(.notification_then_keepalive_after_copy_both);
    defer res.start.deinit();
    defer res.driver.deinit();

    var msg = try res.driver.recvReplicationMessage();
    defer msg.deinit();

    switch (msg) {
        .keepalive => |keepalive| {
            try std.testing.expectEqual(@as(u64, 0x20), keepalive.wal_end);
            try std.testing.expectEqual(@as(i64, 9876), keepalive.server_time_micros);
            try std.testing.expect(keepalive.reply_requested);
        },
        else => return error.TestExpectedEqual,
    }

    try std.testing.expect(res.driver.replication_stream_active);
    try std.testing.expectEqual(@as(?u64, 0x20), res.driver.last_replication_wal_end);

    const notifications = try res.driver.pollNotifications();
    defer freeNotifications(notifications);

    try std.testing.expectEqual(@as(usize, 1), notifications.len);
    try std.testing.expectEqual(@as(i32, 52), notifications[0].process_id);
    try std.testing.expectEqualStrings("repl_stream", notifications[0].channel);
    try std.testing.expectEqualStrings("keepalive", notifications[0].payload);
}

test "recvReplicationMessage parses XLogData and advances wal end" {
    var res = try startLogicalReplication(.xlog_data_after_copy_both);
    defer res.start.deinit();
    defer res.driver.deinit();

    var msg = try res.driver.recvReplicationMessage();
    defer msg.deinit();

    switch (msg) {
        .xlog_data => |xlog| {
            try std.testing.expectEqual(@as(u64, 0x20), xlog.wal_start);
            try std.testing.expectEqual(@as(u64, 0x30), xlog.wal_end);
            try std.testing.expectEqual(@as(i64, 1111), xlog.server_time_micros);
            try std.testing.expectEqualStrings("wal", xlog.data);
        },
        else => return error.TestExpectedEqual,
    }

    try std.testing.expect(res.driver.replication_stream_active);
    try std.testing.expectEqual(@as(?u64, 0x30), res.driver.last_replication_wal_end);
}

test "recvReplicationMessage rejects regressed XLogData wal end" {
    var res = try startLogicalReplication(.regressed_xlog_data_after_copy_both);
    defer res.start.deinit();
    defer res.driver.deinit();

    res.driver.last_replication_wal_end = 0x10;

    try std.testing.expectError(error.InvalidReplicationWalEnd, res.driver.recvReplicationMessage());
    try std.testing.expect(!res.driver.replication_stream_active);
    try std.testing.expect(res.driver.last_replication_wal_end == null);
}

test "sendStandbyStatusUpdate writes CopyData standby status frame" {
    const Ctx = struct {
        server: *net.Server,
        capture: *FrontendCopyData,
    };

    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var capture: FrontendCopyData = .{};
    var ctx = Ctx{ .server = &server, .capture = &capture };

    var thread = try std.Thread.spawn(.{}, struct {
        fn run(thread_ctx: *Ctx) void {
            defer thread_ctx.server.deinit();
            var conn = thread_ctx.server.accept() catch return;
            defer conn.stream.close();

            readStartup(conn.stream) catch return;
            sendAuthenticationOk(conn.stream) catch return;
            sendBackendKeyData(conn.stream, 1234, 5678) catch return;
            sendReadyForQuery(conn.stream, 'I') catch return;

            readStartReplicationQuery(conn.stream) catch return;
            sendCopyBothResponse(conn.stream, 0, &.{}) catch return;
            readFrontendCopyData(conn.stream, thread_ctx.capture) catch {};
        }
    }.run, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    var conn = try Connection.connect(std.testing.allocator, "127.0.0.1", port);
    var conn_owned = true;
    defer if (conn_owned) conn.close();
    try conn.startupWithParamsAndAuth("test_user", "test_db", null, &.{}, AuthOptions{});

    var driver = PgDriver.init(conn, std.testing.allocator);
    conn_owned = false;
    defer driver.deinit();
    driver.replication_mode_enabled = true;

    var start = try driver.startLogicalReplication("slot_main", "0/16B6C50", &.{});
    defer start.deinit();

    driver.last_replication_wal_end = 0x40;
    try driver.sendStandbyStatusUpdate(0x30, 0x20, 0x10, true);

    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(usize, 34), capture.len);
    try std.testing.expectEqual(@as(u8, 'r'), capture.payload[0]);
    try std.testing.expectEqual(@as(u64, 0x30), std.mem.readInt(u64, capture.payload[1..9], .big));
    try std.testing.expectEqual(@as(u64, 0x20), std.mem.readInt(u64, capture.payload[9..17], .big));
    try std.testing.expectEqual(@as(u64, 0x10), std.mem.readInt(u64, capture.payload[17..25], .big));
    try std.testing.expectEqual(@as(u8, 1), capture.payload[33]);
}
