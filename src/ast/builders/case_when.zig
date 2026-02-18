//! CASE WHEN expression builders.
//!
//! Port of qail.rs/core/src/ast/builders/case_when.rs

const Expr = @import("../expr.zig").Expr;
const Condition = @import("../expr.zig").Condition;
const WhenClause = @import("../expr.zig").WhenClause;

/// Create a CASE WHEN expression with a single when clause.
/// Use the returned Expr directly, or chain with more when clauses
/// by constructing the case_expr variant directly.
///
/// CASE WHEN condition THEN result [ELSE else_value] END
pub fn caseWhen(when_clauses: []const WhenClause, else_value: ?*const Expr) Expr {
    return .{ .case_expr = .{
        .when_clauses = when_clauses,
        .else_value = else_value,
    } };
}

/// Create a simple CASE WHEN cond THEN result END
pub fn simpleCase(condition: Condition, result: Expr) Expr {
    return caseWhen(
        &[_]WhenClause{.{ .condition = condition, .result = result }},
        null,
    );
}

/// Create a CASE WHEN cond THEN result ELSE else_val END
pub fn simpleCaseElse(condition: Condition, result: Expr, else_val: *const Expr) Expr {
    return caseWhen(
        &[_]WhenClause{.{ .condition = condition, .result = result }},
        else_val,
    );
}

const std = @import("std");
const operators = @import("../operators.zig");
const Value = @import("../values.zig").Value;

test "caseWhen creates case expression" {
    const clause = WhenClause{
        .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } },
        .result = Expr.int(1),
    };
    const e = caseWhen(&[_]WhenClause{clause}, null);
    try std.testing.expect(e == .case_expr);
    try std.testing.expect(e.case_expr.when_clauses.len == 1);
}

test "simpleCase creates single-clause case" {
    const e = simpleCase(
        .{ .column = "x", .op = .gt, .value = .{ .int = 0 } },
        Expr.int(1),
    );
    try std.testing.expect(e == .case_expr);
    try std.testing.expect(e.case_expr.else_value == null);
}
