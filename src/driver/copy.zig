// PostgreSQL COPY Protocol
//
// Bulk data operations using the PostgreSQL COPY protocol.
// Provides high-performance bulk insert and export.

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;

/// Bulk insert using COPY protocol.
///
/// Takes a table name, column names, and row data.
/// Each row is a slice of nullable column values (null = NULL).
///
/// Returns the number of rows inserted.
pub fn copyIn(
    conn: anytype,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
    rows: []const []const ?[]const u8,
) !u64 {
    // Build COPY command
    const quoted_table = try quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);

    const quoted_cols = try quoteIdentifierListAlloc(allocator, columns);
    defer allocator.free(quoted_cols);

    const sql = try std.fmt.allocPrint(allocator, "COPY {s} ({s}) FROM STDIN", .{ quoted_table, quoted_cols });
    defer allocator.free(sql);

    // Send Query message
    var encoder = protocol.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    // Wait for CopyInResponse
    var saw_copy_in_response = false;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_in_response => {
                saw_copy_in_response = true;
                break;
            },
            .error_response => return error.CopyFailed,
            .notice, .parameter_status, .notification => {},
            else => return error.InvalidCopyState,
        }
    }
    if (!saw_copy_in_response) return error.InvalidCopyState;

    // Send data rows as CopyData messages
    var total_rows: u64 = 0;
    for (rows) |row| {
        const line = try encodeCopyRow(allocator, row);
        defer allocator.free(line);

        try sendCopyData(conn, line);
        total_rows += 1;
    }

    // Send CopyDone
    try sendCopyDone(conn);

    // Wait for CommandComplete
    var saw_command_complete = false;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .command_complete => saw_command_complete = true,
            .ready_for_query => {
                if (!saw_command_complete) return error.InvalidCopyState;
                return total_rows;
            },
            .error_response => return error.CopyFailed,
            .notice, .parameter_status, .notification => {},
            else => return error.InvalidCopyState,
        }
    }
}

/// Bulk insert with pre-encoded data.
///
/// Takes raw COPY text format (tab-separated, newline-terminated).
/// Example: "1\thello\t3.14\n2\tworld\t2.71\n"
///
/// Returns the number of rows inserted.
pub fn copyInRaw(
    conn: anytype,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
    data: []const u8,
) !u64 {
    // Build COPY command
    const quoted_table = try quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);

    const quoted_cols = try quoteIdentifierListAlloc(allocator, columns);
    defer allocator.free(quoted_cols);

    const sql = try std.fmt.allocPrint(allocator, "COPY {s} ({s}) FROM STDIN", .{ quoted_table, quoted_cols });
    defer allocator.free(sql);

    // Send Query message
    var encoder = protocol.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    // Wait for CopyInResponse
    var saw_copy_in_response = false;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_in_response => {
                saw_copy_in_response = true;
                break;
            },
            .error_response => return error.CopyFailed,
            .notice, .parameter_status, .notification => {},
            else => return error.InvalidCopyState,
        }
    }
    if (!saw_copy_in_response) return error.InvalidCopyState;

    // Send all data in one CopyData message
    try sendCopyData(conn, data);

    // Send CopyDone
    try sendCopyDone(conn);

    // Count rows (newlines) and wait for completion
    var row_count: u64 = 0;
    for (data) |c| {
        if (c == '\n') row_count += 1;
    }
    var saw_command_complete = false;

    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .command_complete => saw_command_complete = true,
            .ready_for_query => {
                if (!saw_command_complete) return error.InvalidCopyState;
                return row_count;
            },
            .error_response => return error.CopyFailed,
            .notice, .parameter_status, .notification => {},
            else => return error.InvalidCopyState,
        }
    }
}

