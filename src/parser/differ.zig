// Schema Differ
//
// Computes the difference between two schemas and generates migration commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const Schema = schema.Schema;
const TableDef = schema.TableDef;
const ColumnDef = schema.ColumnDef;

// ============================================================================
// Migration Commands
// ============================================================================

pub const MigrationCmd = struct {
    action: Action,
    table: []const u8,
    column: ?ColumnDef = null,
    index: ?IndexInfo = null,
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
        };
    }

    pub fn toSql(self: *const MigrationCmd, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        const w = buf.writer(allocator);

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
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Generate DOWN (rollback) SQL for this migration command
    pub fn toDownSql(self: *const MigrationCmd, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        const w = buf.writer(allocator);

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
        }

        return buf.toOwnedSlice(allocator);
    }
};

pub const IndexInfo = struct {
    name: []const u8,
    table: []const u8,
    columns: []const u8,
    unique: bool = false,
};

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

    return cmds;
}

/// Generate SQL statements from migration commands
pub fn toSqlStatements(allocator: Allocator, cmds: *const std.ArrayList(MigrationCmd)) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const w = buf.writer(allocator);

    for (cmds.items) |cmd| {
        const sql = try cmd.toSql(allocator);
        defer allocator.free(sql);
        try w.print("{s};\n", .{sql});
    }

    return buf.toOwnedSlice(allocator);
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
