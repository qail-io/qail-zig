const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../../runtime/io.zig");
const render = @import("../../transpiler/postgres/render.zig");
const schema = @import("../schema.zig");
const ast_expr = @import("../../ast/expr.zig");

const ColumnDef = schema.ColumnDef;
const PolicyDef = schema.PolicyDef;
const GrantDef = schema.GrantDef;
const Expr = ast_expr.Expr;
const Constraint = ast_expr.Constraint;

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
        enable_rls,
        disable_rls,
        force_rls,
        no_force_rls,
    };

    fn writeColumnType(writer: anytype, col: ColumnDef) !void {
        if (col.is_serial) {
            try writer.writeAll(col.typ);
            return;
        }

        try writer.writeAll(col.typ);
        if (col.type_params) |params| {
            try writer.print("({s})", .{params});
        }
        if (col.is_array) {
            try writer.writeAll("[]");
        }
    }

    fn allocColumnType(allocator: Allocator, col: ColumnDef) ![]const u8 {
        var writer = io.AllocatingWriter.init(allocator);
        defer writer.deinit();
        try writeColumnType(writer.writer(), col);
        return writer.toOwnedSlice();
    }

    fn allocColumnConstraints(allocator: Allocator, col: ColumnDef) ![]const Constraint {
        const check_count = col.checkCount();
        if (check_count == 0) return &.{};

        const check_values = try allocator.alloc([]const u8, check_count);
        errdefer allocator.free(check_values);
        for (0..check_count) |i| {
            check_values[i] = col.checkAt(i);
        }

        const constraints = try allocator.alloc(Constraint, 1);
        constraints[0] = .{ .check = check_values };
        return constraints;
    }

    fn freeColumnConstraints(allocator: Allocator, constraints: []const Constraint) void {
        for (constraints) |constraint| {
            switch (constraint) {
                .check => |values| allocator.free(values),
                else => {},
            }
        }
        if (constraints.len > 0) allocator.free(constraints);
    }

    fn deinitColumnDefExpr(allocator: Allocator, expr: Expr) void {
        if (expr != .column_def) return;
        allocator.free(expr.column_def.data_type);
        freeColumnConstraints(allocator, expr.column_def.constraints);
    }

    fn allocColumnDefExpr(allocator: Allocator, col: ColumnDef, include_constraints: bool) !Expr {
        const type_buf = try allocColumnType(allocator, col);
        errdefer allocator.free(type_buf);

        const constraints = if (include_constraints)
            try allocColumnConstraints(allocator, col)
        else
            &.{};
        errdefer freeColumnConstraints(allocator, constraints);

        return .{
            .column_def = .{
                .name = col.name,
                .data_type = type_buf,
                .constraints = constraints,
                .is_primary_key = col.primary_key,
                .is_unique = col.unique,
                .is_not_null = !col.nullable,
                .default_value = col.default_value,
                .references = col.references,
            },
        };
    }

    pub fn deinitQailCmd(allocator: Allocator, cmd: *const @import("../../ast/cmd.zig").QailCmd) void {
        if (cmd.columns.len > 0) {
            for (cmd.columns) |col| {
                deinitColumnDefExpr(allocator, col);
            }

            const cols_ptr: [*]const Expr = cmd.columns.ptr;
            const cols_many: [*]Expr = @constCast(cols_ptr);
            allocator.free(cols_many[0..cmd.columns.len]);
        }

        if (cmd.index_def) |idx| {
            if (idx.columns.len > 0) {
                const idx_cols_ptr: [*]const []const u8 = idx.columns.ptr;
                const idx_cols_many: [*][]const u8 = @constCast(idx_cols_ptr);
                allocator.free(idx_cols_many[0..idx.columns.len]);
            }
            if (idx.include.len > 0) {
                const include_ptr: [*]const []const u8 = idx.include.ptr;
                const include_many: [*][]const u8 = @constCast(include_ptr);
                allocator.free(include_many[0..idx.include.len]);
            }
        }
    }

    /// Convert to QailCmd for AST-native execution (preferred method)
    /// NOTE: caller must invoke `deinitQailCmd` on returned commands.
    pub fn toQailCmd(self: *const MigrationCmd, allocator: Allocator) !@import("../../ast/cmd.zig").QailCmd {
        const QailCmd = @import("../../ast/cmd.zig").QailCmd;

        return switch (self.action) {
            .create_table => blk: {
                var cmd = QailCmd.make(self.table);
                if (self.table_columns.len > 0) {
                    const cols = try allocator.alloc(Expr, self.table_columns.len);
                    var initialized: usize = 0;
                    errdefer {
                        for (cols[0..initialized]) |expr| {
                            deinitColumnDefExpr(allocator, expr);
                        }
                        allocator.free(cols);
                    }

                    for (self.table_columns, 0..) |col_def, i| {
                        cols[i] = try allocColumnDefExpr(allocator, col_def, true);
                        initialized += 1;
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
                    var initialized = false;
                    errdefer {
                        if (initialized) deinitColumnDefExpr(allocator, cols[0]);
                        allocator.free(cols);
                    }
                    cols[0] = try allocColumnDefExpr(allocator, col, true);
                    initialized = true;
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
                    var initialized = false;
                    errdefer {
                        if (initialized) deinitColumnDefExpr(allocator, cols[0]);
                        allocator.free(cols);
                    }
                    cols[0] = try allocColumnDefExpr(allocator, col, false);
                    initialized = true;
                    cmd.columns = cols;
                    break :blk cmd;
                }
                break :blk QailCmd.modify(self.table);
            },
            .create_index => blk: {
                if (self.index) |idx| {
                    const index_columns = try allocIndexColumns(allocator, idx.columns);
                    errdefer allocator.free(index_columns);
                    const include_columns = try allocIndexIdentifiers(allocator, idx.include);
                    errdefer allocator.free(include_columns);
                    var cmd = QailCmd.createIndex(idx.table);
                    cmd.index_def = .{
                        .name = idx.name,
                        .table = idx.table,
                        .columns = index_columns,
                        .unique = idx.unique,
                        .index_type = idx.index_type,
                        .include = include_columns,
                        .concurrently = idx.concurrently,
                        .where_clause = idx.where_clause,
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
            .enable_rls => .{ .kind = .alter_enable_rls, .table = self.table },
            .disable_rls => .{ .kind = .alter_disable_rls, .table = self.table },
            .force_rls => .{ .kind = .alter_force_rls, .table = self.table },
            .no_force_rls => .{ .kind = .alter_no_force_rls, .table = self.table },
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
                        try w.print("    {s} ", .{col.name});
                        try writeColumnType(w, col);
                        if (col.primary_key) try w.writeAll(" PRIMARY KEY");
                        if (!col.nullable and !col.primary_key) try w.writeAll(" NOT NULL");
                        if (col.unique and !col.primary_key) try w.writeAll(" UNIQUE");
                        if (col.default_value) |dv| {
                            try w.print(" DEFAULT {s}", .{dv});
                        }
                        if (col.references) |ref| {
                            try w.print(" REFERENCES {s}", .{ref});
                        }
                        try writeColumnCheckConstraints(w, col);
                    }
                    try w.writeAll("\n)");
                }
            },
            .drop_table => {
                try w.print("DROP TABLE {s}", .{self.table});
            },
            .add_column => {
                if (self.column) |col| {
                    try w.print("ALTER TABLE {s} ADD COLUMN {s} ", .{
                        self.table,
                        col.name,
                    });
                    try writeColumnType(w, col);
                    if (!col.nullable) {
                        try w.writeAll(" NOT NULL");
                    }
                    if (col.unique and !col.primary_key) {
                        try w.writeAll(" UNIQUE");
                    }
                    if (col.default_value) |def| {
                        try w.print(" DEFAULT {s}", .{def});
                    }
                    if (col.references) |ref| {
                        try w.print(" REFERENCES {s}", .{ref});
                    }
                    try writeColumnCheckConstraints(w, col);
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
                    try w.print("ALTER TABLE {s} ALTER COLUMN {s} TYPE ", .{
                        self.table,
                        col.name,
                    });
                    try writeColumnType(w, col);
                }
            },
            .create_index => {
                if (self.index) |idx| {
                    const index_columns = try allocIndexColumns(allocator, idx.columns);
                    defer allocator.free(index_columns);

                    if (idx.unique) {
                        try w.writeAll("CREATE UNIQUE INDEX ");
                    } else {
                        try w.writeAll("CREATE INDEX ");
                    }
                    if (idx.concurrently) try w.writeAll("CONCURRENTLY ");
                    try w.print("{s} ON {s}", .{ idx.name, idx.table });
                    if (idx.index_type) |index_type| {
                        if (!isAllowedIndexMethod(index_type)) return error.InvalidIndexMethod;
                        try w.print(" USING {s}", .{index_type});
                    }
                    try w.writeAll(" (");
                    for (index_columns, 0..) |col, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(col);
                    }
                    try w.writeByte(')');
                    const include_columns = try allocIndexIdentifiers(allocator, idx.include);
                    defer allocator.free(include_columns);
                    if (include_columns.len > 0) {
                        try w.writeAll(" INCLUDE (");
                        for (include_columns, 0..) |col, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(col);
                        }
                        try w.writeByte(')');
                    }
                    if (idx.where_clause) |where_clause| {
                        const checked = checkedSqlExprFragment(where_clause) orelse return error.UnsafeSqlFragment;
                        try w.print(" WHERE {s}", .{checked});
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
                }
                if (policy.with_check_expr) |with_check_expr| {
                    try w.writeAll(" WITH CHECK (");
                    var expr = with_check_expr;
                    try render.writeExpr(w, &expr);
                    try w.writeByte(')');
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
            .enable_rls => {
                try w.print("ALTER TABLE {s} ENABLE ROW LEVEL SECURITY", .{self.table});
            },
            .disable_rls => {
                try w.print("ALTER TABLE {s} DISABLE ROW LEVEL SECURITY", .{self.table});
            },
            .force_rls => {
                try w.print("ALTER TABLE {s} FORCE ROW LEVEL SECURITY", .{self.table});
            },
            .no_force_rls => {
                try w.print("ALTER TABLE {s} NO FORCE ROW LEVEL SECURITY", .{self.table});
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
                    }
                    if (policy.with_check_expr) |with_check_expr| {
                        try w.writeAll(" WITH CHECK (");
                        var expr = with_check_expr;
                        try render.writeExpr(w, &expr);
                        try w.writeByte(')');
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
            .enable_rls => {
                try w.print("ALTER TABLE {s} DISABLE ROW LEVEL SECURITY", .{self.table});
            },
            .disable_rls => {
                try w.print("ALTER TABLE {s} ENABLE ROW LEVEL SECURITY", .{self.table});
            },
            .force_rls => {
                try w.print("ALTER TABLE {s} NO FORCE ROW LEVEL SECURITY", .{self.table});
            },
            .no_force_rls => {
                try w.print("ALTER TABLE {s} FORCE ROW LEVEL SECURITY", .{self.table});
            },
        }

        return writer.toOwnedSlice();
    }
};

fn writeCheckConstraint(writer: anytype, expr: []const u8) !void {
    const trimmed = checkedSqlExprFragment(expr) orelse return error.UnsafeSqlFragment;
    try writer.print(" CHECK ({s})", .{trimmed});
}

fn writeColumnCheckConstraints(writer: anytype, col: ColumnDef) !void {
    const check_count = col.checkCount();
    for (0..check_count) |i| {
        try writeCheckConstraint(writer, col.checkAt(i));
    }
}

fn checkedSqlExprFragment(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or containsUnquotedStatementDelimiter(trimmed)) return null;
    return trimmed;
}

fn allocIndexColumns(allocator: Allocator, columns: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, columns, ',');
    while (parts.next()) |part| {
        const column = std.mem.trim(u8, part, " \t\r\n");
        if (!isSafeIndexElement(column)) return error.InvalidIndexColumns;
        try out.append(allocator, column);
    }

    if (out.items.len == 0) return error.InvalidIndexColumns;
    return try out.toOwnedSlice(allocator);
}

