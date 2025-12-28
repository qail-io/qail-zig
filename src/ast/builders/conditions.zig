//! Condition builders for WHERE clauses.
//!
//! Port of qail.rs/qail-core/src/ast/builders/conditions.rs

const std = @import("std");
const Expr = @import("../expr.zig").Expr;
const values = @import("../values.zig");
const operators = @import("../operators.zig");

const Value = values.Value;
const Operator = operators.Operator;

/// A filter condition for WHERE clauses
pub const Condition = struct {
    left: Expr,
    op: Operator,
    value: Value,
};

/// Helper to create a condition
fn makeCondition(column: []const u8, op: Operator, value: Value) Condition {
    return .{
        .left = .{ .named = column },
        .op = op,
        .value = value,
    };
}

/// Create an equality condition (column = value)
pub fn eq(column: []const u8, value: Value) Condition {
    return makeCondition(column, .eq, value);
}

/// Create a not-equal condition (column != value)
pub fn ne(column: []const u8, value: Value) Condition {
    return makeCondition(column, .ne, value);
}

/// Create a greater-than condition (column > value)
pub fn gt(column: []const u8, value: Value) Condition {
    return makeCondition(column, .gt, value);
}

/// Create a greater-than-or-equal condition (column >= value)
pub fn gte(column: []const u8, value: Value) Condition {
    return makeCondition(column, .gte, value);
}

/// Create a less-than condition (column < value)
pub fn lt(column: []const u8, value: Value) Condition {
    return makeCondition(column, .lt, value);
}

/// Create a less-than-or-equal condition (column <= value)
pub fn lte(column: []const u8, value: Value) Condition {
    return makeCondition(column, .lte, value);
}

/// Create an IN condition (column IN (values))
pub fn isIn(column: []const u8, vals: []const Value) Condition {
    return .{
        .left = .{ .named = column },
        .op = .in,
        .value = .{ .array = vals },
    };
}

/// Create an IS NULL condition
pub fn isNull(column: []const u8) Condition {
    return makeCondition(column, .is_null, .null_val);
}

/// Create an IS NOT NULL condition
pub fn isNotNull(column: []const u8) Condition {
    return makeCondition(column, .is_not_null, .null_val);
}

/// Create a LIKE condition (column LIKE pattern)
pub fn like(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .like, .{ .string = pattern });
}

test "eq creates equality condition" {
    const cond = eq("status", .{ .string = "active" });
    try std.testing.expect(cond.left == .named);
    try std.testing.expectEqualStrings("status", cond.left.named);
    try std.testing.expect(cond.op == .eq);
}

test "gt creates greater-than condition" {
    const cond = gt("score", .{ .int = 100 });
    try std.testing.expect(cond.op == .gt);
    try std.testing.expect(cond.value.int == 100);
}

test "isNull creates null check" {
    const cond = isNull("deleted_at");
    try std.testing.expect(cond.op == .is_null);
}
