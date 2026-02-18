//! Literal value builders.
//!
//! Port of qail.rs/core/src/ast/builders/literals.rs

const Expr = @import("../expr.zig").Expr;
const Value = @import("../values.zig").Value;

/// Create an integer literal expression
pub fn int(value: i64) Expr {
    return .{ .literal = .{ .int = value } };
}

/// Create a float literal expression
pub fn float(value: f64) Expr {
    return .{ .literal = .{ .float = value } };
}

/// Create a string literal expression
pub fn text(s: []const u8) Expr {
    return .{ .literal = .{ .string = s } };
}

/// Create a boolean literal expression
pub fn boolean(value: bool) Expr {
    return .{ .literal = .{ .bool = value } };
}

/// Create a NULL literal expression
pub fn nullVal() Expr {
    return .{ .literal = .null };
}

/// Create a parameter placeholder ($n)
pub fn param(n: u16) Expr {
    return .{ .literal = .{ .param = n } };
}

const std = @import("std");

test "int creates integer literal" {
    const e = int(42);
    try std.testing.expectEqual(@as(i64, 42), e.literal.int);
}

test "text creates string literal" {
    const e = text("hello");
    try std.testing.expectEqualStrings("hello", e.literal.string);
}

test "boolean creates bool literal" {
    const e = boolean(true);
    try std.testing.expect(e.literal.bool);
}

test "null creates null literal" {
    const e = nullVal();
    try std.testing.expect(e.literal == .null);
}

test "float creates float literal" {
    const e = float(3.14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), e.literal.float, 0.001);
}
