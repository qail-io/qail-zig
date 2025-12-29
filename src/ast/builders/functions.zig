//! Function call builders.
//!
//! Port of qail.rs/qail-core/src/ast/builders/functions.rs

const std = @import("std");
const Expr = @import("../expr.zig").Expr;

/// Create a COALESCE expression from a slice of expressions
pub fn coalesceSlice(exprs: []const Expr) Expr {
    return .{
        .coalesce = .{
            .exprs = exprs,
            .alias = null,
        },
    };
}

/// Create a NULLIF(expr, value) expression
pub fn nullif(expr: Expr, value: Expr) Expr {
    return .{
        .func_call = .{
            .name = "NULLIF",
            .args = &[_]Expr{ expr, value },
            .alias = null,
        },
    };
}

/// Create a generic function call
pub fn funcCall(name: []const u8, args: []const Expr) Expr {
    return .{
        .func_call = .{
            .name = name,
            .args = args,
            .alias = null,
        },
    };
}

/// Create NOW() expression
pub fn now() Expr {
    return .{ .func_call = .{ .name = "NOW", .args = &.{} } };
}

/// Create NOW() - INTERVAL expression
pub fn nowMinus(interval_str: []const u8) Expr {
    // This creates a binary expression: NOW() - INTERVAL 'x'
    return .{
        .special_func = .{
            .name = "NOW_MINUS",
            .args = &[_]SpecialFuncArg{
                .{ .keyword = null, .expr = &Expr{ .literal = .{ .string = interval_str } } },
            },
        },
    };
}

/// Create NOW() + INTERVAL expression
pub fn nowPlus(interval_str: []const u8) Expr {
    return .{
        .special_func = .{
            .name = "NOW_PLUS",
            .args = &[_]SpecialFuncArg{
                .{ .keyword = null, .expr = &Expr{ .literal = .{ .string = interval_str } } },
            },
        },
    };
}

/// Create a text literal expression (for use in CASE, COALESCE, etc.)
pub fn text(s: []const u8) Expr {
    return .{ .literal = .{ .string = s } };
}

/// Create COUNT(DISTINCT column) aggregate
pub fn countDistinct(column: []const u8) Expr {
    return .{ .aggregate = .{ .func = .count, .column = column, .distinct = true } };
}

/// Create ARRAY_AGG(column) aggregate
pub fn arrayAgg(column: []const u8) Expr {
    return .{ .aggregate = .{ .func = .array_agg, .column = column } };
}

/// Create STRING_AGG(column, separator) expression
pub fn stringAgg(column: Expr, separator: []const u8) Expr {
    return .{
        .func_call = .{
            .name = "STRING_AGG",
            .args = &[_]Expr{ column, .{ .literal = .{ .string = separator } } },
        },
    };
}

/// Create JSON_AGG(column) aggregate
pub fn jsonAgg(column: []const u8) Expr {
    return .{ .aggregate = .{ .func = .json_agg, .column = column } };
}

/// Create a CASE WHEN expression
pub fn caseWhen(condition: @import("conditions.zig").Condition, result: Expr) CaseBuilder {
    return CaseBuilder{
        .when_clauses = &[_]WhenClause{.{ .condition = condition, .result = result }},
        .else_value = null,
    };
}

/// Builder for CASE expressions
pub const CaseBuilder = struct {
    when_clauses: []const WhenClause,
    else_value: ?*const Expr,

    /// Add ELSE clause
    pub fn otherwise(self: CaseBuilder, else_expr: *const Expr) Expr {
        return .{
            .case_expr = .{
                .when_clauses = self.when_clauses,
                .else_value = else_expr,
            },
        };
    }

    /// Build without ELSE
    pub fn build(self: CaseBuilder) Expr {
        return .{
            .case_expr = .{
                .when_clauses = self.when_clauses,
                .else_value = self.else_value,
            },
        };
    }
};

const WhenClause = @import("../expr.zig").WhenClause;
const SpecialFuncArg = @import("../expr.zig").SpecialFuncArg;

test "coalesceSlice creates coalesce expression" {
    const columns = @import("columns.zig");
    const exprs = [_]Expr{
        columns.col("name"),
        .{ .literal = .{ .string = "Unknown" } },
    };
    const expr = coalesceSlice(&exprs);
    try std.testing.expect(expr == .coalesce);
    try std.testing.expect(expr.coalesce.exprs.len == 2);
}

test "nullif creates function call" {
    const columns = @import("columns.zig");
    const expr = nullif(columns.col("value"), .{ .literal = .{ .string = "" } });
    try std.testing.expect(expr == .func_call);
    try std.testing.expectEqualStrings("NULLIF", expr.func_call.name);
}
