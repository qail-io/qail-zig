//! PostgreSQL Row
//!
//! Represents a row of data returned from a query.
//! Provides typed access to column values, similar to pg.zig.

const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const pg_types = @import("types/mod.zig");
const types = protocol.types;

/// A row of data from PostgreSQL
pub const PgRow = struct {
    columns: []?[]const u8,
    field_names: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PgRow) void {
        self.allocator.free(self.columns);
    }

    /// Generic typed getter by column index
    /// Usage: row.get(i32, 0), row.get([]const u8, 1)
    pub fn get(self: *const PgRow, comptime T: type, index: usize) ?T {
        const raw = self.getString(index) orelse return null;
        return parseAs(T, raw);
    }

    /// Generic typed getter by column name
    /// Usage: row.getCol(i32, "id"), row.getCol([]const u8, "name")
    pub fn getCol(self: *const PgRow, comptime T: type, name: []const u8) ?T {
        const raw = self.getByName(name) orelse return null;
        return parseAs(T, raw);
    }

    /// Parse raw bytes as type T
    fn parseAs(comptime T: type, raw: []const u8) ?T {
        if (T == []const u8) {
            return raw;
        } else if (T == i16) {
            return std.fmt.parseInt(i16, raw, 10) catch null;
        } else if (T == i32) {
            return std.fmt.parseInt(i32, raw, 10) catch null;
        } else if (T == i64) {
            return std.fmt.parseInt(i64, raw, 10) catch null;
        } else if (T == u32) {
            return std.fmt.parseInt(u32, raw, 10) catch null;
        } else if (T == f32) {
            return std.fmt.parseFloat(f32, raw) catch null;
        } else if (T == f64) {
            return std.fmt.parseFloat(f64, raw) catch null;
        } else if (T == bool) {
            if (raw.len == 0) return null;
            return raw[0] == 't' or raw[0] == 'T' or raw[0] == '1';
        } else if (T == pg_types.Uuid) {
            if (raw.len == 16) {
                return pg_types.Uuid.fromBytes(raw[0..16].*);
            } else if (raw.len == 36) {
                return pg_types.Uuid.fromHex(raw) catch null;
            }
            return null;
        } else if (T == pg_types.Timestamp) {
            // Parse microseconds from text
            const micros = std.fmt.parseInt(i64, raw, 10) catch return null;
            return pg_types.Timestamp.fromMicros(micros);
        } else {
            @compileError("Unsupported type for PgRow.get(): " ++ @typeName(T));
        }
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
        return self.get(i32, index);
    }

    /// Get column value as i64
    pub fn getInt64(self: *const PgRow, index: usize) ?i64 {
        return self.get(i64, index);
    }

    /// Get column value as f64
    pub fn getFloat64(self: *const PgRow, index: usize) ?f64 {
        return self.get(f64, index);
    }

    /// Get column value as bool
    pub fn getBool(self: *const PgRow, index: usize) ?bool {
        return self.get(bool, index);
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
