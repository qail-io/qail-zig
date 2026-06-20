// QAIL Values - Literal values for queries
//
// Port of Rust qail-core/src/ast/values.rs

const std = @import("std");
const io = @import("../runtime/io.zig");

const MAX_RAW_FUNCTION_LEN: usize = 1024;

/// Time interval unit for duration expressions
pub const IntervalUnit = enum {
    second,
    minute,
    hour,
    day,
    week,
    month,
    year,

    pub fn toSql(self: IntervalUnit) []const u8 {
        return switch (self) {
            .second => "seconds",
            .minute => "minutes",
            .hour => "hours",
            .day => "days",
            .week => "weeks",
            .month => "months",
            .year => "years",
        };
    }
};

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
    /// Bytes value (bytea)
    bytes: []const u8,
    /// Array of values
    array: []const Value,
    /// Placeholder parameter ($1, $2, etc.)
    param: u16,
    /// Named parameter (:name, :id, etc.)
    named_param: []const u8,
    /// SQL function call (e.g., now(), uuid_generate_v4())
    function: []const u8,
    /// Column reference (e.g., table.column)
    column: []const u8,
    /// UUID value (stored as 36-char string)
    uuid: []const u8,
    /// NULL-typed UUID
    null_uuid,
    /// Time interval (e.g., 24 hours, 7 days)
    interval: struct { amount: i64, unit: IntervalUnit },
    /// Timestamp value (ISO format string)
    timestamp: []const u8,
    /// Range for BETWEEN conditions
    range: struct { low: i64, high: i64 },
    /// Vector embedding for similarity search (Qdrant)
    vector: []const f32,
    /// JSON data
    json: []const u8,

    /// Format value for SQL output
    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("NULL"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| {
                try ensureFiniteFloat64(f);
                try writer.print("{d}", .{f});
            },
            .string => |s| try writeSqlStringLiteral(writer, s),
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
            .named_param => |name| {
                if (!isSafeNamedParam(name)) return error.WriteFailed;
                try writer.print(":{s}", .{name});
            },
            .function => |f| {
                if (!isSafeRawFunctionValue(f)) return error.WriteFailed;
                try writer.writeAll(f);
            },
            .column => |c| {
                if (!isSafeIdentifier(c)) return error.WriteFailed;
                try writer.writeAll(c);
            },
            .uuid => |u| try writeSqlStringLiteral(writer, u),
            .interval => |iv| try writer.print("INTERVAL '{d} {s}'", .{ iv.amount, iv.unit.toSql() }),
            .timestamp => |ts| try writeSqlStringLiteral(writer, ts),
            .range => |r| try writer.print("{d} AND {d}", .{ r.low, r.high }),
            .null_uuid => try writer.writeAll("NULL"),
            .vector => |v| {
                try writer.writeByte('[');
                for (v, 0..) |val, i| {
                    try ensureFiniteFloat32(val);
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{val});
                }
                try writer.writeByte(']');
            },
            .json => |j| {
                try writeSqlStringLiteral(writer, j);
                try writer.writeAll("::jsonb");
            },
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

    pub fn fromColumn(c: []const u8) Value {
        return .{ .column = c };
    }

    pub fn fromFunction(f: []const u8) Value {
        return .{ .function = f };
    }

    pub fn fromUuid(u: []const u8) Value {
        return .{ .uuid = u };
    }

    pub fn fromInterval(amount: i64, unit: IntervalUnit) Value {
        return .{ .interval = .{ .amount = amount, .unit = unit } };
    }

    pub fn fromVector(v: []const f32) Value {
        return .{ .vector = v };
    }

    pub fn fromJson(j: []const u8) Value {
        return .{ .json = j };
    }

    pub fn validateFinite(self: Value) !void {
        switch (self) {
            .float => |f| if (!std.math.isFinite(f)) return error.NonFiniteSqlValue,
            .vector => |v| for (v) |val| {
                if (!std.math.isFinite(val)) return error.NonFiniteSqlValue;
            },
            .array => |arr| for (arr) |value| {
                try value.validateFinite();
            },
            else => {},
        }
    }
};

fn ensureFiniteFloat64(value: f64) error{WriteFailed}!void {
    if (!std.math.isFinite(value)) return error.WriteFailed;
}

fn ensureFiniteFloat32(value: f32) error{WriteFailed}!void {
    if (!std.math.isFinite(value)) return error.WriteFailed;
}

fn isSafeIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    var parts = std.mem.splitScalar(u8, value, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 63) return false;
        for (part) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }
    return true;
}

