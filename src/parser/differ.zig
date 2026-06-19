// Schema Differ
//
// Computes the difference between two schemas and generates migration commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../runtime/io.zig");
const schema = @import("schema.zig");
const compare = @import("differ/compare.zig");
const differ_types = @import("differ/types.zig");
const Schema = schema.Schema;
const ColumnDef = schema.ColumnDef;
pub const MigrationCmd = differ_types.MigrationCmd;
pub const IndexInfo = differ_types.IndexInfo;

// ============================================================================
// Differ
// ============================================================================

/// Compute the difference between two schemas.
/// Returns a list of migration commands needed to go from `old` to `new`.
pub fn diffSchemas(allocator: Allocator, old: *const Schema, new: *const Schema) !std.ArrayList(MigrationCmd) {
    var cmds = std.ArrayList(MigrationCmd).initCapacity(allocator, 0) catch unreachable;

    // 1. Detect new tables - CREATE TABLE with all columns (AST-native)
    for (new.tables.items) |new_table| {
        if (old.findTable(new_table.name) == null) {
            // Copy column slice for AST-native CREATE TABLE
            const cols = try allocator.alloc(ColumnDef, new_table.columns.items.len);
            for (new_table.columns.items, 0..) |col, i| {
                cols[i] = col;
            }
            try cmds.append(allocator, MigrationCmd{
                .action = .create_table,
                .table = new_table.name,
                .table_columns = cols,
            });
        }
    }

    // 2. Detect dropped tables
    for (old.tables.items) |old_table| {
        if (new.findTable(old_table.name) == null) {
            try cmds.append(allocator, MigrationCmd{
                .action = .drop_table,
                .table = old_table.name,
            });
        }
    }

    // 3. Detect column changes in existing tables
    for (new.tables.items) |new_table| {
        if (old.findTable(new_table.name)) |old_table| {
            // New columns
            for (new_table.columns.items) |new_col| {
                if (old_table.findColumn(new_col.name) == null) {
                    try cmds.append(allocator, MigrationCmd{
                        .action = .add_column,
                        .table = new_table.name,
                        .column = new_col,
                    });
                }
            }

            // Dropped columns
            for (old_table.columns.items) |old_col| {
                if (new_table.findColumn(old_col.name) == null) {
                    try cmds.append(allocator, MigrationCmd{
                        .action = .drop_column,
                        .table = new_table.name,
                        .column = old_col,
                    });
                }
            }

            // Type changes (alter column)
            for (new_table.columns.items) |new_col| {
                if (old_table.findColumn(new_col.name)) |old_col| {
                    if (!std.mem.eql(u8, old_col.typ, new_col.typ)) {
                        try cmds.append(allocator, MigrationCmd{
                            .action = .alter_column,
                            .table = new_table.name,
                            .column = new_col,
                        });
                    }
                }
            }
        }
    }

    // 4. Detect policy changes
    for (new.policies.items) |*new_policy| {
        if (old.findPolicy(new_policy.name, new_policy.table)) |old_policy| {
            if (!compare.policyEquals(old_policy, new_policy)) {
                try cmds.append(allocator, MigrationCmd{
                    .action = .drop_policy,
                    .table = old_policy.table,
                    .policy = old_policy.*,
                });
                try cmds.append(allocator, MigrationCmd{
                    .action = .create_policy,
                    .table = new_policy.table,
                    .policy = new_policy.*,
                });
            }
        } else {
            try cmds.append(allocator, MigrationCmd{
                .action = .create_policy,
                .table = new_policy.table,
                .policy = new_policy.*,
            });
        }
    }

    for (old.policies.items) |*old_policy| {
        if (new.findPolicy(old_policy.name, old_policy.table) == null) {
            try cmds.append(allocator, MigrationCmd{
                .action = .drop_policy,
                .table = old_policy.table,
                .policy = old_policy.*,
            });
        }
    }

    // 5. Detect grant/revoke changes
    for (new.grants.items) |*new_grant| {
        var exists = false;
        for (old.grants.items) |*old_grant| {
            if (compare.grantEquals(old_grant, new_grant)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            const cmd_action: MigrationCmd.Action = switch (new_grant.action) {
                .grant => .grant,
                .revoke => .revoke,
            };
            try cmds.append(allocator, MigrationCmd{
                .action = cmd_action,
                .table = new_grant.on_object,
                .grant = new_grant.*,
            });
        }
    }

    for (old.grants.items) |*old_grant| {
        var exists = false;
        for (new.grants.items) |*new_grant| {
            if (compare.grantEquals(old_grant, new_grant)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var inverse_grant = old_grant.*;
            const cmd_action: MigrationCmd.Action = switch (old_grant.action) {
                .grant => blk: {
                    inverse_grant.action = .revoke;
                    break :blk .revoke;
                },
                .revoke => blk: {
                    inverse_grant.action = .grant;
                    break :blk .grant;
                },
            };
            try cmds.append(allocator, MigrationCmd{
                .action = cmd_action,
                .table = old_grant.on_object,
                .grant = inverse_grant,
            });
        }
    }

    return cmds;
}

/// Generate SQL statements from migration commands
pub fn toSqlStatements(allocator: Allocator, cmds: *const std.ArrayList(MigrationCmd)) ![]const u8 {
    var writer = io.AllocatingWriter.init(allocator);
    defer writer.deinit();
    const w = writer.writer();

    for (cmds.items) |cmd| {
        const sql = try cmd.toSql(allocator);
        defer allocator.free(sql);
        try w.print("{s};\n", .{sql});
    }

    return writer.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "diff new table" {
    const allocator = std.testing.allocator;

    const old_input = "";
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    name text not null
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    // New design: 1 create_table with full DDL (no separate add_column)
    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .create_table);
}

test "diff dropped table" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input = "";
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .drop_table);
}

