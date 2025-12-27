//! QAIL Command - The primary query command structure
//!
//! Port of Rust qail-core/src/ast/cmd.rs

const std = @import("std");
const expr = @import("expr.zig");
const operators = @import("operators.zig");
const values = @import("values.zig");

const Expr = expr.Expr;
const Condition = expr.Condition;
const Operator = operators.Operator;
const SortOrder = operators.SortOrder;
const LogicalOp = operators.LogicalOp;
const Value = values.Value;

/// Command type (GET, SET, DEL, ADD, etc.)
pub const CmdKind = enum {
    // Query operations
    get, // SELECT
    set, // UPDATE
    del, // DELETE
    add, // INSERT
    put, // UPSERT (INSERT ON CONFLICT)

    // Schema operations
    make, // CREATE TABLE
    truncate, // TRUNCATE

    // Transaction control
    begin, // BEGIN TRANSACTION
    commit, // COMMIT
    rollback, // ROLLBACK
    savepoint, // SAVEPOINT name
    release, // RELEASE SAVEPOINT name
    rollback_to, // ROLLBACK TO SAVEPOINT name

    // Pub/Sub (LISTEN/NOTIFY)
    listen, // LISTEN channel
    notify, // NOTIFY channel, 'payload'
    unlisten, // UNLISTEN channel

    // Analysis
    explain, // EXPLAIN
    explain_analyze, // EXPLAIN ANALYZE

    // Bulk operations
    raw, // Raw SQL passthrough
    copy_out, // COPY TO STDOUT (bulk export)

    // Table operations
    lock_table, // LOCK TABLE

    // Materialized views
    create_materialized_view, // CREATE MATERIALIZED VIEW
    refresh_materialized_view, // REFRESH MATERIALIZED VIEW
    drop_materialized_view, // DROP MATERIALIZED VIEW
};

/// Join type
pub const JoinKind = enum {
    inner,
    left,
    right,
    full,
    cross,

    pub fn toSql(self: JoinKind) []const u8 {
        return switch (self) {
            .inner => "INNER JOIN",
            .left => "LEFT JOIN",
            .right => "RIGHT JOIN",
            .full => "FULL OUTER JOIN",
            .cross => "CROSS JOIN",
        };
    }
};

/// A JOIN clause
pub const Join = struct {
    kind: JoinKind,
    table: []const u8,
    on_left: []const u8,
    on_right: []const u8,
    alias: ?[]const u8 = null,
};

/// A WHERE condition with logical operator
pub const WhereClause = struct {
    condition: Condition,
    logical_op: LogicalOp = .@"and",
};

/// ORDER BY clause
pub const OrderBy = struct {
    column: []const u8,
    order: SortOrder = .asc,
};

/// Column assignment for UPDATE/INSERT
pub const Assignment = struct {
    column: []const u8,
    value: Value,
};

/// CTE (Common Table Expression) definition
pub const CTEDef = struct {
    name: []const u8,
    recursive: bool = false,
    columns: []const []const u8 = &.{},
    // Note: For Zig, we use sql string instead of nested QailCmd pointer
    base_sql: []const u8 = "",
};

/// ON CONFLICT action for upsert
pub const ConflictAction = enum {
    do_nothing,
    do_update,
};

/// ON CONFLICT clause for upsert (INSERT ON CONFLICT)
pub const OnConflict = struct {
    columns: []const []const u8 = &.{},
    action: ConflictAction = .do_nothing,
    update_columns: []const Assignment = &.{},
};

/// Set operation for combining queries
pub const SetOp = enum {
    @"union",
    union_all,
    intersect,
    intersect_all,
    except,
    except_all,
};

