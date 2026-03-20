// PostgreSQL Row-Level Security (RLS) context helpers.
//
// Centralizes scoped `set_config(...)` SQL generation so pool/driver callsites
// don't need to duplicate raw SQL fragments.

const std = @import("std");

pub const SuperAdminToken = struct {
    pub fn forSystemProcess(_: []const u8) SuperAdminToken {
        return .{};
    }

    pub fn forWebhook(_: []const u8) SuperAdminToken {
        return .{};
    }

    pub fn forAuth(_: []const u8) SuperAdminToken {
        return .{};
    }
};

pub const RlsContext = struct {
    tenant_id: []const u8,
    agent_id: []const u8,
    is_super_admin: bool,
    is_global: bool,
    user_id: []const u8,

    pub fn tenant(tenant_id: []const u8) RlsContext {
        return .{
            .tenant_id = tenant_id,
            .agent_id = "",
            .is_super_admin = false,
            .is_global = false,
            .user_id = "",
        };
    }

    pub fn agent(agent_id: []const u8) RlsContext {
        return .{
            .tenant_id = "",
            .agent_id = agent_id,
            .is_super_admin = false,
            .is_global = false,
            .user_id = "",
        };
    }

    pub fn tenantAndAgent(tenant_id: []const u8, agent_id: []const u8) RlsContext {
        return .{
            .tenant_id = tenant_id,
            .agent_id = agent_id,
            .is_super_admin = false,
            .is_global = false,
            .user_id = "",
        };
    }

    pub fn global() RlsContext {
        return .{
            .tenant_id = "",
            .agent_id = "",
            .is_super_admin = false,
            .is_global = true,
            .user_id = "",
        };
    }

    pub fn superAdmin(_: SuperAdminToken) RlsContext {
        const nil_uuid = "00000000-0000-0000-0000-000000000000";
        return .{
            .tenant_id = nil_uuid,
            .agent_id = "",
            .is_super_admin = true,
            .is_global = false,
            .user_id = "",
        };
    }

    pub fn empty() RlsContext {
        return .{
            .tenant_id = "",
            .agent_id = "",
            .is_super_admin = false,
            .is_global = false,
            .user_id = "",
        };
    }

    pub fn user(user_id: []const u8) RlsContext {
        return .{
            .tenant_id = "",
            .agent_id = "",
            .is_super_admin = false,
            .is_global = false,
            .user_id = user_id,
        };
    }

    pub fn hasTenant(self: *const RlsContext) bool {
        return self.tenant_id.len != 0;
    }

    pub fn hasAgent(self: *const RlsContext) bool {
        return self.agent_id.len != 0;
    }

    pub fn hasUser(self: *const RlsContext) bool {
        return self.user_id.len != 0;
    }

    pub fn userId(self: *const RlsContext) []const u8 {
        return self.user_id;
    }

    pub fn bypassesRls(self: *const RlsContext) bool {
        return self.is_super_admin;
    }

    pub fn isGlobal(self: *const RlsContext) bool {
        return self.is_global;
    }
};

/// Sanitize SQL GUC values for insertion into single-quoted literals.
///
/// Allowlist:
/// - printable ASCII (0x20..0x7E)
///
/// Denylist (removed even if printable):
/// - `'` `\` `;` `$`
pub fn sanitizeGucValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    for (value) |c| {
        if (c < 0x20 or c > 0x7E) continue;
        switch (c) {
            '\'', '\\', ';', '$' => continue,
            else => {},
        }
        try out.append(allocator, c);
    }

    return try out.toOwnedSlice(allocator);
}

/// Build SQL that starts a transaction and configures RLS/session GUC values.
pub fn contextToSql(allocator: std.mem.Allocator, ctx: *const RlsContext) ![]u8 {
    const nil_uuid = "00000000-0000-0000-0000-000000000000";

    const tenant_raw = if (ctx.isGlobal() and ctx.tenant_id.len == 0) nil_uuid else ctx.tenant_id;
    const agent_raw = if (ctx.isGlobal() and ctx.agent_id.len == 0) nil_uuid else ctx.agent_id;
    const user_raw = if (ctx.userId().len == 0) nil_uuid else ctx.userId();

    const tenant = try sanitizeGucValue(allocator, tenant_raw);
    defer allocator.free(tenant);
    const agent = try sanitizeGucValue(allocator, agent_raw);
    defer allocator.free(agent);
    const user = try sanitizeGucValue(allocator, user_raw);
    defer allocator.free(user);

    const is_global = if (ctx.isGlobal()) "true" else "false";
    const is_super_admin = if (ctx.bypassesRls()) "true" else "false";

    return std.fmt.allocPrint(
        allocator,
        "BEGIN; SET LOCAL app.is_global = '{s}'; SELECT set_config('app.current_user_id', '{s}', true), set_config('app.current_tenant_id', '{s}', true), set_config('app.tenant_id', '{s}', true), set_config('app.current_agent_id', '{s}', true), set_config('app.is_super_admin', '{s}', true)",
        .{ is_global, user, tenant, tenant, agent, is_super_admin },
    );
}

