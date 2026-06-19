const std = @import("std");
const protocol = @import("../../protocol/mod.zig");
const copy = @import("../copy.zig");
const helpers = @import("helpers.zig");

const wire = protocol.wire;

const MockMsg = struct {
    msg_type: wire.BackendMessage,
    payload: []const u8 = &.{},
};

const copy_in_one_col = [_]u8{ 0, 0, 1, 0, 0 };
const copy_in_two_cols = [_]u8{ 0, 0, 2, 0, 0, 0, 0 };
const copy_in_three_cols = [_]u8{ 0, 0, 3, 0, 0, 0, 0, 0, 0 };
const copy_out_one_col = [_]u8{ 0, 0, 1, 0, 0 };

const MockConn = struct {
    allocator: std.mem.Allocator,
    messages: []const MockMsg,
    index: usize = 0,
    sent: std.ArrayListUnmanaged(u8) = .empty,

    fn init(allocator: std.mem.Allocator, messages: []const MockMsg) MockConn {
        return .{
            .allocator = allocator,
            .messages = messages,
        };
    }

    fn deinit(self: *MockConn) void {
        self.sent.deinit(self.allocator);
    }

    pub fn send(self: *MockConn, bytes: []const u8) !void {
        try self.sent.appendSlice(self.allocator, bytes);
    }

    pub fn readMessage(self: *MockConn) !struct { msg_type: wire.BackendMessage, payload: []const u8 } {
        if (self.index >= self.messages.len) return error.EndOfStream;
        const msg = self.messages[self.index];
        self.index += 1;
        return .{
            .msg_type = msg.msg_type,
            .payload = msg.payload,
        };
    }
};

const CopyDataGuardConn = struct {
    send_count: usize = 0,

    pub fn send(self: *CopyDataGuardConn, bytes: []const u8) !void {
        _ = bytes;
        self.send_count += 1;
    }
};

test "copy sendCopyData rejects oversized payload" {
    var conn = CopyDataGuardConn{};
    const too_large_len = @as(usize, std.math.maxInt(u32)) - 3;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.CopyDataTooLarge, helpers.sendCopyData(&conn, payload));
    try std.testing.expectEqual(@as(usize, 0), conn.send_count);
}

test "copy_in_raw quotes qualified identifiers in generated query" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_in_response, .payload = &copy_in_two_cols },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const rows = try copy.copyInRaw(&conn, std.testing.allocator, "tenant.users", &.{ "id", "full_name" }, "1\tAlice\n");
    try std.testing.expectEqual(@as(u64, 1), rows);
    try std.testing.expect(std.mem.indexOf(u8, conn.sent.items, "COPY \"tenant\".\"users\" (\"id\", \"full_name\") FROM STDIN") != null);
}

test "copy_in escapes copy text data" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_in_response, .payload = &copy_in_three_cols },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const row = [_]?[]const u8{ "hello\tworld", "line\nnext", "back\\slash" };
    const rows = [_][]const ?[]const u8{&row};
    const inserted = try copy.copyIn(&conn, std.testing.allocator, "users", &.{ "body", "note", "path" }, &rows);

    try std.testing.expectEqual(@as(u64, 1), inserted);
    try std.testing.expect(std.mem.indexOf(u8, conn.sent.items, "hello\\tworld\tline\\nnext\tback\\\\slash\n") != null);
}

test "copy_in rejects invalid copy data before sending" {
    var conn = MockConn.init(std.testing.allocator, &.{});
    defer conn.deinit();

    const row = [_]?[]const u8{"bad\x00value"};
    const rows = [_][]const ?[]const u8{&row};
    const err = copy.copyIn(&conn, std.testing.allocator, "users", &.{"body"}, &rows) catch |e| e;

    try std.testing.expectEqual(error.InvalidCopyData, err);
    try std.testing.expectEqual(@as(usize, 0), conn.sent.items.len);
}

test "copy_in_raw rejects invalid identifier before sending" {
    var conn = MockConn.init(std.testing.allocator, &.{});
    defer conn.deinit();

    const err = copy.copyInRaw(&conn, std.testing.allocator, "users;drop", &.{"id"}, "1\n") catch |e| e;
    try std.testing.expectEqual(error.InvalidIdentifier, err);
    try std.testing.expectEqual(@as(usize, 0), conn.sent.items.len);
}

test "copy_in_raw rejects unexpected startup message" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .backend_key_data, .payload = &.{ 0, 0, 0, 1, 0, 0, 0, 2 } },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copy.copyInRaw(&conn, std.testing.allocator, "users", &.{"id"}, "1\n") catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_in_raw rejects ready_without_command_complete" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_in_response, .payload = &copy_in_one_col },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copy.copyInRaw(&conn, std.testing.allocator, "users", &.{"id"}, "1\n") catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export rejects unexpected stream message" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response, .payload = &copy_out_one_col },
        .{ .msg_type = .backend_key_data, .payload = &.{ 0, 0, 0, 1, 0, 0, 0, 2 } },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copy.copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export requires copy_done and command_complete before ready" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response, .payload = &copy_out_one_col },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copy.copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export rejects copy_data after copy_done" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response, .payload = &copy_out_one_col },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .copy_done },
        .{ .msg_type = .copy_data, .payload = "2\tBob\n" },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copy.copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export rejects command_complete before copy_done" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response, .payload = &copy_out_one_col },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copy.copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export succeeds on valid message sequence" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response, .payload = &copy_out_one_col },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .copy_done },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const rows = try copy.copyExport(&conn, std.testing.allocator, "users", &.{"id"});
    defer {
        for (rows) |row| std.testing.allocator.free(row);
        std.testing.allocator.free(rows);
    }

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("1\tAlice\n", rows[0]);
}
