//! Binary expression builders.
//!
//! Port of qail.rs/core/src/ast/builders/binary.rs

const Expr = @import("../expr.zig").Expr;
const BinaryOp = @import("../expr.zig").BinaryOp;

/// Create a binary expression (left op right)
pub fn binary(left: *const Expr, op: BinaryOp, right: *const Expr) Expr {
    return .{ .binary = .{ .left = left, .op = op, .right = right } };
}

/// Shorthand: left + right
pub fn add(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .add, right);
}

/// Shorthand: left - right
pub fn sub(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .sub, right);
}

/// Shorthand: left * right
pub fn mul(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .mul, right);
}

/// Shorthand: left / right
pub fn div(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .div, right);
}

/// Shorthand: left || right (string concatenation)
pub fn concat(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .concat, right);
}

/// Shorthand: left AND right
pub fn andExpr(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .@"and", right);
}

/// Shorthand: left OR right
pub fn orExpr(left: *const Expr, right: *const Expr) Expr {
    return binary(left, .@"or", right);
}

const std = @import("std");

test "binary add creates expression" {
    const left = Expr.int(1);
    const right = Expr.int(2);
    const result = add(&left, &right);
    try std.testing.expect(result == .binary);
    try std.testing.expect(result.binary.op == .add);
}

test "concat creates concatenation" {
    const a = Expr.str("hello");
    const b = Expr.str(" world");
    const result = concat(&a, &b);
    try std.testing.expect(result.binary.op == .concat);
}
