//! JSON access builders for PostgreSQL JSONB operations.
//!
//! Port of qail.rs/core/src/ast/builders/json.rs

const Expr = @import("../expr.zig").Expr;
const JsonPathSegment = @import("../expr.zig").JsonPathSegment;

/// JSON text access (column->>'key')
/// Example: json("contact_info", "phone") → contact_info->>'phone'
pub fn json(column: []const u8, key: []const u8) Expr {
    return .{ .json_access = .{
        .column = column,
        .path = &[_]JsonPathSegment{.{ .key = key, .as_text = true }},
    } };
}

/// JSON object access (column->'key') — keeps as JSONB, not text
pub fn jsonObj(column: []const u8, key: []const u8) Expr {
    return .{ .json_access = .{
        .column = column,
        .path = &[_]JsonPathSegment{.{ .key = key, .as_text = false }},
    } };
}

/// JSON path access with two keys (column->'a'->>'b')
/// Last key extracts as text.
pub fn jsonPath2(column: []const u8, key1: []const u8, key2: []const u8) Expr {
    return .{ .json_access = .{
        .column = column,
        .path = &[_]JsonPathSegment{
            .{ .key = key1, .as_text = false },
            .{ .key = key2, .as_text = true },
        },
    } };
}

/// JSON path access with three keys (column->'a'->'b'->>'c')
pub fn jsonPath3(column: []const u8, k1: []const u8, k2: []const u8, k3: []const u8) Expr {
    return .{ .json_access = .{
        .column = column,
        .path = &[_]JsonPathSegment{
            .{ .key = k1, .as_text = false },
            .{ .key = k2, .as_text = false },
            .{ .key = k3, .as_text = true },
        },
    } };
}

const std = @import("std");

test "json creates json_access expression" {
    const e = json("contact", "phone");
    try std.testing.expect(e == .json_access);
    try std.testing.expectEqualStrings("contact", e.json_access.column);
}

test "jsonObj creates json_access expression" {
    const e = jsonObj("metadata", "config");
    try std.testing.expect(e == .json_access);
    try std.testing.expectEqualStrings("metadata", e.json_access.column);
}

test "jsonPath2 creates json_access expression" {
    const e = jsonPath2("data", "booking", "departure");
    try std.testing.expect(e == .json_access);
    try std.testing.expectEqualStrings("data", e.json_access.column);
}

test "comptime json preserves path" {
    comptime {
        const e = json("contact", "phone");
        if (e.json_access.path.len != 1) @compileError("expected 1 path segment");
        if (!e.json_access.path[0].as_text) @compileError("expected as_text=true");
    }
}
