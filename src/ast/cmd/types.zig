const std = @import("std");
const expr = @import("../expr.zig");
const operators = @import("../operators.zig");
const values = @import("../values.zig");

const Condition = expr.Condition;
const LogicalOp = operators.LogicalOp;
const SortOrder = operators.SortOrder;
const Value = values.Value;

/// Command type (GET, SET, DEL, ADD, etc.)
pub const CmdKind = enum {
    // Query operations
    get, // SELECT
    set, // UPDATE
    del, // DELETE
    add, // INSERT
    put, // UPSERT (INSERT ON CONFLICT)
    cnt, // COUNT

    // Schema operations (DDL)
    make, // CREATE TABLE
    drop, // DROP TABLE
    mod, // ALTER TABLE (general modification)
    alter, // ALTER TABLE ADD COLUMN
    alter_drop, // ALTER TABLE DROP COLUMN
    alter_type, // ALTER TABLE ALTER COLUMN TYPE
    drop_col, // DROP COLUMN
    rename_col, // RENAME COLUMN
    truncate, // TRUNCATE TABLE

    // Index operations
    index, // CREATE INDEX
    drop_index, // DROP INDEX

    // Advanced query features
    over, // Window functions / UPSERT
    with, // CTE (Common Table Expression)
    json_table, // JSON_TABLE

    // View operations
    create_view, // CREATE VIEW
    drop_view, // DROP VIEW

    // Materialized views
    create_materialized_view, // CREATE MATERIALIZED VIEW
    refresh_materialized_view, // REFRESH MATERIALIZED VIEW
    drop_materialized_view, // DROP MATERIALIZED VIEW

    // Function/Trigger operations
    create_function, // CREATE FUNCTION
    drop_function, // DROP FUNCTION
    create_trigger, // CREATE TRIGGER
    drop_trigger, // DROP TRIGGER

    // Extension operations
    create_extension, // CREATE EXTENSION
    drop_extension, // DROP EXTENSION

    // Sequence operations
    create_sequence, // CREATE SEQUENCE
    drop_sequence, // DROP SEQUENCE

    // Enum type operations
    create_enum, // CREATE TYPE ... AS ENUM
    drop_enum, // DROP TYPE
    alter_enum_add_value, // ALTER TYPE ... ADD VALUE

    // Column-level ALTER operations
    alter_set_not_null, // ALTER COLUMN SET NOT NULL
    alter_drop_not_null, // ALTER COLUMN DROP NOT NULL
    alter_set_default, // ALTER COLUMN SET DEFAULT
    alter_drop_default, // ALTER COLUMN DROP DEFAULT

    // RLS operations
    alter_enable_rls, // ALTER TABLE ENABLE ROW LEVEL SECURITY
    alter_disable_rls, // ALTER TABLE DISABLE ROW LEVEL SECURITY
    alter_force_rls, // ALTER TABLE FORCE ROW LEVEL SECURITY
    alter_no_force_rls, // ALTER TABLE NO FORCE ROW LEVEL SECURITY

    // Comment
    comment_on, // COMMENT ON

    // Codegen
    gen, // Generate struct from table schema

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

    // Search & vector
    search, // Full-text or vector search
    upsert, // INSERT ... ON CONFLICT DO UPDATE
    scroll, // Cursor-based scrolling

    // Vector database (Qdrant)
    create_collection, // Create vector collection
    delete_collection, // Delete vector collection

    // Session & procedural commands
    call, // CALL procedure
    do_block, // DO anonymous block
    session_set, // SET session variable
    session_show, // SHOW session variable
    session_reset, // RESET session variable
    create_database, // CREATE DATABASE
    drop_database, // DROP DATABASE
    grant, // GRANT privileges
    revoke, // REVOKE privileges
    create_policy, // CREATE POLICY
    drop_policy, // DROP POLICY

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

/// Target operation for CREATE POLICY
pub const PolicyTarget = enum {
    all,
    select,
    insert,
    update,
    delete,

    pub fn toSql(self: PolicyTarget) []const u8 {
        return switch (self) {
            .all => "ALL",
            .select => "SELECT",
            .insert => "INSERT",
            .update => "UPDATE",
            .delete => "DELETE",
        };
    }
};

/// Policy permissiveness (PostgreSQL RLS)
pub const PolicyPermissiveness = enum {
    permissive,
    restrictive,
};

/// Row-level security policy definition
pub const PolicyDef = struct {
    name: []const u8,
    table: []const u8,
    target: PolicyTarget = .all,
    permissiveness: PolicyPermissiveness = .permissive,
    role: ?[]const u8 = null,
    using_sql: ?[]const u8 = null,
    with_check_sql: ?[]const u8 = null,
};

/// Create a simple filter condition
pub fn filter(column: []const u8, op: operators.Operator, value: Value) WhereClause {
    return .{
        .condition = .{ .column = column, .op = op, .value = value },
    };
}

/// Create an OR filter condition
pub fn orFilter(column: []const u8, op: operators.Operator, value: Value) WhereClause {
    return .{
        .condition = .{ .column = column, .op = op, .value = value },
        .logical_op = .@"or",
    };
}

test "join kind renders sql" {
    try std.testing.expectEqualStrings("INNER JOIN", JoinKind.inner.toSql());
    try std.testing.expectEqualStrings("FULL OUTER JOIN", JoinKind.full.toSql());
}

test "policy target renders sql" {
    try std.testing.expectEqualStrings("ALL", PolicyTarget.all.toSql());
    try std.testing.expectEqualStrings("DELETE", PolicyTarget.delete.toSql());
}

test "filter helpers create clauses" {
    const clause = filter("age", .gte, Value.fromInt(18));
    try std.testing.expectEqualStrings("age", clause.condition.column);
    try std.testing.expectEqual(LogicalOp.@"and", clause.logical_op);

    const or_clause = orFilter("name", .eq, Value.fromString("alpha"));
    try std.testing.expectEqual(LogicalOp.@"or", or_clause.logical_op);
}
