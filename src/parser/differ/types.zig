const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../../compat/io.zig");
const render = @import("../../transpiler/postgres/render.zig");
const schema = @import("../schema.zig");

const ColumnDef = schema.ColumnDef;
const PolicyDef = schema.PolicyDef;
const GrantDef = schema.GrantDef;

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
    pub fn toQailCmd(self: *const MigrationCmd, allocator: Allocator) !@import("../../ast/cmd.zig").QailCmd {
        const QailCmd = @import("../../ast/cmd.zig").QailCmd;
        const Expr = @import("../../ast/expr.zig").Expr;

        return switch (self.action) {
            .create_table => blk: {
                var cmd = QailCmd.make(self.table);
                if (self.table_columns.len > 0) {
                    const cols = try allocator.alloc(Expr, self.table_columns.len);
                    for (self.table_columns, 0..) |col_def, i| {
                        var type_buf: []const u8 = col_def.typ;
                        if (col_def.is_serial) {
                            type_buf = "serial";
                        }

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
                if (policy.using_expr) |using_expr| {
                    try w.writeAll(" USING (");
                    var expr = using_expr;
                    try render.writeExpr(w, &expr);
                    try w.writeByte(')');
                } else if (policy.using_sql) |using_sql| {
                    try w.print(" USING ({s})", .{using_sql});
                }
                if (policy.with_check_expr) |with_check_expr| {
                    try w.writeAll(" WITH CHECK (");
                    var expr = with_check_expr;
                    try render.writeExpr(w, &expr);
                    try w.writeByte(')');
                } else if (policy.with_check_sql) |with_check_sql| {
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
                try w.print("DROP TABLE IF EXISTS {s}", .{self.table});
            },
            .drop_table => {
                try w.print("-- Cannot auto-rollback DROP TABLE {s} (data lost)", .{self.table});
            },
            .add_column => {
                if (self.column) |col| {
                    try w.print("ALTER TABLE {s} DROP COLUMN {s}", .{ self.table, col.name });
                }
            },
            .drop_column => {
                try w.print("-- Cannot auto-rollback DROP COLUMN on {s} (data lost)", .{self.table});
            },
            .alter_column => {
                try w.print("-- Cannot auto-rollback TYPE change on {s} (may need USING clause)", .{self.table});
            },
            .create_index => {
                if (self.index) |idx| {
                    try w.print("DROP INDEX IF EXISTS {s}", .{idx.name});
                }
            },
            .drop_index => {
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
                    if (policy.using_expr) |using_expr| {
                        try w.writeAll(" USING (");
                        var expr = using_expr;
                        try render.writeExpr(w, &expr);
                        try w.writeByte(')');
                    } else if (policy.using_sql) |using_sql| {
                        try w.print(" USING ({s})", .{using_sql});
                    }
                    if (policy.with_check_expr) |with_check_expr| {
                        try w.writeAll(" WITH CHECK (");
                        var expr = with_check_expr;
                        try render.writeExpr(w, &expr);
                        try w.writeByte(')');
                    } else if (policy.with_check_sql) |with_check_sql| {
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
