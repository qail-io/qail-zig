const cmd = @import("cmd.zig");

const PolicyDef = cmd.PolicyDef;

/// Trusted/internal helper for legacy raw policy SQL compatibility paths.
/// Public driver execution rejects these policies by default.
pub fn usingSql(policy: PolicyDef, sql: []const u8) PolicyDef {
    var next = policy;
    next.using_sql = sql;
    return next;
}

pub fn withCheckSql(policy: PolicyDef, sql: []const u8) PolicyDef {
    var next = policy;
    next.with_check_sql = sql;
    return next;
}

pub fn usingAndCheckSql(policy: PolicyDef, using_sql: []const u8, with_check_sql: []const u8) PolicyDef {
    return withCheckSql(usingSql(policy, using_sql), with_check_sql);
}

test "trusted policy sql helpers set compatibility fields" {
    const policy = usingAndCheckSql(
        PolicyDef.create("tenant_only", "orders"),
        "tenant_id = current_setting('app.tenant_id')::uuid",
        "tenant_id = current_setting('app.tenant_id')::uuid",
    );

    try @import("std").testing.expectEqualStrings(
        "tenant_id = current_setting('app.tenant_id')::uuid",
        policy.using_sql.?,
    );
    try @import("std").testing.expectEqualStrings(
        "tenant_id = current_setting('app.tenant_id')::uuid",
        policy.with_check_sql.?,
    );
}