fn isSafeNamedParam(value: []const u8) bool {
    if (value.len == 0) return false;
    const first = value[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn isSafeRawFunctionValue(value: []const u8) bool {
    return value.len <= MAX_RAW_FUNCTION_LEN and
        std.mem.indexOfScalar(u8, value, 0) == null and
        std.mem.indexOfScalar(u8, value, ';') == null and
        std.mem.indexOf(u8, value, "--") == null and
        std.mem.indexOf(u8, value, "/*") == null and
        std.mem.indexOf(u8, value, "*/") == null;
}

fn writeSqlStringLiteral(writer: anytype, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| {
        if (c == 0) return error.WriteFailed;
        if (c == '\'') {
            try writer.writeAll("''");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('\'');
}

// Tests
test "value format null" {
    var buf: [64]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&buf);
    const v: Value = .null;
    try writer.writer().print("{f}", .{v});
    try std.testing.expectEqualStrings("NULL", writer.getWritten());
}

test "value format string escapes quotes" {
    var buf: [64]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&buf);
    const v: Value = .{ .string = "it's" };
    try writer.writer().print("{f}", .{v});
    try std.testing.expectEqualStrings("'it''s'", writer.getWritten());

    var nul_writer = io.FixedBufferWriter.init(&buf);
    try std.testing.expectError(error.WriteFailed, (Value{ .string = "bad\x00value" }).format(nul_writer.writer()));
}

test "value format string-like variants escape quotes" {
    var buf: [128]u8 = undefined;

    var uuid_writer = io.FixedBufferWriter.init(&buf);
    try (Value{ .uuid = "x'; DROP TABLE users; --" }).format(uuid_writer.writer());
    try std.testing.expectEqualStrings("'x''; DROP TABLE users; --'", uuid_writer.getWritten());

    var ts_writer = io.FixedBufferWriter.init(&buf);
    try (Value{ .timestamp = "2026-01-01T00:00:00Z'; DROP TABLE users; --" }).format(ts_writer.writer());
    try std.testing.expectEqualStrings("'2026-01-01T00:00:00Z''; DROP TABLE users; --'", ts_writer.getWritten());

    var json_writer = io.FixedBufferWriter.init(&buf);
    try (Value{ .json = "{\"x\":\"O'Brien\"}" }).format(json_writer.writer());
    try std.testing.expectEqualStrings("'{\"x\":\"O''Brien\"}'::jsonb", json_writer.getWritten());
}

test "value format param" {
    var buf: [64]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&buf);
    const v: Value = .{ .param = 1 };
    try v.format(writer.writer());
    try std.testing.expectEqualStrings("$1", writer.getWritten());
}

test "value format validates named parameters" {
    var buf: [64]u8 = undefined;

    var ok_writer = io.FixedBufferWriter.init(&buf);
    try (Value{ .named_param = "_user_id1" }).format(ok_writer.writer());
    try std.testing.expectEqualStrings(":_user_id1", ok_writer.getWritten());

    var bad_writer = io.FixedBufferWriter.init(&buf);
    try std.testing.expectError(error.WriteFailed, (Value{ .named_param = "1bad" }).format(bad_writer.writer()));
}

test "value format validates raw function fragments" {
    var buf: [64]u8 = undefined;

    var ok_writer = io.FixedBufferWriter.init(&buf);
    try (Value{ .function = "now()" }).format(ok_writer.writer());
    try std.testing.expectEqualStrings("now()", ok_writer.getWritten());

    var bad_writer = io.FixedBufferWriter.init(&buf);
    try std.testing.expectError(error.WriteFailed, (Value{ .function = "now(); DROP TABLE users; --" }).format(bad_writer.writer()));
}

test "value format validates column references" {
    var buf: [64]u8 = undefined;

    var ok_writer = io.FixedBufferWriter.init(&buf);
    try (Value{ .column = "users.id" }).format(ok_writer.writer());
    try std.testing.expectEqualStrings("users.id", ok_writer.getWritten());

    var bad_writer = io.FixedBufferWriter.init(&buf);
    try std.testing.expectError(error.WriteFailed, (Value{ .column = "users..id" }).format(bad_writer.writer()));
}

test "value format rejects non-finite floats and vectors" {
    var buf: [64]u8 = undefined;

    try std.testing.expectError(error.NonFiniteSqlValue, (Value{ .float = std.math.nan(f64) }).validateFinite());

    var nan_writer = io.FixedBufferWriter.init(&buf);
    try std.testing.expectError(error.WriteFailed, (Value{ .float = std.math.nan(f64) }).format(nan_writer.writer()));

    const vector = [_]f32{ 1.0, std.math.inf(f32) };
    try std.testing.expectError(error.NonFiniteSqlValue, (Value{ .vector = &vector }).validateFinite());

    var vector_writer = io.FixedBufferWriter.init(&buf);
    try std.testing.expectError(error.WriteFailed, (Value{ .vector = &vector }).format(vector_writer.writer()));
}

// ==================== Comptime Exhaustive Tests ====================

test "property: all IntervalUnit variants produce non-empty SQL" {
    inline for (std.meta.fields(IntervalUnit)) |field| {
        const v: IntervalUnit = @enumFromInt(field.value);
        const sql = v.toSql();
        try std.testing.expect(sql.len > 0);
    }
}

test "property: Value.format covers all variants" {
    var buf: [256]u8 = undefined;

    // Test each Value variant produces output
    const test_values = [_]Value{
        .null,
        .{ .bool = true },
        .{ .int = 42 },
        .{ .float = 3.14 },
        .{ .string = "hello" },
        .{ .bytes = &[_]u8{ 0xDE, 0xAD } },
        .{ .array = &[_]Value{.{ .int = 1 }} },
        .{ .param = 1 },
        .{ .named_param = "user_id" },
        .{ .function = "now()" },
        .{ .column = "users.id" },
        .{ .uuid = "550e8400-e29b-41d4-a716-446655440000" },
        .null_uuid,
        .{ .interval = .{ .amount = 24, .unit = .hour } },
        .{ .timestamp = "2026-01-01T00:00:00Z" },
        .{ .range = .{ .low = 1, .high = 10 } },
        .{ .vector = &[_]f32{ 0.1, 0.2, 0.3 } },
        .{ .json = "{\"key\":\"value\"}" },
    };

    for (test_values) |val| {
        var writer = io.FixedBufferWriter.init(&buf);
        try val.format(writer.writer());
        try std.testing.expect(writer.getWritten().len > 0);
    }
}