fn allocIndexIdentifiers(allocator: Allocator, columns: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, columns, " \t\r\n");
    if (trimmed.len == 0) return &.{};

    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const column = std.mem.trim(u8, part, " \t\r\n");
        if (!isSimpleIndexIdentifier(column)) return error.InvalidIndexColumns;
        try out.append(allocator, column);
    }

    return try out.toOwnedSlice(allocator);
}

fn isSafeIndexElement(element: []const u8) bool {
    if (element.len == 0 or containsUnquotedStatementDelimiter(element)) return false;
    if (std.mem.indexOfScalar(u8, element, '(') != null or
        std.mem.indexOfScalar(u8, element, ')') != null or
        std.mem.indexOfScalar(u8, element, '\'') != null or
        std.mem.indexOfScalar(u8, element, '"') != null)
    {
        return false;
    }

    var tokens = std.mem.tokenizeAny(u8, element, " \t\r\n");
    const column = tokens.next() orelse return false;
    if (!isSimpleIndexIdentifier(column)) return false;

    while (tokens.next()) |token| {
        if (!isAllowedIndexModifier(token)) return false;
    }
    return true;
}

fn isAllowedIndexModifier(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "asc") or
        std.ascii.eqlIgnoreCase(token, "desc") or
        std.ascii.eqlIgnoreCase(token, "nulls") or
        std.ascii.eqlIgnoreCase(token, "first") or
        std.ascii.eqlIgnoreCase(token, "last") or
        isAllowedIndexOpclass(token);
}

