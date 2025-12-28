//! Column and basic expression builders.
//!
//! Port of qail.rs/qail-core/src/ast/builders/columns.rs

const Expr = @import("../expr.zig").Expr;

/// Create a column reference expression
pub fn col(name: []const u8) Expr {
    return .{ .named = name };
}

/// Create a star (*) expression for SELECT *
pub fn star() Expr {
    return .star;
}

/// Create a parameter placeholder ($n)
/// Returns the formatted string reference - caller should manage buffer if dynamic
pub fn param(comptime n: u32) Expr {
    const num_str = comptime blk: {
        var buf: [16]u8 = undefined;
        const len = std.fmt.formatIntBuf(&buf, n, 10, .lower, .{});
        break :blk "$" ++ buf[0..len];
    };
    return .{ .named = num_str };
}

const std = @import("std");

test "col creates named expression" {
    const expr = col("id");
    try std.testing.expect(expr == .named);
    try std.testing.expectEqualStrings("id", expr.named);
}

test "star creates star expression" {
    const expr = star();
    try std.testing.expect(expr == .star);
}

test "param creates parameter placeholder" {
    const expr = param(1);
    try std.testing.expect(expr == .named);
    try std.testing.expectEqualStrings("$1", expr.named);
}
