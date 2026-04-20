// PostgreSQL COPY Protocol
//
// Bulk data operations using the PostgreSQL COPY protocol.
// Provides high-performance bulk insert and export.

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const helpers = @import("copy/helpers.zig");
const copy_sql = @import("copy/sql.zig");

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
    const sql = try copy_sql.buildCopyInSql(allocator, table, columns);
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
        const line = try helpers.encodeCopyRow(allocator, row);
        defer allocator.free(line);

        try helpers.sendCopyData(conn, line);
        total_rows += 1;
    }

    // Send CopyDone
    try helpers.sendCopyDone(conn);

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
    const sql = try copy_sql.buildCopyInSql(allocator, table, columns);
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
    try helpers.sendCopyData(conn, data);

    // Send CopyDone
    try helpers.sendCopyDone(conn);

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
    const sql = try copy_sql.buildCopyOutSql(allocator, table, columns);
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
    var rows: std.ArrayList([]const u8) = .empty;
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

// ==================== Tests ====================

test "COPY module compiles" {
    _ = copyIn;
    _ = copyInRaw;
    _ = copyExport;
}

test {
    _ = @import("copy/tests.zig");
}
