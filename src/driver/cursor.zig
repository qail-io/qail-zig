//! Server-side cursor for streaming large result sets.
//!
//! Uses PostgreSQL DECLARE CURSOR to avoid loading all rows into memory.
//! Port of qail.rs/qail-pg/src/driver/cursor.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const QailCmd = ast.QailCmd;

/// Server-side cursor for streaming query results.
///
/// Example (AST-native):
/// ```zig
/// const cursor = Cursor.init(&conn, "my_cursor");
/// try cursor.declare("SELECT * FROM large_table");
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

    /// Build DECLARE CURSOR SQL.
    pub fn declareSql(self: *const Cursor, allocator: std.mem.Allocator, query_sql: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "DECLARE {s} CURSOR FOR {s}", .{ self.name, query_sql });
    }

    /// Build FETCH SQL.
    pub fn fetchSql(self: *const Cursor, allocator: std.mem.Allocator, batch_size: usize) ![]u8 {
        return std.fmt.allocPrint(allocator, "FETCH {d} FROM {s}", .{ batch_size, self.name });
    }

    /// Build CLOSE CURSOR SQL.
    pub fn closeSql(self: *const Cursor, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "CLOSE {s}", .{self.name});
    }

    /// Create QailCmd for declaring cursor (AST-native).
    pub fn declareCmd(self: *const Cursor, query: *const QailCmd) QailCmd {
        _ = query; // Future: embed query in cursor command
        return QailCmd.raw(self.name); // Placeholder - actual impl uses SQL
    }
};

// ==================== Tests ====================

test "Cursor SQL generation" {
    const allocator = std.testing.allocator;
    const cursor = Cursor.init(allocator, "test_cursor");

    const declare = try cursor.declareSql(allocator, "SELECT * FROM users");
    defer allocator.free(declare);
    try std.testing.expectEqualStrings("DECLARE test_cursor CURSOR FOR SELECT * FROM users", declare);

    const fetch = try cursor.fetchSql(allocator, 100);
    defer allocator.free(fetch);
    try std.testing.expectEqualStrings("FETCH 100 FROM test_cursor", fetch);

    const close = try cursor.closeSql(allocator);
    defer allocator.free(close);
    try std.testing.expectEqualStrings("CLOSE test_cursor", close);
}