test "diff new column" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    email text not null
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .add_column);
    try std.testing.expectEqualStrings("email", cmds.items[0].column.?.name);
}

test "diff dropped column" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key,
        \\    legacy text
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .drop_column);
    try std.testing.expectEqualStrings("legacy", cmds.items[0].column.?.name);
}

test "diff type change" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key,
        \\    count i32
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    count i64
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .alter_column);
}

test "generate sql" {
    const allocator = std.testing.allocator;

    const old_input = "";
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    const sql = try toSqlStatements(allocator, &cmds);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "id uuid") != null);
}

test "diff policy create and drop" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.tenant_id')::uuid)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    var has_create_policy = false;
    for (cmds.items) |cmd| {
        if (cmd.action == .create_policy) {
            has_create_policy = true;
            const sql = try cmd.toSql(allocator);
            defer allocator.free(sql);
            try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE POLICY orders_tenant_isolation ON orders") != null);
        }
    }
    try std.testing.expect(has_create_policy);
}

test "diff policy predicate change emits drop and recreate" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.tenant_id')::uuid)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.current_tenant_id')::uuid)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    var saw_drop = false;
    var saw_create = false;
    for (cmds.items) |cmd| {
        switch (cmd.action) {
            .drop_policy => saw_drop = true,
            .create_policy => {
                saw_create = true;
                const sql = try cmd.toSql(allocator);
                defer allocator.free(sql);
                try std.testing.expect(std.mem.indexOf(u8, sql, "current_setting('app.current_tenant_id')::uuid") != null);
            },
            else => {},
        }
    }

    try std.testing.expect(saw_drop);
    try std.testing.expect(saw_create);
}

test "diff policy ignores nullif wrapped tenant predicate equivalent" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.current_tenant_id')::uuid)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff policy ignores coalesce wrapped boolean predicate equivalent" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table secrets (
        \\    id uuid primary_key
        \\)
        \\policy admin_bypass on secrets
        \\  using (current_setting('app.is_super_admin')::boolean = true)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table secrets (
        \\    id uuid primary_key
        \\)
        \\policy admin_bypass on secrets
        \\  using (COALESCE(current_setting('app.is_super_admin'::text, true), 'false'::text) = 'true'::text)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff grant removal emits revoke" {
    const allocator = std.testing.allocator;

    const old_input =
        \\grant select, insert on users to app_role
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input = "";
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.revoke, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "REVOKE SELECT, INSERT ON users FROM app_role") != null);
}
