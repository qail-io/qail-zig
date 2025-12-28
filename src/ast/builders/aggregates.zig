//! Aggregate function builders.
//!
//! Port of qail.rs/qail-core/src/ast/builders/aggregates.rs

const std = @import("std");
const Expr = @import("../expr.zig").Expr;
const operators = @import("../operators.zig");

const AggregateFunc = operators.AggregateFunc;

/// Create a COUNT(column) expression
pub fn count(column: []const u8) Expr {
    return .{
        .aggregate = .{
            .func = .count,
            .column = column,
            .distinct = false,
            .alias = null,
        },
    };
}

/// Create a COUNT(DISTINCT column) expression
pub fn countDistinct(column: []const u8) Expr {
    return .{
        .aggregate = .{
            .func = .count,
            .column = column,
            .distinct = true,
            .alias = null,
        },
    };
}

/// Create a SUM(column) expression
pub fn sum(column: []const u8) Expr {
    return .{
        .aggregate = .{
            .func = .sum,
            .column = column,
            .distinct = false,
            .alias = null,
        },
    };
}

/// Create an AVG(column) expression
pub fn avg(column: []const u8) Expr {
    return .{
        .aggregate = .{
            .func = .avg,
            .column = column,
            .distinct = false,
            .alias = null,
        },
    };
}

/// Create a MIN(column) expression
pub fn min(column: []const u8) Expr {
    return .{
        .aggregate = .{
            .func = .min,
            .column = column,
            .distinct = false,
            .alias = null,
        },
    };
}

/// Create a MAX(column) expression
pub fn max(column: []const u8) Expr {
    return .{
        .aggregate = .{
            .func = .max,
            .column = column,
            .distinct = false,
            .alias = null,
        },
    };
}

test "count creates aggregate expression" {
    const expr = count("*");
    try std.testing.expect(expr == .aggregate);
    try std.testing.expect(expr.aggregate.func == .count);
    try std.testing.expectEqualStrings("*", expr.aggregate.column);
}

test "countDistinct sets distinct flag" {
    const expr = countDistinct("user_id");
    try std.testing.expect(expr.aggregate.distinct == true);
}

test "sum creates sum aggregate" {
    const expr = sum("amount");
    try std.testing.expect(expr.aggregate.func == .sum);
}
