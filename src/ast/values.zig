//! QAIL Values - Literal values for queries
//!
//! Port of Rust qail-core/src/ast/values.rs

const std = @import("std");

/// A literal value in a query
pub const Value = union(enum) {
    /// NULL value
    null,
    /// Boolean value
    bool: bool,
    /// Integer value
    int: i64,
    /// Float value
    float: f64,
    /// String value (borrowed)
    string: []const u8,
    /// Bytes value
    bytes: []const u8,
    /// Array of values
    array: []const Value,
    /// Placeholder parameter ($1, $2, etc.)
    param: u16,

    /// Format value for SQL output (Zig 0.15+ signature)
    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("NULL"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| {
                try writer.writeByte('\'');
                for (s) |c| {
                    if (c == '\'') {
                        try writer.writeAll("''");
                    } else {
                        try writer.writeByte(c);
                    }
                }
                try writer.writeByte('\'');
            },
            .bytes => |b| {
                try writer.writeAll("'\\x");
                for (b) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
                try writer.writeByte('\'');
            },
            .array => |arr| {
                try writer.writeAll("ARRAY[");
                for (arr, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.format(writer);
                }
                try writer.writeByte(']');
            },
            .param => |p| try writer.print("${d}", .{p}),
        }
    }

    /// Create helpers
    pub fn fromInt(i: i64) Value {
        return .{ .int = i };
    }

    pub fn fromFloat(f: f64) Value {
        return .{ .float = f };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .bool = b };
    }

    pub fn fromString(s: []const u8) Value {
        return .{ .string = s };
    }
};

// Tests
test "value format null" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const v: Value = .null;
    try std.fmt.format(fbs.writer(), "{f}", .{v});
    try std.testing.expectEqualStrings("NULL", fbs.getWritten());
}

test "value format string escapes quotes" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const v: Value = .{ .string = "it's" };
    try std.fmt.format(fbs.writer(), "{f}", .{v});
    try std.testing.expectEqualStrings("'it''s'", fbs.getWritten());
}

test "value format param" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const v: Value = .{ .param = 1 };
    try std.fmt.format(fbs.writer(), "{f}", .{v});
    try std.testing.expectEqualStrings("$1", fbs.getWritten());
}
