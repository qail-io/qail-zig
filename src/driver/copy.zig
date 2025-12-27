//! PostgreSQL COPY Protocol
//!
//! Bulk data operations using the PostgreSQL COPY protocol.
//! Provides high-performance bulk insert and export.

const std = @import("std");
const Connection = @import("connection.zig").Connection;
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;

/// Bulk insert using COPY protocol.
///
/// Takes a table name, column names, and row data.
/// Each row is a slice of nullable column values (null = NULL).
///
/// Returns the number of rows inserted.
pub fn copyIn(
    conn: *Connection,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
    rows: []const []const ?[]const u8,
) !u64 {
    // Build COPY command
    const cols = try std.mem.join(allocator, ", ", columns);
    defer allocator.free(cols);

    const sql = try std.fmt.allocPrint(allocator, "COPY {s} ({s}) FROM STDIN", .{ table, cols });
    defer allocator.free(sql);

    // Send Query message
    var encoder = protocol.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    // Wait for CopyInResponse
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_in_response => break,
            .error_response => return error.CopyFailed,
            else => {},
        }
    }

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
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .command_complete => {},
            .ready_for_query => return total_rows,
            .error_response => return error.CopyFailed,
            else => {},
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
    conn: *Connection,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
    data: []const u8,
) !u64 {
    // Build COPY command
    const cols = try std.mem.join(allocator, ", ", columns);
    defer allocator.free(cols);

    const sql = try std.fmt.allocPrint(allocator, "COPY {s} ({s}) FROM STDIN", .{ table, cols });
    defer allocator.free(sql);

    // Send Query message
    var encoder = protocol.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    // Wait for CopyInResponse
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_in_response => break,
            .error_response => return error.CopyFailed,
            else => {},
        }
    }

    // Send all data in one CopyData message
    try sendCopyData(conn, data);

    // Send CopyDone
    try sendCopyDone(conn);

    // Count rows (newlines) and wait for completion
    var row_count: u64 = 0;
    for (data) |c| {
        if (c == '\n') row_count += 1;
    }

    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .command_complete => {},
            .ready_for_query => return row_count,
            .error_response => return error.CopyFailed,
            else => {},
        }
    }
}

/// Export data using COPY TO STDOUT.
///
/// Returns rows as slices of column values.
pub fn copyExport(
    conn: *Connection,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
) ![][]const u8 {
    // Build COPY command
    const cols = try std.mem.join(allocator, ", ", columns);
    defer allocator.free(cols);

    const sql = try std.fmt.allocPrint(allocator, "COPY (SELECT {s} FROM {s}) TO STDOUT", .{ cols, table });
    defer allocator.free(sql);

    // Send Query message
    var encoder = protocol.Encoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    // Wait for CopyOutResponse
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_out_response => break,
            .error_response => return error.CopyFailed,
            else => {},
        }
    }

    // Receive CopyData messages
    var rows: std.ArrayList([]const u8) = .{};
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }

    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .copy_data => {
                // Copy payload since buffer may be reused
                const row = try allocator.dupe(u8, msg.payload);
                try rows.append(allocator, row);
            },
            .copy_done => {},
            .command_complete => {},
            .ready_for_query => return try rows.toOwnedSlice(allocator),
            .error_response => return error.CopyFailed,
            else => {},
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
fn sendCopyData(conn: *Connection, data: []const u8) !void {
    // CopyData: 'd' + length (4 bytes) + data
    const len: u32 = @intCast(data.len + 4);
    var header: [5]u8 = undefined;
    header[0] = 'd';
    std.mem.writeInt(u32, header[1..5], len, .big);

    try conn.send(&header);
    try conn.send(data);
}

/// Send CopyDone message
fn sendCopyDone(conn: *Connection) !void {
    // CopyDone: 'c' + length (4) = 5 bytes total
    const msg = [_]u8{ 'c', 0, 0, 0, 4 };
    try conn.send(&msg);
}

// ==================== Tests ====================

test "COPY module compiles" {
    _ = copyIn;
    _ = copyInRaw;
    _ = copyExport;
}
