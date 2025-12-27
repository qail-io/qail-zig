//! PostgreSQL Row
//!
//! Represents a row of data returned from a query.

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const types = protocol.types;

/// A row of data from PostgreSQL
pub const PgRow = struct {
    columns: []?[]const u8,
    field_names: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PgRow) void {
        self.allocator.free(self.columns);
    }

    /// Get column value by index as string
    pub fn getString(self: *const PgRow, index: usize) ?[]const u8 {
        if (index >= self.columns.len) return null;
        return self.columns[index];
    }

    /// Get column value by name as string
    pub fn getByName(self: *const PgRow, name: []const u8) ?[]const u8 {
        for (self.field_names, 0..) |field_name, i| {
            if (std.mem.eql(u8, field_name, name)) {
                return self.columns[i];
            }
        }
        return null;
    }

    /// Get column value as i32
    pub fn getInt32(self: *const PgRow, index: usize) ?i32 {
        const str = self.getString(index) orelse return null;
        return types.textToInt32(str) catch null;
    }

    /// Get column value as i64
    pub fn getInt64(self: *const PgRow, index: usize) ?i64 {
        const str = self.getString(index) orelse return null;
        return types.textToInt64(str) catch null;
    }

    /// Get column value as f64
    pub fn getFloat64(self: *const PgRow, index: usize) ?f64 {
        const str = self.getString(index) orelse return null;
        return types.textToFloat64(str) catch null;
    }

    /// Get column value as bool
    pub fn getBool(self: *const PgRow, index: usize) ?bool {
        const str = self.getString(index) orelse return null;
        return types.textToBool(str);
    }
};

// Tests
test "pgrow getString" {
    const columns = [_]?[]const u8{ "hello", "world", null };
    const names = [_][]const u8{ "a", "b", "c" };
    const row = PgRow{
        .columns = @constCast(&columns),
        .field_names = &names,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqualStrings("hello", row.getString(0).?);
    try std.testing.expectEqualStrings("world", row.getString(1).?);
    try std.testing.expect(row.getString(2) == null);
}

test "pgrow getByName" {
    const columns = [_]?[]const u8{ "42", "test" };
    const names = [_][]const u8{ "id", "name" };
    const row = PgRow{
        .columns = @constCast(&columns),
        .field_names = &names,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqualStrings("42", row.getByName("id").?);
    try std.testing.expectEqualStrings("test", row.getByName("name").?);
    try std.testing.expect(row.getByName("unknown") == null);
}

test "pgrow getInt32" {
    const columns = [_]?[]const u8{"42"};
    const names = [_][]const u8{"num"};
    const row = PgRow{
        .columns = @constCast(&columns),
        .field_names = &names,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(@as(i32, 42), row.getInt32(0).?);
}
