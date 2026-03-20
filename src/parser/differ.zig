// Schema Differ
//
// Computes the difference between two schemas and generates migration commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../compat/io.zig");
const schema = @import("schema.zig");
const Schema = schema.Schema;
const TableDef = schema.TableDef;
const ColumnDef = schema.ColumnDef;
const PolicyDef = schema.PolicyDef;
const GrantDef = schema.GrantDef;
const GrantAction = schema.GrantAction;

// ============================================================================
// Migration Commands
// ============================================================================

pub const MigrationCmd = struct {
    action: Action,
    table: []const u8,
    column: ?ColumnDef = null,
    index: ?IndexInfo = null,
    policy: ?PolicyDef = null,
    grant: ?GrantDef = null,
    table_columns: []const ColumnDef = &.{}, // For CREATE TABLE (AST-native, no raw SQL!)
    ddl_sql: ?[]const u8 = null, // DEPRECATED: only for backwards compatibility

    pub const Action = enum {
        create_table,
        drop_table,
        add_column,
        drop_column,
        alter_column,
        create_index,
        drop_index,
        create_policy,
        drop_policy,
        grant,
        revoke,
    };

    /// Convert to QailCmd for AST-native execution (preferred method)
    /// NOTE: caller must free returned cmd.columns if non-empty
    pub fn toQailCmd(self: *const MigrationCmd, allocator: Allocator) !@import("../ast/cmd.zig").QailCmd {
        const QailCmd = @import("../ast/cmd.zig").QailCmd;
        const Expr = @import("../ast/expr.zig").Expr;

        return switch (self.action) {
            .create_table => blk: {
                // AST-native CREATE TABLE - convert ColumnDefs to Expr.column_def
                var cmd = QailCmd.make(self.table);
                if (self.table_columns.len > 0) {
                    const cols = try allocator.alloc(Expr, self.table_columns.len);
                    for (self.table_columns, 0..) |col_def, i| {
                        // Build full data type (handle serial, array, type params)
                        var type_buf: []const u8 = col_def.typ;
                        if (col_def.is_serial) {
                            type_buf = "serial";
                        }

                        // Build Expr.column_def with inline constraints
                        cols[i] = .{
                            .column_def = .{
                                .name = col_def.name,
                                .data_type = type_buf,
                                .is_primary_key = col_def.primary_key,
                                .is_unique = col_def.unique,
                                .is_not_null = !col_def.nullable,
                                .default_value = col_def.default_value,
                                .references = col_def.references,
                            },
                        };
                    }
                    cmd.columns = cols;
                }
                break :blk cmd;
            },
            .drop_table => QailCmd.drop(self.table),
            .add_column => blk: {
                if (self.column) |col| {
                    // ALTER TABLE ADD COLUMN - heap allocate columns
                    var cmd = QailCmd.alter(self.table);
                    const cols = try allocator.alloc(Expr, 1);
                    cols[0] = Expr.def(col.name, col.typ);
                    cmd.columns = cols;
                    break :blk cmd;
                }
                break :blk QailCmd.alter(self.table);
            },
            .drop_column => blk: {
                if (self.column) |col| {
                    // ALTER TABLE DROP COLUMN - heap allocate columns
                    var cmd = QailCmd.alterDrop(self.table);
                    const cols = try allocator.alloc(Expr, 1);
                    cols[0] = Expr.col(col.name);
                    cmd.columns = cols;
                    break :blk cmd;
                }
                break :blk QailCmd.alterDrop(self.table);
            },
            .alter_column => blk: {
                if (self.column) |col| {
                    // ALTER TABLE ALTER COLUMN TYPE - heap allocate columns
                    var cmd = QailCmd.modify(self.table);
                    const cols = try allocator.alloc(Expr, 1);
                    cols[0] = Expr.def(col.name, col.typ);
                    cmd.columns = cols;
                    break :blk cmd;
                }
                break :blk QailCmd.modify(self.table);
            },
            .create_index => blk: {
                if (self.index) |idx| {
                    var cmd = QailCmd.createIndex(idx.table);
                    cmd.index_def = .{
                        .name = idx.name,
                        .table = idx.table,
                        .columns = &.{},
                        .unique = idx.unique,
                    };
                    break :blk cmd;
                }
                break :blk QailCmd.createIndex(self.table);
            },
            .drop_index => blk: {
                if (self.index) |idx| {
                    break :blk QailCmd.dropIndex(idx.name);
                }
                break :blk QailCmd.dropIndex(self.table);
            },
            .create_policy => blk: {
                if (self.policy) |policy| {
                    break :blk QailCmd.createPolicy(policy);
                }
                return error.MissingPolicyDefinition;
            },
            .drop_policy => blk: {
                if (self.policy) |policy| {
                    break :blk QailCmd.dropPolicy(policy.name, policy.table);
                }
                return error.MissingPolicyDefinition;
            },
            .grant => blk: {
                if (self.grant) |grant_cmd| {
                    break :blk QailCmd.grant(grant_cmd.on_object, grant_cmd.privileges, grant_cmd.role);
                }
                return error.MissingGrantDefinition;
            },
            .revoke => blk: {
                if (self.grant) |grant_cmd| {
                    break :blk QailCmd.revoke(grant_cmd.on_object, grant_cmd.privileges, grant_cmd.role);
                }
                return error.MissingGrantDefinition;
            },
        };
    }

    pub fn toSql(self: *const MigrationCmd, allocator: Allocator) ![]const u8 {
        var writer = io.AllocatingWriter.init(allocator);
        defer writer.deinit();
        const w = writer.writer();

        switch (self.action) {
            .create_table => {
                // Render CREATE TABLE from AST columns
                try w.print("CREATE TABLE IF NOT EXISTS {s}", .{self.table});
                if (self.table_columns.len > 0) {
                    try w.writeAll(" (\n");
                    for (self.table_columns, 0..) |col, i| {
                        if (i > 0) try w.writeAll(",\n");
                        try w.print("    {s} {s}", .{ col.name, col.typ });
                        if (col.primary_key) try w.writeAll(" PRIMARY KEY");
                        if (!col.nullable and !col.primary_key) try w.writeAll(" NOT NULL");
                        if (col.unique and !col.primary_key) try w.writeAll(" UNIQUE");
                        if (col.default_value) |dv| {
                            try w.print(" DEFAULT {s}", .{dv});
                        }
                        if (col.references) |ref| {
                            try w.print(" REFERENCES {s}", .{ref});
                        }
                    }
                    try w.writeAll("\n)");
                }
            },
            .drop_table => {
                try w.print("DROP TABLE {s}", .{self.table});
            },
            .add_column => {
                if (self.column) |col| {
                    try w.print("ALTER TABLE {s} ADD COLUMN {s} {s}", .{
                        self.table,
                        col.name,
                        col.typ,
                    });
                    if (col.type_params) |params| {
                        try w.print("({s})", .{params});
                    }
                    if (!col.nullable) {
                        try w.writeAll(" NOT NULL");
                    }
                    if (col.default_value) |def| {
                        try w.print(" DEFAULT {s}", .{def});
                    }
                }
            },
            .drop_column => {
                if (self.column) |col| {
                    try w.print("ALTER TABLE {s} DROP COLUMN {s}", .{
                        self.table,
                        col.name,
                    });
                }
            },
            .alter_column => {
                if (self.column) |col| {
                    try w.print("ALTER TABLE {s} ALTER COLUMN {s} TYPE {s}", .{
                        self.table,
                        col.name,
                        col.typ,
                    });
                }
            },
            .create_index => {
                if (self.index) |idx| {
                    if (idx.unique) {
                        try w.print("CREATE UNIQUE INDEX {s} ON {s} ({s})", .{
                            idx.name,
                            idx.table,
                            idx.columns,
                        });
                    } else {
                        try w.print("CREATE INDEX {s} ON {s} ({s})", .{
                            idx.name,
                            idx.table,
                            idx.columns,
                        });
                    }
                }
            },
            .drop_index => {
                if (self.index) |idx| {
                    try w.print("DROP INDEX {s}", .{idx.name});
                }
            },
            .create_policy => {
                const policy = self.policy orelse return error.MissingPolicyDefinition;
                try w.print("CREATE POLICY {s} ON {s}", .{ policy.name, policy.table });
                if (policy.permissiveness == .restrictive) {
                    try w.writeAll(" AS RESTRICTIVE");
                }
                try w.print(" FOR {s}", .{policy.target.toSql()});
                if (policy.role) |role| {
                    try w.print(" TO {s}", .{role});
                }
                if (policy.using_sql) |using_sql| {
                    try w.print(" USING ({s})", .{using_sql});
                }
                if (policy.with_check_sql) |with_check_sql| {
                    try w.print(" WITH CHECK ({s})", .{with_check_sql});
                }
            },
            .drop_policy => {
                const policy = self.policy orelse return error.MissingPolicyDefinition;
                try w.print("DROP POLICY IF EXISTS {s} ON {s}", .{ policy.name, policy.table });
            },
            .grant => {
                const grant_cmd = self.grant orelse return error.MissingGrantDefinition;
                try w.writeAll("GRANT ");
                for (grant_cmd.privileges, 0..) |privilege, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(privilege);
                }
                try w.print(" ON {s} TO {s}", .{ grant_cmd.on_object, grant_cmd.role });
            },
            .revoke => {
                const grant_cmd = self.grant orelse return error.MissingGrantDefinition;
                try w.writeAll("REVOKE ");
                for (grant_cmd.privileges, 0..) |privilege, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(privilege);
                }
                try w.print(" ON {s} FROM {s}", .{ grant_cmd.on_object, grant_cmd.role });
            },
        }

        return writer.toOwnedSlice();
    }

    /// Generate DOWN (rollback) SQL for this migration command
    pub fn toDownSql(self: *const MigrationCmd, allocator: Allocator) ![]const u8 {
        var writer = io.AllocatingWriter.init(allocator);
        defer writer.deinit();
        const w = writer.writer();

        switch (self.action) {
            .create_table => {
                // CREATE TABLE -> DROP TABLE
                try w.print("DROP TABLE IF EXISTS {s}", .{self.table});
            },
            .drop_table => {
                // DROP TABLE -> cannot auto-rollback (data lost)
                try w.print("-- Cannot auto-rollback DROP TABLE {s} (data lost)", .{self.table});
            },
            .add_column => {
                // ADD COLUMN -> DROP COLUMN
                if (self.column) |col| {
                    try w.print("ALTER TABLE {s} DROP COLUMN {s}", .{ self.table, col.name });
                }
            },
            .drop_column => {
                // DROP COLUMN -> cannot auto-rollback (data lost)
                try w.print("-- Cannot auto-rollback DROP COLUMN on {s} (data lost)", .{self.table});
            },
            .alter_column => {
                // ALTER COLUMN TYPE -> cannot easily reverse (may need USING clause)
                try w.print("-- Cannot auto-rollback TYPE change on {s} (may need USING clause)", .{self.table});
            },
            .create_index => {
                // CREATE INDEX -> DROP INDEX
                if (self.index) |idx| {
                    try w.print("DROP INDEX IF EXISTS {s}", .{idx.name});
                }
            },
            .drop_index => {
                // DROP INDEX -> cannot auto-rollback (need original definition)
                try w.print("-- Cannot auto-rollback DROP INDEX (need original definition)", .{});
            },
            .create_policy => {
                if (self.policy) |policy| {
                    try w.print("DROP POLICY IF EXISTS {s} ON {s}", .{ policy.name, policy.table });
                } else {
                    try w.print("-- Cannot auto-rollback CREATE POLICY (definition missing)", .{});
                }
            },
            .drop_policy => {
                if (self.policy) |policy| {
                    try w.print("CREATE POLICY {s} ON {s}", .{ policy.name, policy.table });
                    if (policy.permissiveness == .restrictive) {
                        try w.writeAll(" AS RESTRICTIVE");
                    }
                    try w.print(" FOR {s}", .{policy.target.toSql()});
                    if (policy.role) |role| {
                        try w.print(" TO {s}", .{role});
                    }
                    if (policy.using_sql) |using_sql| {
                        try w.print(" USING ({s})", .{using_sql});
                    }
                    if (policy.with_check_sql) |with_check_sql| {
                        try w.print(" WITH CHECK ({s})", .{with_check_sql});
                    }
                } else {
                    try w.print("-- Cannot auto-rollback DROP POLICY (definition missing)", .{});
                }
            },
            .grant => {
                if (self.grant) |grant_cmd| {
                    try w.writeAll("REVOKE ");
                    for (grant_cmd.privileges, 0..) |privilege, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(privilege);
                    }
                    try w.print(" ON {s} FROM {s}", .{ grant_cmd.on_object, grant_cmd.role });
                } else {
                    try w.print("-- Cannot auto-rollback GRANT (definition missing)", .{});
                }
            },
            .revoke => {
                if (self.grant) |grant_cmd| {
                    try w.writeAll("GRANT ");
                    for (grant_cmd.privileges, 0..) |privilege, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(privilege);
                    }
                    try w.print(" ON {s} TO {s}", .{ grant_cmd.on_object, grant_cmd.role });
                } else {
                    try w.print("-- Cannot auto-rollback REVOKE (definition missing)", .{});
                }
            },
        }

        return writer.toOwnedSlice();
    }
};

