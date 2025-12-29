//! Condition builders for WHERE clauses.
//!
//! Port of qail.rs/qail-core/src/ast/builders/conditions.rs

const std = @import("std");
const expr = @import("../expr.zig");
const values = @import("../values.zig");
const operators = @import("../operators.zig");

const Expr = expr.Expr;
const Value = values.Value;
const Operator = operators.Operator;

// Re-export Condition from expr.zig to avoid type mismatch
pub const Condition = expr.Condition;

/// Helper to create a condition
fn makeCondition(column: []const u8, op: Operator, value: Value) Condition {
    return .{
        .column = column,
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

/// Create a NOT LIKE condition (column NOT LIKE pattern)
pub fn notLike(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .not_like, .{ .string = pattern });
}

/// Create an ILIKE condition (case-insensitive LIKE)
pub fn ilike(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .ilike, .{ .string = pattern });
}

/// Create a NOT ILIKE condition
pub fn notIlike(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .not_ilike, .{ .string = pattern });
}

/// Create a regex match condition (column ~ pattern)
pub fn regex(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .regex, .{ .string = pattern });
}

/// Create a case-insensitive regex condition (column ~* pattern)
pub fn regexI(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .regex_i, .{ .string = pattern });
}

/// Create a SIMILAR TO condition
pub fn similarTo(column: []const u8, pattern: []const u8) Condition {
    return makeCondition(column, .similar_to, .{ .string = pattern });
}

/// Create a BETWEEN condition (column BETWEEN low AND high)
pub fn between(column: []const u8, low: i64, high: i64) Condition {
    return .{
        .left = .{ .named = column },
        .op = .between,
        .value = .{ .range = .{ .low = low, .high = high } },
    };
}

/// Create a NOT BETWEEN condition
pub fn notBetween(column: []const u8, low: i64, high: i64) Condition {
    return .{
        .left = .{ .named = column },
        .op = .not_between,
        .value = .{ .range = .{ .low = low, .high = high } },
    };
}

/// Create a NOT IN condition (column NOT IN (values))
pub fn notIn(column: []const u8, vals: []const Value) Condition {
    return .{
        .left = .{ .named = column },
        .op = .not_in,
        .value = .{ .array = vals },
    };
}

/// Create an array contains condition (column @> array)
pub fn contains(column: []const u8, vals: []const Value) Condition {
    return .{
        .left = .{ .named = column },
        .op = .contains,
        .value = .{ .array = vals },
    };
}

/// Create an array overlaps condition (column && array)
pub fn overlaps(column: []const u8, vals: []const Value) Condition {
    return .{
        .left = .{ .named = column },
        .op = .overlaps,
        .value = .{ .array = vals },
    };
}

/// Create a JSON key exists condition (column ? key)
pub fn keyExists(column: []const u8, key: []const u8) Condition {
    return makeCondition(column, .key_exists, .{ .string = key });
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
