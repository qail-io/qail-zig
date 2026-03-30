// QAIL Command - The primary query command structure
//
// Port of Rust qail-core/src/ast/cmd.rs

const expr = @import("expr.zig");
const operators = @import("operators.zig");
const values = @import("values.zig");
const cmd_types = @import("cmd/types.zig");

const Expr = expr.Expr;
const SortOrder = operators.SortOrder;
pub const Value = values.Value;
pub const CmdKind = cmd_types.CmdKind;
pub const JoinKind = cmd_types.JoinKind;
pub const Join = cmd_types.Join;
pub const WhereClause = cmd_types.WhereClause;
pub const OrderBy = cmd_types.OrderBy;
pub const Assignment = cmd_types.Assignment;
pub const CTEDef = cmd_types.CTEDef;
pub const ConflictAction = cmd_types.ConflictAction;
pub const OnConflict = cmd_types.OnConflict;
pub const SetOp = cmd_types.SetOp;
pub const SetOpDef = cmd_types.SetOpDef;
pub const IndexDef = cmd_types.IndexDef;
pub const TableConstraint = cmd_types.TableConstraint;
pub const GroupByMode = cmd_types.GroupByMode;
pub const PolicyTarget = cmd_types.PolicyTarget;
pub const PolicyPermissiveness = cmd_types.PolicyPermissiveness;
pub const PolicyDef = cmd_types.PolicyDef;
pub const filter = cmd_types.filter;
pub const orFilter = cmd_types.orFilter;

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

    // Privilege fields (GRANT/REVOKE)
    privileges: []const []const u8 = &.{},

    // Policy fields (CREATE/DROP POLICY)
    policy_def: ?PolicyDef = null,

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

    // ==================== DML Extensions ====================

    // INSERT ... SELECT source query
    source_query_sql: ?[]const u8 = null,

    // UPDATE ... FROM additional tables
    from_tables: []const []const u8 = &.{},

    // DELETE ... USING additional tables
    using_tables: []const []const u8 = &.{},

    // ==================== Vector Database (Qdrant) ====================

    /// Search vector for similarity queries
    vector: ?[]const f32 = null,
    /// Minimum score threshold
    score_threshold: ?f32 = null,
    /// Named vector in multi-vector collections
    vector_name: ?[]const u8 = null,
    /// Include vector data in results
    with_vector: bool = false,
    /// Vector dimensionality
    vector_size: ?u64 = null,
    /// Distance metric
    distance: ?operators.Distance = null,
    /// Store vectors on disk
    on_disk: ?bool = null,

    // ==================== Static Constructors ======================================

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

    /// CREATE VIEW
    pub fn createView(name: []const u8) QailCmd {
        return .{ .kind = .create_view, .table = name };
    }

    /// DROP VIEW
    pub fn dropView(name: []const u8) QailCmd {
        return .{ .kind = .drop_view, .table = name };
    }

    /// CREATE FUNCTION
    pub fn createFunction(name: []const u8) QailCmd {
        return .{ .kind = .create_function, .table = name };
    }

    /// DROP FUNCTION
    pub fn dropFunction(name: []const u8) QailCmd {
        return .{ .kind = .drop_function, .table = name };
    }

    /// CREATE TRIGGER
    pub fn createTrigger(name: []const u8) QailCmd {
        return .{ .kind = .create_trigger, .table = name };
    }

    /// DROP TRIGGER
    pub fn dropTrigger(name: []const u8) QailCmd {
        return .{ .kind = .drop_trigger, .table = name };
    }

    /// CREATE EXTENSION
    pub fn createExtension(name: []const u8) QailCmd {
        return .{ .kind = .create_extension, .table = name };
    }

    /// DROP EXTENSION
    pub fn dropExtension(name: []const u8) QailCmd {
        return .{ .kind = .drop_extension, .table = name };
    }

    /// COMMENT ON
    pub fn commentOn(target: []const u8) QailCmd {
        return .{ .kind = .comment_on, .table = target };
    }

    /// CALL procedure
    pub fn callProc(name: []const u8) QailCmd {
        return .{ .kind = .call, .table = name };
    }

    /// SET session variable
    pub fn sessionSet(name: []const u8) QailCmd {
        return .{ .kind = .session_set, .table = name };
    }

    /// SHOW session variable
    pub fn sessionShow(name: []const u8) QailCmd {
        return .{ .kind = .session_show, .table = name };
    }

    /// RESET session variable
    pub fn sessionReset(name: []const u8) QailCmd {
        return .{ .kind = .session_reset, .table = name };
    }

    /// CREATE DATABASE
    pub fn createDatabase(name: []const u8) QailCmd {
        return .{ .kind = .create_database, .table = name };
    }

    /// DROP DATABASE
    pub fn dropDatabase(name: []const u8) QailCmd {
        return .{ .kind = .drop_database, .table = name };
    }

    /// GRANT privileges ON object TO role
    pub fn grant(on_object: []const u8, privs: []const []const u8, role: []const u8) QailCmd {
        return .{
            .kind = .grant,
            .table = on_object,
            .privileges = privs,
            .payload = role,
        };
    }

    /// REVOKE privileges ON object FROM role
    pub fn revoke(on_object: []const u8, privs: []const []const u8, role: []const u8) QailCmd {
        return .{
            .kind = .revoke,
            .table = on_object,
            .privileges = privs,
            .payload = role,
        };
    }

    /// CREATE POLICY
    pub fn createPolicy(policy: PolicyDef) QailCmd {
        return .{
            .kind = .create_policy,
            .table = policy.table,
            .policy_def = policy,
        };
    }

    /// DROP POLICY IF EXISTS <name> ON <table>
    pub fn dropPolicy(name: []const u8, table: []const u8) QailCmd {
        return .{
            .kind = .drop_policy,
            .table = table,
            .payload = name,
        };
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