/// Export data using COPY TO STDOUT.
///
/// Returns rows as slices of column values.
pub fn copyExport(
    conn: anytype,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
) ![][]const u8 {
    // Build COPY command
    const quoted_table = try quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);

    const quoted_cols = try quoteIdentifierListAlloc(allocator, columns);
    defer allocator.free(quoted_cols);

    const sql = try std.fmt.allocPrint(allocator, "COPY (SELECT {s} FROM {s}) TO STDOUT", .{ quoted_cols, quoted_table });
    defer allocator.free(sql);

    // Send Query message
    var encoder = protocol.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    // Wait for CopyOutResponse
    var saw_copy_out = false;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_out_response => {
                saw_copy_out = true;
                break;
            },
            .error_response => return error.CopyFailed,
            .notice, .parameter_status, .notification => {},
            else => return error.InvalidCopyState,
        }
    }
    if (!saw_copy_out) return error.InvalidCopyState;

    // Receive CopyData messages
    var rows: std.ArrayList([]const u8) = .{};
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    var saw_copy_done = false;
    var saw_command_complete = false;

    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_data => {
                if (saw_copy_done) return error.InvalidCopyState;
                // Copy payload since buffer may be reused
                const row = try allocator.dupe(u8, msg.payload);
                try rows.append(allocator, row);
            },
            .copy_done => {
                if (saw_copy_done) return error.InvalidCopyState;
                saw_copy_done = true;
            },
            .command_complete => {
                if (!saw_copy_done) return error.InvalidCopyState;
                saw_command_complete = true;
            },
            .ready_for_query => {
                if (!saw_copy_done or !saw_command_complete) return error.InvalidCopyState;
                return try rows.toOwnedSlice(allocator);
            },
            .error_response => return error.CopyFailed,
            .notice, .parameter_status, .notification => {},
            else => return error.InvalidCopyState,
        }
    }
}

// ==================== Internal Helpers ====================

/// Encode a row to COPY text format (tab-separated, newline-terminated)
fn encodeCopyRow(allocator: std.mem.Allocator, row: []const ?[]const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(allocator);

    for (row) |col| {
        if (col) |value| {
            try parts.append(allocator, value);
        } else {
            try parts.append(allocator, "\\N"); // NULL
        }
    }

    const joined = try std.mem.join(allocator, "\t", parts.items);
    defer allocator.free(joined);

    return try std.fmt.allocPrint(allocator, "{s}\n", .{joined});
}

/// Send CopyData message
fn sendCopyData(conn: anytype, data: []const u8) !void {
    // CopyData: 'd' + length (4 bytes) + data
    if (data.len > std.math.maxInt(u32) - 4) return error.CopyDataTooLarge;
    const len: u32 = @intCast(data.len + 4);
    var header: [5]u8 = undefined;
    header[0] = 'd';
    std.mem.writeInt(u32, header[1..5], len, .big);

    try conn.send(&header);
    try conn.send(data);
}

/// Send CopyDone message
fn sendCopyDone(conn: anytype) !void {
    // CopyDone: 'c' + length (4) = 5 bytes total
    const msg = [_]u8{ 'c', 0, 0, 0, 4 };
    try conn.send(&msg);
}

fn quoteIdentifierListAlloc(allocator: std.mem.Allocator, columns: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    for (columns, 0..) |column, i| {
        const quoted = try quoteQualifiedIdentifierAlloc(allocator, column);
        defer allocator.free(quoted);

        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, quoted);
    }

    return try out.toOwnedSlice(allocator);
}

fn quoteQualifiedIdentifierAlloc(allocator: std.mem.Allocator, ident: []const u8) ![]u8 {
    if (ident.len == 0) return error.InvalidIdentifier;

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, ident, '.');
    var wrote_part = false;
    while (parts.next()) |part| {
        try validateIdentifierPart(part);

        if (wrote_part) try out.append(allocator, '.');
        try out.append(allocator, '"');
        try out.appendSlice(allocator, part);
        try out.append(allocator, '"');
        wrote_part = true;
    }

    if (!wrote_part) return error.InvalidIdentifier;
    return try out.toOwnedSlice(allocator);
}

fn validateIdentifierPart(part: []const u8) !void {
    if (part.len == 0 or part.len > 63) return error.InvalidIdentifier;

    const first = part[0];
    if (!(first == '_' or std.ascii.isAlphabetic(first))) return error.InvalidIdentifier;

    for (part[1..]) |ch| {
        if (!(ch == '_' or std.ascii.isAlphanumeric(ch))) return error.InvalidIdentifier;
    }
}

