// QAIL Command - The primary query command structure
//
// Port of Rust qail-core/src/ast/cmd.rs

const std = @import("std");
const expr = @import("expr.zig");
const operators = @import("operators.zig");
const values = @import("values.zig");

const Expr = expr.Expr;
const Condition = expr.Condition;
const Operator = operators.Operator;
const SortOrder = operators.SortOrder;
const LogicalOp = operators.LogicalOp;
pub const Value = values.Value;

/// Command type (GET, SET, DEL, ADD, etc.)
pub const CmdKind = enum {
    // Query operations
    get, // SELECT
    set, // UPDATE
    del, // DELETE
    add, // INSERT
    put, // UPSERT (INSERT ON CONFLICT)

    // Schema operations (DDL)
    make, // CREATE TABLE
    drop, // DROP TABLE
    mod, // ALTER TABLE (general modification)
    alter, // ALTER TABLE ADD COLUMN
    alter_drop, // ALTER TABLE DROP COLUMN
    drop_col, // DROP COLUMN
    rename_col, // RENAME COLUMN
    truncate, // TRUNCATE TABLE

    // Index operations
    index, // CREATE INDEX
    drop_index, // DROP INDEX

    // Advanced query features
    over, // Window functions
    with, // CTE (Common Table Expression)
    json_table, // JSON_TABLE

    // Codegen
    gen, // Generate Rust struct from table schema

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
    copy_out, // COPY TO STDOUT (bulk export)

    // Table operations
    lock_table, // LOCK TABLE

    // Materialized views
    create_materialized_view, // CREATE MATERIALIZED VIEW
    refresh_materialized_view, // REFRESH MATERIALIZED VIEW
    drop_materialized_view, // DROP MATERIALIZED VIEW

    // Raw SQL (for migrations, DDL, etc.)
    raw, // Raw SQL string
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

/// Set operation definition (operation + query)
pub const SetOpDef = struct {
    op: SetOp,
    // Note: For Zig, we use sql string instead of nested QailCmd pointer
    query_sql: []const u8 = "",
};

/// Index definition for CREATE INDEX
pub const IndexDef = struct {
    name: []const u8,
    table: []const u8,
    columns: []const []const u8 = &.{},
    unique: bool = false,
};

/// Table-level constraint for CREATE TABLE
pub const TableConstraint = union(enum) {
    /// UNIQUE (col1, col2, ...)
    unique: []const []const u8,
    /// PRIMARY KEY (col1, col2, ...)
    primary_key: []const []const u8,
    /// FOREIGN KEY
    foreign_key: struct {
        columns: []const []const u8,
        ref_table: []const u8,
        ref_columns: []const []const u8,
    },
    /// CHECK constraint
    check: []const u8,
};

/// GROUP BY mode for advanced aggregations
pub const GroupByMode = enum {
    /// Standard GROUP BY
    simple,
    /// ROLLUP - hierarchical subtotals
    rollup,
    /// CUBE - all combinations of subtotals
    cube,
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

    // Row locking (FOR UPDATE/SHARE variants)
    lock_mode: ?operators.LockMode = null,

    // Advanced query features
    distinct_on: []const Expr = &.{}, // DISTINCT ON (Postgres-specific)
    group_by_mode: GroupByMode = .simple, // ROLLUP/CUBE support
    on_conflict: ?OnConflict = null, // Upsert ON CONFLICT clause
    ctes: []const CTEDef = &.{}, // CTE definitions

    // DDL fields
    index_def: ?IndexDef = null, // For CREATE INDEX
    table_constraints: []const TableConstraint = &.{}, // For CREATE TABLE

    // Set operations
    set_ops: []const SetOpDef = &.{}, // UNION/INTERSECT/EXCEPT

    // Transaction fields
    savepoint_name: ?[]const u8 = null,

    // Pub/Sub fields (LISTEN/NOTIFY)
    channel: ?[]const u8 = null,
    payload: ?[]const u8 = null,

    // INSERT values (for add command)
    insert_values: []const Value = &.{},

    // Raw SQL (for migrations, DDL)
    raw_sql: ?[]const u8 = null,

    // ==================== New DML Features ====================

    // FETCH clause (SQL standard alternative to LIMIT)
    fetch_count: ?u64 = null, // FETCH FIRST n ROWS
    fetch_with_ties: bool = false, // WITH TIES

    // DEFAULT VALUES for INSERT
    default_values: bool = false,

    // OVERRIDING clause for INSERT
    overriding: ?operators.OverridingKind = null,

    // TABLESAMPLE (method, percentage, optional seed for REPEATABLE)
    sample_method: ?operators.SampleMethod = null,
    sample_percent: ?f64 = null,
    sample_seed: ?u64 = null,

    // ONLY - select/update/delete without child tables (inheritance)
    only_table: bool = false,

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

    /// Create a raw SQL command
    pub fn raw(sql: []const u8) QailCmd {
        return .{ .kind = .raw, .raw_sql = sql };
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

    // ==================== DDL Commands ====================

    /// DROP TABLE
    pub fn drop(table: []const u8) QailCmd {
        return .{ .kind = .drop, .table = table };
    }

    /// CREATE INDEX
    pub fn createIndex(table: []const u8) QailCmd {
        return .{ .kind = .index, .table = table };
    }

    /// DROP INDEX
    pub fn dropIndex(index_name: []const u8) QailCmd {
        return .{ .kind = .drop_index, .table = index_name };
    }

    /// ALTER TABLE ADD COLUMN
    pub fn alter(table: []const u8) QailCmd {
        return .{ .kind = .alter, .table = table };
    }

    /// ALTER TABLE DROP COLUMN
    pub fn alterDrop(table: []const u8) QailCmd {
        return .{ .kind = .alter_drop, .table = table };
    }

    /// General table modification
    pub fn modify(table: []const u8) QailCmd {
        return .{ .kind = .mod, .table = table };
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
        cmd.lock_mode = .update;
        return cmd;
    }

    /// Set FOR NO KEY UPDATE lock
    pub fn forNoKeyUpdate(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.lock_mode = .no_key_update;
        return cmd;
    }

    /// Set FOR SHARE lock
    pub fn forShare(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.lock_mode = .share;
        return cmd;
    }

    /// Set FOR KEY SHARE lock
    pub fn forKeyShare(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.lock_mode = .key_share;
        return cmd;
    }

    /// Use FETCH instead of LIMIT (SQL standard)
    pub fn fetchFirst(self: QailCmd, count: u64) QailCmd {
        var cmd = self;
        cmd.fetch_count = count;
        cmd.fetch_with_ties = false;
        return cmd;
    }

    /// Use FETCH with WITH TIES
    pub fn fetchWithTies(self: QailCmd, count: u64) QailCmd {
        var cmd = self;
        cmd.fetch_count = count;
        cmd.fetch_with_ties = true;
        return cmd;
    }

    /// Insert a row with all default values
    pub fn defaultValues(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.default_values = true;
        return cmd;
    }

    /// Override GENERATED ALWAYS columns
    pub fn overridingSystemValue(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.overriding = .system_value;
        return cmd;
    }

    /// Override GENERATED BY DEFAULT columns
    pub fn overridingUserValue(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.overriding = .user_value;
        return cmd;
    }

    /// Use TABLESAMPLE BERNOULLI
    pub fn tablesampleBernoulli(self: QailCmd, percent: f64) QailCmd {
        var cmd = self;
        cmd.sample_method = .bernoulli;
        cmd.sample_percent = percent;
        return cmd;
    }

    /// Use TABLESAMPLE SYSTEM
    pub fn tablesampleSystem(self: QailCmd, percent: f64) QailCmd {
        var cmd = self;
        cmd.sample_method = .system;
        cmd.sample_percent = percent;
        return cmd;
    }

    /// Add REPEATABLE(seed) for reproducible sampling
    pub fn repeatable(self: QailCmd, seed: u64) QailCmd {
        var cmd = self;
        cmd.sample_seed = seed;
        return cmd;
    }

    /// Query ONLY this table, not child tables (PostgreSQL inheritance)
    pub fn only(self: QailCmd) QailCmd {
        var cmd = self;
        cmd.only_table = true;
        return cmd;
    }

    // ==================== Ergonomic Join Methods ====================

    /// Add a LEFT JOIN
    pub fn leftJoin(self: QailCmd, table: []const u8, left_col: []const u8, right_col: []const u8) QailCmd {
        var cmd = self;
        cmd.joins = &[_]Join{.{ .kind = .left, .table = table, .on_left = left_col, .on_right = right_col }};
        return cmd;
    }

    /// Add a RIGHT JOIN
    pub fn rightJoin(self: QailCmd, table: []const u8, left_col: []const u8, right_col: []const u8) QailCmd {
        var cmd = self;
        cmd.joins = &[_]Join{.{ .kind = .right, .table = table, .on_left = left_col, .on_right = right_col }};
        return cmd;
    }

    /// Add an INNER JOIN
    pub fn innerJoin(self: QailCmd, table: []const u8, left_col: []const u8, right_col: []const u8) QailCmd {
        var cmd = self;
        cmd.joins = &[_]Join{.{ .kind = .inner, .table = table, .on_left = left_col, .on_right = right_col }};
        return cmd;
    }

    /// Add a FULL OUTER JOIN
    pub fn fullJoin(self: QailCmd, table: []const u8, left_col: []const u8, right_col: []const u8) QailCmd {
        var cmd = self;
        cmd.joins = &[_]Join{.{ .kind = .full, .table = table, .on_left = left_col, .on_right = right_col }};
        return cmd;
    }

    // ==================== Ergonomic ORDER BY ====================

    /// ORDER BY single column with sort order
    pub fn orderByCol(self: QailCmd, column: []const u8, order: SortOrder) QailCmd {
        var cmd = self;
        cmd.order_by = &[_]OrderBy{.{ .column = column, .order = order }};
        return cmd;
    }

    /// ORDER BY single column ascending
    pub fn orderByAsc(self: QailCmd, column: []const u8) QailCmd {
        return self.orderByCol(column, .asc);
    }

    /// ORDER BY single column descending
    pub fn orderByDesc(self: QailCmd, column: []const u8) QailCmd {
        return self.orderByCol(column, .desc);
    }

    // ==================== Ergonomic Value Setting ====================

    /// Add/set a single column value (for INSERT/UPDATE)
    pub fn setValue(self: QailCmd, column: []const u8, value: Value) QailCmd {
        var cmd = self;
        cmd.assignments = &[_]Assignment{.{ .column = column, .value = value }};
        return cmd;
    }

    // ==================== Advanced Query Builders ====================

    /// Set DISTINCT ON columns (Postgres-specific)
    pub fn distinctOn(self: QailCmd, exprs: []const Expr) QailCmd {
        var cmd = self;
        cmd.distinct_on = exprs;
        return cmd;
    }

    /// Set GROUP BY mode (simple, rollup, cube)
    pub fn groupByWithMode(self: QailCmd, columns: []const []const u8, mode: GroupByMode) QailCmd {
        var cmd = self;
        cmd.group_by = columns;
        cmd.group_by_mode = mode;
        return cmd;
    }

    /// Set ON CONFLICT clause for upsert
    pub fn onConflictDo(self: QailCmd, conflict: OnConflict) QailCmd {
        var cmd = self;
        cmd.on_conflict = conflict;
        return cmd;
    }

    /// Set CTE definitions
    pub fn withCtes(self: QailCmd, cte_defs: []const CTEDef) QailCmd {
        var cmd = self;
        cmd.ctes = cte_defs;
        return cmd;
    }

    // ==================== DDL Builders ====================

    /// Set index definition
    pub fn withIndex(self: QailCmd, idx: IndexDef) QailCmd {
        var cmd = self;
        cmd.index_def = idx;
        return cmd;
    }

    /// Set table constraints
    pub fn withConstraints(self: QailCmd, constraints: []const TableConstraint) QailCmd {
        var cmd = self;
        cmd.table_constraints = constraints;
        return cmd;
    }

    /// Set set operations (UNION, INTERSECT, EXCEPT)
    pub fn withSetOps(self: QailCmd, ops: []const SetOpDef) QailCmd {
        var cmd = self;
        cmd.set_ops = ops;
        return cmd;
    }

    // ==================== Make (CREATE TABLE) Builders ====================

    /// Create a CREATE TABLE command
    pub fn make(table: []const u8) QailCmd {
        return .{ .kind = .make, .table = table };
    }

    /// Create a CREATE MATERIALIZED VIEW command
    pub fn createMaterializedView(name: []const u8) QailCmd {
        return .{ .kind = .create_materialized_view, .table = name };
    }

    /// REFRESH MATERIALIZED VIEW
    pub fn refreshMaterializedView(name: []const u8) QailCmd {
        return .{ .kind = .refresh_materialized_view, .table = name };
    }

    /// DROP MATERIALIZED VIEW
    pub fn dropMaterializedView(name: []const u8) QailCmd {
        return .{ .kind = .drop_materialized_view, .table = name };
    }

    /// LOCK TABLE
    pub fn lockTable(table: []const u8) QailCmd {
        return .{ .kind = .lock_table, .table = table };
    }

    /// COPY TO STDOUT (bulk export)
    pub fn copyOut(table: []const u8) QailCmd {
        return .{ .kind = .copy_out, .table = table };
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