fn isAllowedIndexOpclass(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '_') == null) return false;
    if (token.len == 0 or !std.ascii.isAlphabetic(token[0])) return false;
    for (token[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isSimpleIndexIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or std.mem.startsWith(u8, identifier, ".") or std.mem.endsWith(u8, identifier, ".")) {
        return false;
    }
    var parts = std.mem.splitScalar(u8, identifier, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (!(std.ascii.isAlphabetic(part[0]) or part[0] == '_')) return false;
        for (part[1..]) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        }
    }
    return true;
}

fn isAllowedIndexMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "btree") or
        std.ascii.eqlIgnoreCase(method, "hash") or
        std.ascii.eqlIgnoreCase(method, "gin") or
        std.ascii.eqlIgnoreCase(method, "gist") or
        std.ascii.eqlIgnoreCase(method, "brin") or
        std.ascii.eqlIgnoreCase(method, "spgist") or
        std.ascii.eqlIgnoreCase(method, "hnsw") or
        std.ascii.eqlIgnoreCase(method, "ivfflat");
}

fn containsUnquotedStatementDelimiter(value: []const u8) bool {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;

    while (i < value.len) {
        const b = value[i];
        if (b == 0) return true;

        if (in_single) {
            if (b == '\'') {
                if (i + 1 < value.len and value[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                in_single = false;
            }
            i += 1;
            continue;
        }

        if (in_double) {
            if (b == '"') {
                if (i + 1 < value.len and value[i + 1] == '"') {
                    i += 2;
                    continue;
                }
                in_double = false;
            }
            i += 1;
            continue;
        }

        switch (b) {
            '\'' => in_single = true,
            '"' => in_double = true,
            ';' => return true,
            '-' => if (i + 1 < value.len and value[i + 1] == '-') return true,
            '/' => if (i + 1 < value.len and value[i + 1] == '*') return true,
            '*' => if (i + 1 < value.len and value[i + 1] == '/') return true,
            else => {},
        }
        i += 1;
    }

    return false;
}

pub const IndexInfo = struct {
    name: []const u8,
    table: []const u8,
    columns: []const u8,
    unique: bool = false,
    index_type: ?[]const u8 = null,
    include: []const u8 = "",
    concurrently: bool = false,
    where_clause: ?[]const u8 = null,
};
