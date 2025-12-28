// QAIL Cages - Constraint blocks for queries
//
// Port of Rust qail-core/src/ast/cages.rs
// Cages represent different types of query constraints:
// filters (WHERE), sorts (ORDER BY), limits, etc.

const std = @import("std");
const operators = @import("operators.zig");
const expr = @import("expr.zig");

const LogicalOp = operators.LogicalOp;
const SortOrder = operators.SortOrder;
const Condition = expr.Condition;

/// A cage (constraint block) in the query.
/// Cages group conditions together with a logical operator.
pub const Cage = struct {
    kind: CageKind,
    conditions: []const Condition = &.{},
    logical_op: LogicalOp = .@"and",
};

/// The type of cage - determines how it's rendered to SQL.
pub const CageKind = union(enum) {
    /// WHERE filter
    filter,
    /// SET payload (for updates)
    payload,
    /// ORDER BY - stores sort direction
    sort: SortOrder,
    /// LIMIT n
    limit: usize,
    /// OFFSET n
    offset: usize,
    /// TABLESAMPLE - percentage of rows
    sample: usize,
    /// QUALIFY - filter on window function results
    qualify,
    /// PARTITION BY - window function partitioning
    partition,
    /// GROUP BY
    group_by,
};

// ==================== Tests ====================

test "cage kind filter" {
    const cage = Cage{ .kind = .filter };
    try std.testing.expect(cage.kind == .filter);
}

test "cage kind limit" {
    const cage = Cage{ .kind = .{ .limit = 10 } };
    try std.testing.expectEqual(@as(usize, 10), cage.kind.limit);
}

test "cage kind sort" {
    const cage = Cage{ .kind = .{ .sort = .desc } };
    try std.testing.expect(cage.kind.sort == .desc);
}