/// The primary QAIL command structure
pub const QailCmd = struct {
    kind: CmdKind = .get,
    table: []const u8 = "",
    table_alias: ?[]const u8 = null,
    columns: []const Expr = &.{},
    where_clauses: []const WhereClause = &.{},
    joins: []const Join = &.{},
    order_by: []const OrderBy = &.{},
    group_by: []const []const u8 = &.{},
    having_clauses: []const WhereClause = &.{},
    limit_val: ?i64 = null,
    offset_val: ?i64 = null,
    assignments: []const Assignment = &.{},
    returning: []const Expr = &.{},
    distinct: bool = false,
    for_update: bool = false,

    // Transaction fields
    savepoint_name: ?[]const u8 = null,

    // Pub/Sub fields (LISTEN/NOTIFY)
    channel: ?[]const u8 = null,
    payload: ?[]const u8 = null,

    // ==================== Static Constructors ====================

    /// Create a GET (SELECT) command
    pub fn get(table: []const u8) QailCmd {
        return .{ .kind = .get, .table = table };
    }

    /// Create a SET (UPDATE) command
    pub fn set(table: []const u8) QailCmd {
        return .{ .kind = .set, .table = table };
    }

    /// Create a DEL (DELETE) command
    pub fn del(table: []const u8) QailCmd {
        return .{ .kind = .del, .table = table };
    }

    /// Create an ADD (INSERT) command
    pub fn add(table: []const u8) QailCmd {
        return .{ .kind = .add, .table = table };
    }

    /// Create a PUT (UPSERT) command
    pub fn put(table: []const u8) QailCmd {
        return .{ .kind = .put, .table = table };
    }

    /// Create a TRUNCATE command
    pub fn truncate(table: []const u8) QailCmd {
        return .{ .kind = .truncate, .table = table };
    }

    // ==================== Transaction Commands ====================

    /// BEGIN TRANSACTION
    pub fn beginTx() QailCmd {
        return .{ .kind = .begin };
    }

    /// COMMIT
    pub fn commitTx() QailCmd {
        return .{ .kind = .commit };
    }

    /// ROLLBACK
    pub fn rollbackTx() QailCmd {
        return .{ .kind = .rollback };
    }

    /// SAVEPOINT name
    pub fn savepoint(name: []const u8) QailCmd {
        return .{ .kind = .savepoint, .savepoint_name = name };
    }

    /// RELEASE SAVEPOINT name
    pub fn releaseSavepoint(name: []const u8) QailCmd {
        return .{ .kind = .release, .savepoint_name = name };
    }

    /// ROLLBACK TO SAVEPOINT name
    pub fn rollbackTo(name: []const u8) QailCmd {
        return .{ .kind = .rollback_to, .savepoint_name = name };
    }

    // ==================== Pub/Sub Commands ====================

    /// LISTEN channel
    pub fn listen(ch: []const u8) QailCmd {
        return .{ .kind = .listen, .channel = ch };
    }

    /// NOTIFY channel, 'payload'
    pub fn notifyChannel(ch: []const u8, msg: ?[]const u8) QailCmd {
        return .{ .kind = .notify, .channel = ch, .payload = msg };
    }

    /// UNLISTEN channel (or all if null)
    pub fn unlisten(ch: ?[]const u8) QailCmd {
        return .{ .kind = .unlisten, .channel = ch };
    }

    /// Create an EXPLAIN command
    pub fn explain(table: []const u8) QailCmd {
        return .{ .kind = .explain, .table = table };
    }

    /// Create a raw SQL passthrough command
    pub fn raw(sql: []const u8) QailCmd {
        return .{ .kind = .raw, .table = sql };
    }

    // ==================== Builder Methods ====================

    /// Set columns to select
    pub fn select(self: QailCmd, cols: []const Expr) QailCmd {
        var cmd = self;
        cmd.columns = cols;
        return cmd;
    }

    /// Set table alias
    pub fn alias(self: QailCmd, a: []const u8) QailCmd {
        var cmd = self;
        cmd.table_alias = a;
        return cmd;
    }

    /// Add WHERE clause
    pub fn where(self: QailCmd, clauses: []const WhereClause) QailCmd {
        var cmd = self;
        cmd.where_clauses = clauses;
        return cmd;
    }

    /// Add JOIN
    pub fn join(self: QailCmd, joins_list: []const Join) QailCmd {
        var cmd = self;
        cmd.joins = joins_list;
        return cmd;
    }

    /// Set ORDER BY
    pub fn orderBy(self: QailCmd, order: []const OrderBy) QailCmd {
        var cmd = self;
        cmd.order_by = order;
        return cmd;
    }

    /// Set GROUP BY
    pub fn groupBy(self: QailCmd, columns: []const []const u8) QailCmd {
        var cmd = self;
        cmd.group_by = columns;
        return cmd;
    }

    /// Set HAVING clause
    pub fn havingClauses(self: QailCmd, clauses: []const WhereClause) QailCmd {
        var cmd = self;
        cmd.having_clauses = clauses;
        return cmd;
    }

    /// Set LIMIT
    pub fn limit(self: QailCmd, n: i64) QailCmd {
        var cmd = self;
        cmd.limit_val = n;
        return cmd;
    }

    /// Set OFFSET
    pub fn offset(self: QailCmd, n: i64) QailCmd {
        var cmd = self;
        cmd.offset_val = n;
        return cmd;
    }

    /// Set column assignments for UPDATE/INSERT
    pub fn values(self: QailCmd, assigns: []const Assignment) QailCmd {
        var cmd = self;
        cmd.assignments = assigns;
        return cmd;
    }

    /// Set RETURNING clause
    pub fn returningCols(self: QailCmd, cols: []const Expr) QailCmd {
        var cmd = self;
        cmd.returning = cols;
        return cmd;
    }

    /// Set DISTINCT
    pub fn distinct_(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.distinct = true;
        return cmd;
    }

    /// Set FOR UPDATE lock
    pub fn forUpdate(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.for_update = true;
        return cmd;
    }
};

// ==================== Helper constructors ====================

/// Create a simple filter condition
pub fn filter(column: []const u8, op: Operator, value: Value) WhereClause {
    return .{
        .condition = .{ .column = column, .op = op, .value = value },
    };
}

/// Create an OR filter condition
pub fn orFilter(column: []const u8, op: Operator, value: Value) WhereClause {
    return .{
        .condition = .{ .column = column, .op = op, .value = value },
        .logical_op = .@"or",
    };
}

// ==================== Tests ====================

test "qailcmd get creates select" {
    const cmd = QailCmd.get("users");
    try std.testing.expectEqual(CmdKind.get, cmd.kind);
    try std.testing.expectEqualStrings("users", cmd.table);
}

test "qailcmd builder chain" {
    const cols = [_]Expr{ Expr.col("id"), Expr.col("name") };
    const cmd = QailCmd.get("users")
        .select(&cols)
        .limit(10)
        .distinct_();

    try std.testing.expectEqual(CmdKind.get, cmd.kind);
    try std.testing.expectEqual(@as(usize, 2), cmd.columns.len);
    try std.testing.expectEqual(@as(?i64, 10), cmd.limit_val);
    try std.testing.expect(cmd.distinct);
}

test "qailcmd set creates update" {
    const cmd = QailCmd.set("users");
    try std.testing.expectEqual(CmdKind.set, cmd.kind);
}

test "qailcmd del creates delete" {
    const cmd = QailCmd.del("users");
    try std.testing.expectEqual(CmdKind.del, cmd.kind);
}

test "filter creates where clause" {
    const clause = filter("age", .gte, Value.fromInt(18));
    try std.testing.expectEqualStrings("age", clause.condition.column);
    try std.testing.expectEqual(Operator.gte, clause.condition.op);
}