/// Build SQL that sets `statement_timeout` and RLS/session GUC values.
pub fn contextToSqlWithTimeout(allocator: std.mem.Allocator, ctx: *const RlsContext, timeout_ms: u32) ![]u8 {
    return contextToSqlWithTimeouts(allocator, ctx, timeout_ms, 0);
}

/// Build SQL that sets `statement_timeout`, optional `lock_timeout`, and RLS.
pub fn contextToSqlWithTimeouts(
    allocator: std.mem.Allocator,
    ctx: *const RlsContext,
    statement_timeout_ms: u32,
    lock_timeout_ms: u32,
) ![]u8 {
    const nil_uuid = "00000000-0000-0000-0000-000000000000";

    const tenant_raw = if (ctx.isGlobal() and ctx.tenant_id.len == 0) nil_uuid else ctx.tenant_id;
    const agent_raw = if (ctx.isGlobal() and ctx.agent_id.len == 0) nil_uuid else ctx.agent_id;
    const user_raw = if (ctx.userId().len == 0) nil_uuid else ctx.userId();

    const tenant = try sanitizeGucValue(allocator, tenant_raw);
    defer allocator.free(tenant);
    const agent = try sanitizeGucValue(allocator, agent_raw);
    defer allocator.free(agent);
    const user = try sanitizeGucValue(allocator, user_raw);
    defer allocator.free(user);

    const lock_clause = if (lock_timeout_ms > 0)
        try std.fmt.allocPrint(allocator, " SET LOCAL lock_timeout = {};", .{lock_timeout_ms})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(lock_clause);

    const is_global = if (ctx.isGlobal()) "true" else "false";
    const is_super_admin = if (ctx.bypassesRls()) "true" else "false";

    return std.fmt.allocPrint(
        allocator,
        "BEGIN; SET LOCAL statement_timeout = {};{s} SET LOCAL app.is_global = '{s}'; SELECT set_config('app.current_user_id', '{s}', true), set_config('app.current_tenant_id', '{s}', true), set_config('app.tenant_id', '{s}', true), set_config('app.current_agent_id', '{s}', true), set_config('app.is_super_admin', '{s}', true)",
        .{ statement_timeout_ms, lock_clause, is_global, user, tenant, tenant, agent, is_super_admin },
    );
}

/// SQL to reset transaction-local scoped RLS state.
pub fn resetSql() []const u8 {
    return "COMMIT";
}

test "contextToSql tenant sets app.current_tenant_id" {
    const allocator = std.testing.allocator;
    const ctx = RlsContext.tenant("abc-123");
    const sql = try contextToSql(allocator, &ctx);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL app.is_global = 'false'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "set_config('app.current_tenant_id', 'abc-123'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "set_config('app.tenant_id', 'abc-123'") != null);
}

test "contextToSql global emits nil uuid and app.is_global true" {
    const allocator = std.testing.allocator;
    const ctx = RlsContext.global();
    const sql = try contextToSql(allocator, &ctx);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL app.is_global = 'true'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "00000000-0000-0000-0000-000000000000") != null);
}

test "contextToSql user empty maps to nil uuid" {
    const allocator = std.testing.allocator;
    const ctx = RlsContext.empty();
    const sql = try contextToSql(allocator, &ctx);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "set_config('app.current_user_id', '00000000-0000-0000-0000-000000000000'") != null);
}

test "sanitizeGucValue strips dangerous chars" {
    const allocator = std.testing.allocator;
    const out = try sanitizeGucValue(allocator, "'; DROP TABLE users; --");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(" DROP TABLE users --", out);
}

test "contextToSqlWithTimeout sets statement timeout" {
    const allocator = std.testing.allocator;
    const ctx = RlsContext.tenant("tenant-1");
    const sql = try contextToSqlWithTimeout(allocator, &ctx, 5000);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL statement_timeout = 5000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "set_config('app.current_tenant_id', 'tenant-1'") != null);
}

test "contextToSqlWithTimeouts omits lock timeout when zero" {
    const allocator = std.testing.allocator;
    const ctx = RlsContext.tenant("tenant-1");
    const sql = try contextToSqlWithTimeouts(allocator, &ctx, 5000, 0);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL statement_timeout = 5000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL lock_timeout") == null);
}

test "contextToSqlWithTimeouts includes lock timeout when non-zero" {
    const allocator = std.testing.allocator;
    const ctx = RlsContext.tenant("tenant-1");
    const sql = try contextToSqlWithTimeouts(allocator, &ctx, 5000, 1200);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL statement_timeout = 5000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SET LOCAL lock_timeout = 1200;") != null);
}

test "resetSql returns COMMIT" {
    try std.testing.expectEqualStrings("COMMIT", resetSql());
}
