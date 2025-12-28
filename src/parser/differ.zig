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

    pub const Action = enum {
        create_table,
        drop_table,
        add_column,
        drop_column,
        alter_column,
        create_index,
        drop_index,
    };

    pub fn toSql(self: *const MigrationCmd, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        const w = buf.writer(allocator);

        switch (self.action) {
            .create_table => {
                try w.print("CREATE TABLE {s}", .{self.table});
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

    // 1. Detect new tables
    for (new.tables.items) |new_table| {
        if (old.findTable(new_table.name) == null) {
            try cmds.append(allocator, MigrationCmd{
                .action = .create_table,
                .table = new_table.name,
            });

            // Add all columns for new table
            for (new_table.columns.items) |col| {
                try cmds.append(allocator, MigrationCmd{
                    .action = .add_column,
                    .table = new_table.name,
                    .column = col,
                });
            }
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
    defer cmds.deinit(allocator);

    // Should have: create_table + 2 add_column
    try std.testing.expectEqual(@as(usize, 3), cmds.items.len);
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
    defer cmds.deinit(allocator);

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
    defer cmds.deinit(allocator);

    const sql = try toSqlStatements(allocator, &cmds);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ADD COLUMN id uuid") != null);
}
