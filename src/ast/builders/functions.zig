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
