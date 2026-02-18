//! Ergonomic shortcuts for common query patterns.
//!
//! Port of qail.rs/core/src/ast/builders/shortcuts.rs

const Expr = @import("../expr.zig").Expr;
const BinaryOp = @import("../expr.zig").BinaryOp;
const Condition = @import("../expr.zig").Condition;
const Value = @import("../values.zig").Value;
const Operator = @import("../operators.zig").Operator;

/// column IS NOT NULL as a binary expression
pub fn isNotNullExpr(column: []const u8) Expr {
    const left = Expr.col(column);
    const right = Expr{ .literal = .null };
    return .{ .binary = .{
        .left = &left,
        .op = .is_not_null,
        .right = &right,
    } };
}

/// column IS NULL as a binary expression
pub fn isNullExpr(column: []const u8) Expr {
    const left = Expr.col(column);
    const right = Expr{ .literal = .null };
    return .{ .binary = .{
        .left = &left,
        .op = .is_null,
        .right = &right,
    } };
}

/// Combine conditions into a slice (all conditions AND'd in WHERE)
pub fn all(conditions: []const Condition) []const Condition {
    return conditions;
}

/// Create an IN-list condition from string values
pub fn inList(column: []const u8, vals: []const Value) Condition {
    return .{
        .column = column,
        .op = .in,
        .value = .{ .array = vals },
    };
}

const std = @import("std");

test "isNotNullExpr creates IS NOT NULL" {
    const e = isNotNullExpr("photo_url");
    try std.testing.expect(e == .binary);
    try std.testing.expect(e.binary.op == .is_not_null);
}

test "isNullExpr creates IS NULL" {
    const e = isNullExpr("deleted_at");
    try std.testing.expect(e == .binary);
    try std.testing.expect(e.binary.op == .is_null);
}

test "inList creates IN condition" {
    const vals = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const cond = inList("status", &vals);
    try std.testing.expect(cond.op == .in);
}
