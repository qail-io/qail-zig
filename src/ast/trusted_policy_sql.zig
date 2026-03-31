const cmd = @import("cmd.zig");
const expr = @import("expr.zig");

const PolicyDef = cmd.PolicyDef;
const Expr = expr.Expr;

/// Trusted/internal helper for legacy raw policy SQL compatibility paths.
/// Public driver execution rejects these policies by default.
pub fn usingSql(policy: PolicyDef, sql: []const u8) PolicyDef {
    var next = policy;
    next.using_expr = .{ .raw = sql };
    return next;
}

pub fn withCheckSql(policy: PolicyDef, sql: []const u8) PolicyDef {
    var next = policy;
    next.with_check_expr = .{ .raw = sql };
    return next;
}

pub fn usingAndCheckSql(policy: PolicyDef, using_clause_sql: []const u8, with_check_clause_sql: []const u8) PolicyDef {
    return withCheckSql(usingSql(policy, using_clause_sql), with_check_clause_sql);
}

test "trusted policy sql helpers set raw expr fallback" {
    const policy = usingAndCheckSql(
        PolicyDef.create("tenant_only", "orders"),
        "tenant_id = current_setting('app.tenant_id')::uuid",
        "tenant_id = current_setting('app.tenant_id')::uuid",
    );

    try @import("std").testing.expect(policy.using_expr != null);
    try @import("std").testing.expect(policy.with_check_expr != null);
    try @import("std").testing.expectEqualStrings(
        "tenant_id = current_setting('app.tenant_id')::uuid",
        switch (policy.using_expr.?) {
            .raw => |raw| raw,
            else => unreachable,
        },
    );
    try @import("std").testing.expectEqualStrings(
        "tenant_id = current_setting('app.tenant_id')::uuid",
        switch (policy.with_check_expr.?) {
            .raw => |raw| raw,
            else => unreachable,
        },
    );
}
