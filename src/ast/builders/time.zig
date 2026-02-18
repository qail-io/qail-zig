//! Time function builders (NOW, INTERVAL, etc.)
//!
//! Port of qail.rs/core/src/ast/builders/time.rs

const Expr = @import("../expr.zig").Expr;
const BinaryOp = @import("../expr.zig").BinaryOp;
const Value = @import("../values.zig").Value;
const IntervalUnit = @import("../values.zig").IntervalUnit;

/// NOW() function call
pub fn now() Expr {
    return .{ .func_call = .{ .name = "NOW", .args = &.{} } };
}

/// INTERVAL expression using typed amount + unit
pub fn interval(amount: i64, unit: IntervalUnit) Expr {
    return .{ .literal = .{ .interval = .{ .amount = amount, .unit = unit } } };
}

/// NOW() - INTERVAL 'duration'
pub fn nowMinus(amount: i64, unit: IntervalUnit) Expr {
    const left = now();
    const right = interval(amount, unit);
    return .{ .binary = .{
        .left = &left,
        .op = .sub,
        .right = &right,
    } };
}

/// NOW() + INTERVAL 'duration'
pub fn nowPlus(amount: i64, unit: IntervalUnit) Expr {
    const left = now();
    const right = interval(amount, unit);
    return .{ .binary = .{
        .left = &left,
        .op = .add,
        .right = &right,
    } };
}

const std = @import("std");

test "now creates function call" {
    const e = now();
    try std.testing.expect(e == .func_call);
    try std.testing.expectEqualStrings("NOW", e.func_call.name);
}

test "interval creates literal" {
    const e = interval(24, .hour);
    try std.testing.expect(e == .literal);
    try std.testing.expectEqual(@as(i64, 24), e.literal.interval.amount);
}
