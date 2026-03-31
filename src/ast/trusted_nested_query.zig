const cmd = @import("cmd.zig");

const QailCmd = cmd.QailCmd;

/// Trusted/internal helper for legacy raw view/materialized-view compatibility paths.
/// Public driver execution rejects these commands by default.
pub fn withRawQuerySource(base: QailCmd, sql: []const u8) QailCmd {
    var cmd_copy = base;
    cmd_copy.raw_sql = sql;
    return cmd_copy;
}

pub fn createViewFromSql(name: []const u8, sql: []const u8) QailCmd {
    return withRawQuerySource(QailCmd.createView(name), sql);
}

pub fn createMaterializedViewFromSql(name: []const u8, sql: []const u8) QailCmd {
    return withRawQuerySource(QailCmd.createMaterializedView(name), sql);
}

test "trusted nested query raw helpers use parent raw_sql for legacy view paths" {
    const cmd_view = createViewFromSql("v_legacy", "SELECT 3");
    try @import("std").testing.expectEqualStrings("SELECT 3", cmd_view.raw_sql.?);

    const cmd_mv = createMaterializedViewFromSql("mv_legacy", "SELECT 4");
    try @import("std").testing.expectEqualStrings("SELECT 4", cmd_mv.raw_sql.?);
}