// ==================== Tests ====================

test "COPY module compiles" {
    _ = copyIn;
    _ = copyInRaw;
    _ = copyExport;
}

const MockMsg = struct {
    msg_type: wire.BackendMessage,
    payload: []const u8 = &.{},
};

const MockConn = struct {
    allocator: std.mem.Allocator,
    messages: []const MockMsg,
    index: usize = 0,
    sent: std.ArrayListUnmanaged(u8) = .{},

    fn init(allocator: std.mem.Allocator, messages: []const MockMsg) MockConn {
        return .{
            .allocator = allocator,
            .messages = messages,
        };
    }

    fn deinit(self: *MockConn) void {
        self.sent.deinit(self.allocator);
    }

    fn send(self: *MockConn, bytes: []const u8) !void {
        try self.sent.appendSlice(self.allocator, bytes);
    }

    fn readMessage(self: *MockConn) !struct { msg_type: wire.BackendMessage, payload: []const u8 } {
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

    fn send(self: *CopyDataGuardConn, bytes: []const u8) !void {
        _ = bytes;
        self.send_count += 1;
    }
};

test "copy sendCopyData rejects oversized payload" {
    var conn = CopyDataGuardConn{};
    const too_large_len = @as(usize, std.math.maxInt(u32)) - 3;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.CopyDataTooLarge, sendCopyData(&conn, payload));
    try std.testing.expectEqual(@as(usize, 0), conn.send_count);
}

test "copy_in_raw quotes qualified identifiers in generated query" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_in_response },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const rows = try copyInRaw(&conn, std.testing.allocator, "tenant.users", &.{ "id", "full_name" }, "1\tAlice\n");
    try std.testing.expectEqual(@as(u64, 1), rows);
    try std.testing.expect(std.mem.indexOf(u8, conn.sent.items, "COPY \"tenant\".\"users\" (\"id\", \"full_name\") FROM STDIN") != null);
}

test "copy_in_raw rejects invalid identifier before sending" {
    var conn = MockConn.init(std.testing.allocator, &.{});
    defer conn.deinit();

    const err = copyInRaw(&conn, std.testing.allocator, "users;drop", &.{"id"}, "1\n") catch |e| e;
    try std.testing.expectEqual(error.InvalidIdentifier, err);
    try std.testing.expectEqual(@as(usize, 0), conn.sent.items.len);
}

test "copy_in_raw rejects unexpected startup message" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .backend_key_data, .payload = &.{ 0, 0, 0, 1, 0, 0, 0, 2 } },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copyInRaw(&conn, std.testing.allocator, "users", &.{"id"}, "1\n") catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_in_raw rejects ready_without_command_complete" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_in_response },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copyInRaw(&conn, std.testing.allocator, "users", &.{"id"}, "1\n") catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export rejects unexpected stream message" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response },
        .{ .msg_type = .backend_key_data, .payload = &.{ 0, 0, 0, 1, 0, 0, 0, 2 } },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export requires copy_done and command_complete before ready" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export rejects copy_data after copy_done" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .copy_done },
        .{ .msg_type = .copy_data, .payload = "2\tBob\n" },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export rejects command_complete before copy_done" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const err = copyExport(&conn, std.testing.allocator, "users", &.{"id"}) catch |e| e;
    try std.testing.expectEqual(error.InvalidCopyState, err);
}

test "copy_export succeeds on valid message sequence" {
    const msgs = [_]MockMsg{
        .{ .msg_type = .copy_out_response },
        .{ .msg_type = .copy_data, .payload = "1\tAlice\n" },
        .{ .msg_type = .copy_done },
        .{ .msg_type = .command_complete, .payload = "COPY 1" },
        .{ .msg_type = .ready_for_query, .payload = &.{'I'} },
    };
    var conn = MockConn.init(std.testing.allocator, &msgs);
    defer conn.deinit();

    const rows = try copyExport(&conn, std.testing.allocator, "users", &.{"id"});
    defer {
        for (rows) |row| std.testing.allocator.free(row);
        std.testing.allocator.free(rows);
    }

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("1\tAlice\n", rows[0]);
}
