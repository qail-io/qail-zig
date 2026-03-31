const cmd = @import("cmd.zig");

const QailCmd = cmd.QailCmd;
const CTEDef = cmd.CTEDef;
const SetOp = cmd.SetOp;
const SetOpDef = cmd.SetOpDef;

/// Trusted/internal helper for legacy raw nested-query compatibility paths.
/// Public driver execution rejects these commands by default.
pub fn withSourceQuerySql(base: QailCmd, sql: []const u8) QailCmd {
    var cmd_copy = base;
    cmd_copy.source_query_sql = sql;
    return cmd_copy;
}

pub fn createViewFromSql(name: []const u8, sql: []const u8) QailCmd {
    return withSourceQuerySql(QailCmd.createView(name), sql);
}

pub fn createMaterializedViewFromSql(name: []const u8, sql: []const u8) QailCmd {
    return withSourceQuerySql(QailCmd.createMaterializedView(name), sql);
}

pub fn cteFromSql(name: []const u8, sql: []const u8) CTEDef {
    return .{
        .name = name,
        .base_sql = sql,
    };
}

pub fn setOpFromSql(op: SetOp, sql: []const u8) SetOpDef {
    return .{
        .op = op,
        .query_sql = sql,
    };
}

test "trusted nested query raw helpers set compatibility fields" {
    const cte = cteFromSql("legacy", "SELECT 1");
    try @import("std").testing.expectEqualStrings("SELECT 1", cte.base_sql);

    const set_op = setOpFromSql(.union_all, "SELECT 2");
    try @import("std").testing.expectEqualStrings("SELECT 2", set_op.query_sql);

    const cmd_view = createViewFromSql("v_legacy", "SELECT 3");
    try @import("std").testing.expectEqualStrings("SELECT 3", cmd_view.source_query_sql.?);

    const cmd_mv = createMaterializedViewFromSql("mv_legacy", "SELECT 4");
    try @import("std").testing.expectEqualStrings("SELECT 4", cmd_mv.source_query_sql.?);
}
