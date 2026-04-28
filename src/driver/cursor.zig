//! Server-side cursor for streaming large result sets.
//!
//! Uses PostgreSQL DECLARE CURSOR to avoid loading all rows into memory.
//! Port of qail.rs/qail-pg/src/driver/cursor.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const protocol = @import("../protocol/mod.zig");
const cursor_sql = @import("cursor/sql.zig");
const raw_policy = @import("raw_policy.zig");
const QailCmd = ast.QailCmd;
const AstEncoder = protocol.AstEncoder;

/// Server-side cursor for streaming query results.
///
/// Example (AST-native):
/// ```zig
/// const cursor = Cursor.init(&conn, "my_cursor");
/// const declare_sql = try cursor.declareSql(allocator, &query);
///
/// while (try cursor.fetch(100)) |rows| {
///     for (rows) |row| {
///         // Process row
///     }
/// }
///
/// try cursor.close();
/// ```
pub const Cursor = struct {
    name: []const u8,
    allocator: std.mem.Allocator,

    /// Create a new cursor with the given name.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) Cursor {
        return .{
            .name = name,
            .allocator = allocator,
        };
    }

    /// Build DECLARE CURSOR SQL from a QAIL AST command.
    pub fn declareSql(self: *const Cursor, allocator: std.mem.Allocator, query: *const QailCmd) ![]u8 {
        try raw_policy.rejectPublicRuntimeCmd(query);

        var encoder = AstEncoder.init(allocator);
        defer encoder.deinit();
        const query_sql = try encoder.toSqlOwned(allocator, query);
        defer allocator.free(query_sql);

        return cursor_sql.buildDeclare(allocator, self.name, query_sql);
    }

    /// Build FETCH SQL.
    pub fn fetchSql(self: *const Cursor, allocator: std.mem.Allocator, batch_size: usize) ![]u8 {
        return cursor_sql.buildFetch(allocator, self.name, batch_size);
    }

    /// Build CLOSE CURSOR SQL.
    pub fn closeSql(self: *const Cursor, allocator: std.mem.Allocator) ![]u8 {
        return cursor_sql.buildClose(allocator, self.name);
    }
};

// ==================== Tests ====================

test "Cursor SQL generation" {
    const allocator = std.testing.allocator;
    const cursor = Cursor.init(allocator, "test_cursor");

    const query = QailCmd.get("users");
    const declare = try cursor.declareSql(allocator, &query);
    defer allocator.free(declare);
    try std.testing.expectEqualStrings("DECLARE \"test_cursor\" CURSOR FOR SELECT * FROM users", declare);

    const fetch = try cursor.fetchSql(allocator, 100);
    defer allocator.free(fetch);
    try std.testing.expectEqualStrings("FETCH 100 FROM \"test_cursor\"", fetch);

    const close = try cursor.closeSql(allocator);
    defer allocator.free(close);
    try std.testing.expectEqualStrings("CLOSE \"test_cursor\"", close);
}

test "Cursor SQL generation quotes cursor name" {
    const allocator = std.testing.allocator;
    const cursor = Cursor.init(allocator, "c\"; DROP TABLE users; --");

    const fetch = try cursor.fetchSql(allocator, 100);
    defer allocator.free(fetch);
    try std.testing.expectEqualStrings("FETCH 100 FROM \"c\"\"; DROP TABLE users; --\"", fetch);
}