pub const IndexInfo = struct {
    name: []const u8,
    table: []const u8,
    columns: []const u8,
    unique: bool = false,
};

fn optionalStrEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn policyEquals(a: *const PolicyDef, b: *const PolicyDef) bool {
    return std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.table, b.table) and
        a.target == b.target and
        a.permissiveness == b.permissiveness and
        optionalStrEq(a.role, b.role) and
        optionalStrEq(a.using_sql, b.using_sql) and
        optionalStrEq(a.with_check_sql, b.with_check_sql);
}

fn grantEquals(a: *const GrantDef, b: *const GrantDef) bool {
    if (a.action != b.action) return false;
    if (!std.mem.eql(u8, a.on_object, b.on_object)) return false;
    if (!std.mem.eql(u8, a.role, b.role)) return false;
    if (a.privileges.len != b.privileges.len) return false;
    for (a.privileges, 0..) |privilege, i| {
        if (!std.mem.eql(u8, privilege, b.privileges[i])) return false;
    }
    return true;
}

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
            if (!policyEquals(old_policy, new_policy)) {
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
            if (grantEquals(old_grant, new_grant)) {
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
            if (grantEquals(old_grant, new_grant)) {
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
    try std.testing.expect(std.mem.indexOf(u8, sql, "REVOKE select, insert ON users FROM app_role") != null);
}
