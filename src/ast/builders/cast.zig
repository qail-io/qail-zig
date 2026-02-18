//! Type casting builder.
//!
//! Port of qail.rs/core/src/ast/builders/cast.rs

const Expr = @import("../expr.zig").Expr;

/// Cast expression to target type (expr::type in Postgres)
pub fn cast(expr: *const Expr, target_type: []const u8) Expr {
    return .{ .cast = .{ .expr = expr, .target_type = target_type } };
}

const std = @import("std");

test "cast creates cast expression" {
    const inner = Expr.col("value");
    const result = cast(&inner, "float8");
    try std.testing.expect(result == .cast);
    try std.testing.expectEqualStrings("float8", result.cast.target_type);
}
