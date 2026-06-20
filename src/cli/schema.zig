const std = @import("std");
const Allocator = std.mem.Allocator;
const QailCmd = @import("../ast/cmd.zig").QailCmd;
const Expr = @import("../ast/expr.zig").Expr;
const Join = @import("../ast/cmd.zig").Join;
const MigrationCmd = @import("../parser/mod.zig").MigrationCmd;
const schema_types = @import("../parser/schema/types.zig");
const io_compat = @import("../runtime/io.zig");

const print = std.debug.print;

pub const NormalizedType = struct {
    typ: []const u8,
    is_array: bool,
    suppress_default: bool,
};

pub const RenderedSchemaSnapshot = struct {
    schema: []u8,
    table_count: usize,
    column_count: usize,
};

const LiveTableRls = struct {
    enable: bool = false,
    force: bool = false,
};

const LiveForeignKeyReference = struct {
    reference: []u8,
    on_delete: ?[]u8 = null,
    on_update: ?[]u8 = null,
    deferrable: ?[]u8 = null,

    fn deinit(self: *LiveForeignKeyReference, allocator: Allocator) void {
        allocator.free(self.reference);
        if (self.on_delete) |action| allocator.free(action);
        if (self.on_update) |action| allocator.free(action);
        if (self.deferrable) |mode| allocator.free(mode);
    }
};

const LiveColumnCheck = struct {
    expr: []u8,
    name: ?[]u8 = null,

    fn deinit(self: *LiveColumnCheck, allocator: Allocator) void {
        allocator.free(self.expr);
        if (self.name) |name| allocator.free(name);
    }
};

fn deinitFetchedRows(allocator: Allocator, rows: []@import("../driver/row.zig").PgRow) void {
    for (rows) |*row| {
        var owned = row.*;
        owned.deinit();
    }
    allocator.free(rows);
}

fn deinitMigrationCmds(
    allocator: Allocator,
    cmds: *std.ArrayList(@import("../parser/mod.zig").MigrationCmd),
) void {
    for (cmds.items) |cmd| {
        if (cmd.table_columns.len > 0) allocator.free(cmd.table_columns);
    }
    cmds.deinit(allocator);
}

fn putOwnedStringSetKey(allocator: Allocator, set: *std.StringHashMap(void), key: []u8) !void {
    errdefer allocator.free(key);
    const gop = try set.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        return;
    }
    gop.value_ptr.* = {};
}

fn putStringSetKey(allocator: Allocator, set: *std.StringHashMap(void), key: []const u8) !void {
    const owned = try allocator.dupe(u8, key);
    try putOwnedStringSetKey(allocator, set, owned);
}

fn deinitStringSet(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    set.deinit();
}

fn deinitStringMap(allocator: Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn deinitTableRlsMap(allocator: Allocator, map: *std.StringHashMap(LiveTableRls)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

fn deinitLiveForeignKeyReferenceMap(allocator: Allocator, map: *std.StringHashMap(LiveForeignKeyReference)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn deinitLiveMultiColumnForeignKeyMap(allocator: Allocator, map: *std.StringHashMap(std.ArrayList(schema_types.MultiColumnForeignKey))) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        for (entry.value_ptr.items) |*fk| fk.deinit(allocator);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn deinitIndexDefList(allocator: Allocator, indexes: *std.ArrayList(schema_types.IndexDef)) void {
    for (indexes.items) |*index| {
        index.deinit(allocator);
    }
    indexes.deinit(allocator);
}

fn putOwnedStringMapValue(
    allocator: Allocator,
    map: *std.StringHashMap([]u8),
    key: []u8,
    value: []u8,
) !void {
    errdefer allocator.free(key);
    errdefer allocator.free(value);

    const gop = try map.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        allocator.free(value);
        return;
    }

    gop.value_ptr.* = value;
}

fn putOwnedLiveForeignKeyReference(
    allocator: Allocator,
    map: *std.StringHashMap(LiveForeignKeyReference),
    key: []u8,
    value: LiveForeignKeyReference,
) !void {
    var owned_value = value;
    errdefer allocator.free(key);
    errdefer owned_value.deinit(allocator);

    const gop = try map.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        owned_value.deinit(allocator);
        return;
    }

    gop.value_ptr.* = owned_value;
}

fn appendOwnedLiveMultiColumnForeignKey(
    allocator: Allocator,
    map: *std.StringHashMap(std.ArrayList(schema_types.MultiColumnForeignKey)),
    key: []u8,
    value: schema_types.MultiColumnForeignKey,
) !void {
    var owned_value = value;
    errdefer owned_value.deinit(allocator);

    const gop = try map.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        try gop.value_ptr.append(allocator, owned_value);
    } else {
        gop.value_ptr.* = std.ArrayList(schema_types.MultiColumnForeignKey).initCapacity(allocator, 0) catch unreachable;
        errdefer {
            const removed = map.fetchRemove(key);
            if (removed) |entry| {
                allocator.free(entry.key);
                var removed_list = entry.value;
                removed_list.deinit(allocator);
            }
        }
        try gop.value_ptr.append(allocator, owned_value);
    }
}

fn deinitCheckMap(allocator: Allocator, checks: *std.StringHashMap(std.ArrayList(LiveColumnCheck))) void {
    var it = checks.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        for (entry.value_ptr.items) |*check| check.deinit(allocator);
        entry.value_ptr.deinit(allocator);
    }
    checks.deinit();
}

fn appendOwnedColumnCheck(
    allocator: Allocator,
    checks: *std.StringHashMap(std.ArrayList(LiveColumnCheck)),
    key: []u8,
    check: LiveColumnCheck,
) !void {
    var owned_check = check;
    var owns_key = true;
    var owns_check = true;
    errdefer if (owns_key) allocator.free(key);
    errdefer if (owns_check) owned_check.deinit(allocator);

    var new_list = try std.ArrayList(LiveColumnCheck).initCapacity(allocator, 1);
    var owns_list = true;
    defer if (owns_list) new_list.deinit(allocator);
    try new_list.append(allocator, owned_check);

    const gop = try checks.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        owns_key = false;
        try gop.value_ptr.append(allocator, owned_check);
        owns_check = false;
        return;
    }

    gop.value_ptr.* = new_list;
    owns_list = false;
    owns_key = false;
    owns_check = false;
}

fn connectPgUrl(
    allocator: Allocator,
    url: []const u8,
) !@import("../driver/driver.zig").PgDriver {
    const driver_mod = @import("../driver/mod.zig");
    return try driver_mod.driver.PgDriver.connectUrl(allocator, url);
}

fn executeMigrationCmds(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    cmds: []const MigrationCmd,
    label: []const u8,
) !void {
    for (cmds, 0..) |migration_cmd, i| {
        const stmt_sql = migration_cmd.toSql(allocator) catch |err| {
            print("Error rendering SQL for {s} step {d}: {}\n", .{ label, i + 1, err });
            return err;
        };
        defer allocator.free(stmt_sql);

        const qail_cmd = migration_cmd.toQailCmd(allocator) catch |err| {
            print("Error converting {s} step {d} to AST command: {}\n", .{ label, i + 1, err });
            return err;
        };
        defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);

        print("  [{s} {d}] {s};\n", .{ label, i + 1, stmt_sql });
        _ = pg.execute(&qail_cmd) catch |err| {
            print("Error executing {s} step {d}: {}\n", .{ label, i + 1, err });
            return err;
        };
    }
}

fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io_compat.runtimeIo(),
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn collectBaseTables(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    base_tables: *std.StringHashMap(void),
) !void {
    const cmd = QailCmd.get("information_schema.tables")
        .select(&.{
            Expr.col("table_name"),
        }).where(&.{
            .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
            .{ .condition = .{ .column = "table_type", .op = .eq, .value = .{ .string = "BASE TABLE" } } },
        }).orderBy(&.{
        .{ .column = "table_name", .order = .asc },
    });
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const table_name = row.getByName("table_name") orelse continue;
        if (std.mem.startsWith(u8, table_name, "_qail_")) continue;
        try putStringSetKey(allocator, base_tables, table_name);
    }
}

fn livePgBool(value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "t") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.mem.eql(u8, trimmed, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "f") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "no") or
        std.mem.eql(u8, trimmed, "0"))
    {
        return false;
    }
    return error.InvalidLiveBoolean;
}

fn collectTableRls(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    base_tables: *const std.StringHashMap(void),
    table_rls: *std.StringHashMap(LiveTableRls),
) !void {
    const joins = [_]Join{
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_namespace",
            .alias = "ns",
            .on_left = "ns.oid",
            .on_right = "cls.relnamespace",
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_class")
        .alias("cls")
        .join(&joins)
        .select(&.{
            Expr.colAs("cls.relname", "table_name"),
            Expr.colAs("cls.relrowsecurity", "enable_rls"),
            Expr.colAs("cls.relforcerowsecurity", "force_rls"),
        }).where(&.{
            .{ .condition = .{ .column = "ns.nspname", .op = .eq, .value = .{ .string = "public" } } },
            .{ .condition = .{ .column = "cls.relkind", .op = .eq, .value = .{ .string = "r" } } },
        }).orderBy(&.{
        .{ .column = "cls.relname", .order = .asc },
    });
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const table_name = row.getByName("table_name") orelse continue;
        if (!base_tables.contains(table_name)) continue;

        const enable = try livePgBool(row.getByName("enable_rls") orelse "false");
        const force = try livePgBool(row.getByName("force_rls") orelse "false");
        if (!enable and !force) continue;

        const owned_name = try allocator.dupe(u8, table_name);
        errdefer allocator.free(owned_name);
        const gop = try table_rls.getOrPut(owned_name);
        if (gop.found_existing) {
            allocator.free(owned_name);
        }
        gop.value_ptr.* = .{
            .enable = enable,
            .force = force,
        };
    }
}

fn collectConstraintIndexNames(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    constraint_indexes: *std.StringHashMap(void),
) !void {
    const joins = [_]Join{
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_class",
            .alias = "idx",
            .on_left = "idx.oid",
            .on_right = "con.conindid",
        },
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_namespace",
            .alias = "ns",
            .on_left = "ns.oid",
            .on_right = "con.connamespace",
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_constraint")
        .alias("con")
        .join(&joins)
        .select(&.{
            Expr.colAs("idx.relname", "index_name"),
        }).where(&.{
        .{ .condition = .{ .column = "ns.nspname", .op = .eq, .value = .{ .string = "public" } } },
    });
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const index_name = row.getByName("index_name") orelse continue;
        try putStringSetKey(allocator, constraint_indexes, index_name);
    }
}

fn collectConstrainedColumns(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    constraint_type: []const u8,
    constrained_columns: *std.StringHashMap(void),
) !void {
    const constraints_cmd = QailCmd.get("information_schema.table_constraints")
        .select(&.{
            Expr.col("table_name"),
            Expr.col("constraint_name"),
        }).where(&.{
        .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
        .{ .condition = .{ .column = "constraint_type", .op = .eq, .value = .{ .string = constraint_type } } },
    });
    const constraints = try pg.fetchAll(&constraints_cmd);
    defer deinitFetchedRows(allocator, constraints);

    for (constraints) |constraint| {
        const table_name = constraint.getByName("table_name") orelse continue;
        const constraint_name = constraint.getByName("constraint_name") orelse continue;

        const kcu_cmd = QailCmd.get("information_schema.key_column_usage")
            .select(&.{
                Expr.col("table_name"),
                Expr.col("column_name"),
            }).where(&.{
                .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
                .{ .condition = .{ .column = "table_name", .op = .eq, .value = .{ .string = table_name } } },
                .{ .condition = .{ .column = "constraint_name", .op = .eq, .value = .{ .string = constraint_name } } },
            }).orderBy(&.{
            .{ .column = "ordinal_position", .order = .asc },
        });
        const key_columns = try pg.fetchAll(&kcu_cmd);
        defer deinitFetchedRows(allocator, key_columns);

        for (key_columns) |key_col| {
            const col_name = key_col.getByName("column_name") orelse continue;
            const composite = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table_name, col_name });
            try putOwnedStringSetKey(allocator, constrained_columns, composite);
        }
    }
}

fn collectUniqueConstraints(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    base_tables: *const std.StringHashMap(void),
    unique_columns: *std.StringHashMap(void),
    unique_constraint_indexes: *std.ArrayList(schema_types.IndexDef),
) !void {
    const constraints_cmd = QailCmd.get("information_schema.table_constraints")
        .select(&.{
            Expr.col("table_name"),
            Expr.col("constraint_name"),
        }).where(&.{
            .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
            .{ .condition = .{ .column = "constraint_type", .op = .eq, .value = .{ .string = "UNIQUE" } } },
        }).orderBy(&.{
        .{ .column = "table_name", .order = .asc },
        .{ .column = "constraint_name", .order = .asc },
    });
    const constraints = try pg.fetchAll(&constraints_cmd);
    defer deinitFetchedRows(allocator, constraints);

    for (constraints) |constraint| {
        const table_name = constraint.getByName("table_name") orelse continue;
        const constraint_name = constraint.getByName("constraint_name") orelse continue;
        if (!base_tables.contains(table_name)) continue;
        if (!isLiveSchemaIdentifier(table_name) or !isLiveSchemaIdentifier(constraint_name)) {
            return error.UnsupportedLiveIndexIdentifier;
        }

        const kcu_cmd = QailCmd.get("information_schema.key_column_usage")
            .select(&.{
                Expr.col("column_name"),
            }).where(&.{
                .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
                .{ .condition = .{ .column = "table_name", .op = .eq, .value = .{ .string = table_name } } },
                .{ .condition = .{ .column = "constraint_name", .op = .eq, .value = .{ .string = constraint_name } } },
            }).orderBy(&.{
            .{ .column = "ordinal_position", .order = .asc },
        });
        const key_columns = try pg.fetchAll(&kcu_cmd);
        defer deinitFetchedRows(allocator, key_columns);

        const columns = try liveConstraintColumnList(allocator, key_columns);
        defer freeLiveIdentifierList(allocator, columns);
        if (columns.len == 0) continue;

        if (columns.len == 1) {
            const composite = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table_name, columns[0] });
            try putOwnedStringSetKey(allocator, unique_columns, composite);
            continue;
        }

        const index_name = try allocator.dupe(u8, constraint_name);
        errdefer allocator.free(index_name);
        const index_table = try allocator.dupe(u8, table_name);
        errdefer allocator.free(index_table);
        const column_list = try allocLiveIdentifierList(allocator, columns);
        errdefer allocator.free(column_list);
        try unique_constraint_indexes.append(allocator, .{
            .name = index_name,
            .table = index_table,
            .columns = column_list,
            .unique = true,
        });
    }
}

fn collectColumnAttnums(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    attnum_columns: *std.StringHashMap([]u8),
) !void {
    const joins = [_]Join{
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_class",
            .alias = "src",
            .on_left = "src.oid",
            .on_right = "att.attrelid",
        },
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_namespace",
            .alias = "ns",
            .on_left = "ns.oid",
            .on_right = "src.relnamespace",
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_attribute")
        .alias("att")
        .join(&joins)
        .select(&.{
            Expr.colAs("src.relname", "table_name"),
            Expr.colAs("att.attnum", "attnum"),
            Expr.colAs("att.attname", "column_name"),
        }).where(&.{
            .{ .condition = .{ .column = "ns.nspname", .op = .eq, .value = .{ .string = "public" } } },
            .{ .condition = .{ .column = "att.attnum", .op = .gt, .value = .{ .int = 0 } } },
            .{ .condition = .{ .column = "att.attisdropped", .op = .eq, .value = .{ .bool = false } } },
        }).orderBy(&.{
        .{ .column = "src.relname", .order = .asc },
        .{ .column = "att.attnum", .order = .asc },
    });
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const table_name = row.getByName("table_name") orelse continue;
        if (std.mem.startsWith(u8, table_name, "_qail_")) continue;
        const attnum = row.getByName("attnum") orelse continue;
        const column_name = row.getByName("column_name") orelse continue;

        const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table_name, attnum });
        const value = try allocator.dupe(u8, column_name);
        try putOwnedStringMapValue(allocator, attnum_columns, key, value);
    }
}

fn collectCheckConstraints(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    attnum_columns: *const std.StringHashMap([]u8),
    checks: *std.StringHashMap(std.ArrayList(LiveColumnCheck)),
) !void {
    const joins = [_]Join{
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_class",
            .alias = "src",
            .on_left = "src.oid",
            .on_right = "con.conrelid",
        },
        .{
            .kind = .inner,
            .table = "pg_catalog.pg_namespace",
            .alias = "ns",
            .on_left = "ns.oid",
            .on_right = "con.connamespace",
        },
    };
    const pg_get_expr_args = [_]Expr{
        Expr.col("con.conbin"),
        Expr.col("con.conrelid"),
    };
    const columns = [_]Expr{
        Expr.colAs("con.conname", "constraint_name"),
        Expr.colAs("src.relname", "table_name"),
        Expr.colAs("con.conkey", "conkey"),
        .{ .func_call = .{
            .name = "pg_catalog.pg_get_expr",
            .args = &pg_get_expr_args,
            .alias = "check_clause",
        } },
    };
    const cmd = QailCmd.get("pg_catalog.pg_constraint")
        .alias("con")
        .join(&joins)
        .select(&columns)
        .where(&.{
            .{ .condition = .{ .column = "con.contype", .op = .eq, .value = .{ .string = "c" } } },
            .{ .condition = .{ .column = "ns.nspname", .op = .eq, .value = .{ .string = "public" } } },
        }).orderBy(&.{
        .{ .column = "src.relname", .order = .asc },
        .{ .column = "con.conname", .order = .asc },
    });
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const table_name = row.getByName("table_name") orelse continue;
        if (std.mem.startsWith(u8, table_name, "_qail_")) continue;

        const raw_conkey = row.getByName("conkey") orelse continue;
        if (std.mem.trim(u8, raw_conkey, " \t\r\n").len == 0) continue;

        const check_clause_raw = row.getByName("check_clause") orelse continue;
        const check_clause = std.mem.trim(u8, check_clause_raw, " \t\r\n");
        if (check_clause.len == 0 or isTrivialNotNullCheck(check_clause)) continue;

        const column_name = try checkConstraintAnchorColumn(
            allocator,
            table_name,
            raw_conkey,
            attnum_columns,
            check_clause,
        ) orelse continue;

        const constraint_name = row.getByName("constraint_name") orelse continue;
        if (!isLiveSchemaIdentifier(constraint_name)) return error.UnsupportedLiveCheckIdentifier;
        const composite = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table_name, column_name });
        var owns_composite = true;
        errdefer if (owns_composite) allocator.free(composite);
        var check = LiveColumnCheck{
            .expr = try allocator.dupe(u8, check_clause),
            .name = try allocator.dupe(u8, constraint_name),
        };
        var moved_check = false;
        errdefer if (!moved_check) check.deinit(allocator);
        owns_composite = false;
        moved_check = true;
        try appendOwnedColumnCheck(allocator, checks, composite, check);
    }
}

fn collectForeignKeyReferences(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    refs: *std.StringHashMap(LiveForeignKeyReference),
    composite_refs: *std.StringHashMap(std.ArrayList(schema_types.MultiColumnForeignKey)),
) !void {
    const fk_constraints_cmd = QailCmd.get("information_schema.table_constraints")
        .select(&.{
            Expr.col("constraint_schema"),
            Expr.col("constraint_name"),
            Expr.col("table_name"),
            Expr.col("is_deferrable"),
            Expr.col("initially_deferred"),
        }).where(&.{
            .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
            .{ .condition = .{ .column = "constraint_type", .op = .eq, .value = .{ .string = "FOREIGN KEY" } } },
        }).orderBy(&.{
        .{ .column = "table_name", .order = .asc },
        .{ .column = "constraint_name", .order = .asc },
    });
    const fk_constraints = try pg.fetchAll(&fk_constraints_cmd);
    defer deinitFetchedRows(allocator, fk_constraints);

    for (fk_constraints) |fk_constraint| {
        const constraint_schema = fk_constraint.getByName("constraint_schema") orelse continue;
        const constraint_name = fk_constraint.getByName("constraint_name") orelse continue;
        const table_name = fk_constraint.getByName("table_name") orelse continue;
        const is_deferrable = fk_constraint.getByName("is_deferrable") orelse "NO";
        const initially_deferred = fk_constraint.getByName("initially_deferred") orelse "NO";
        if (std.mem.startsWith(u8, table_name, "_qail_")) continue;

        const rc_cmd = QailCmd.get("information_schema.referential_constraints")
            .select(&.{
                Expr.col("unique_constraint_schema"),
                Expr.col("unique_constraint_name"),
                Expr.col("match_option"),
                Expr.col("update_rule"),
                Expr.col("delete_rule"),
            }).where(&.{
                .{ .condition = .{ .column = "constraint_schema", .op = .eq, .value = .{ .string = constraint_schema } } },
                .{ .condition = .{ .column = "constraint_name", .op = .eq, .value = .{ .string = constraint_name } } },
            }).limit(2);
        const refs_rows = try pg.fetchAll(&rc_cmd);
        defer deinitFetchedRows(allocator, refs_rows);
        if (refs_rows.len != 1) return error.InvalidLiveForeignKeyMetadata;

        const unique_constraint_schema = refs_rows[0].getByName("unique_constraint_schema") orelse continue;
        const unique_constraint_name = refs_rows[0].getByName("unique_constraint_name") orelse continue;
        const match_option = refs_rows[0].getByName("match_option") orelse "";
        const update_rule = refs_rows[0].getByName("update_rule") orelse "";
        const delete_rule = refs_rows[0].getByName("delete_rule") orelse "";
        if (!std.ascii.eqlIgnoreCase(match_option, "NONE")) return error.UnsupportedLiveForeignKeyAction;
        const on_update = try liveForeignKeyActionToken(update_rule);
        const on_delete = try liveForeignKeyActionToken(delete_rule);
        const deferrable = try liveForeignKeyDeferrableToken(is_deferrable, initially_deferred);

        const source_cols = try collectForeignKeyColumns(
            pg,
            constraint_schema,
            constraint_name,
            table_name,
        );
        defer deinitFetchedRows(allocator, source_cols);

        const target_cols = try collectForeignKeyColumns(
            pg,
            unique_constraint_schema,
            unique_constraint_name,
            null,
        );
        defer deinitFetchedRows(allocator, target_cols);
        if (source_cols.len != target_cols.len or source_cols.len == 0) return error.InvalidLiveForeignKeyMetadata;

        const target_schema = target_cols[0].getByName("table_schema") orelse continue;
        const target_table = target_cols[0].getByName("table_name") orelse continue;
        if (!std.mem.eql(u8, target_schema, "public")) return error.UnsupportedCrossSchemaForeignKey;
        if (!isLiveSchemaIdentifier(target_table)) return error.UnsupportedLiveForeignKeyIdentifier;

        if (source_cols.len == 1) {
            const source_column = source_cols[0].getByName("column_name") orelse continue;
            const target_column = target_cols[0].getByName("column_name") orelse continue;
            if (!isLiveSchemaIdentifier(source_column) or !isLiveSchemaIdentifier(target_column)) {
                return error.UnsupportedLiveForeignKeyIdentifier;
            }

            const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table_name, source_column });
            var value = LiveForeignKeyReference{
                .reference = try std.fmt.allocPrint(allocator, "{s}({s})", .{ target_table, target_column }),
            };
            errdefer value.deinit(allocator);
            if (on_delete) |action| value.on_delete = try allocator.dupe(u8, action);
            if (on_update) |action| value.on_update = try allocator.dupe(u8, action);
            if (deferrable) |mode| value.deferrable = try allocator.dupe(u8, mode);
            try putOwnedLiveForeignKeyReference(allocator, refs, key, value);
            continue;
        }

        if (!isLiveSchemaIdentifier(constraint_name)) return error.UnsupportedLiveForeignKeyIdentifier;
        const columns = try liveForeignKeyColumnList(allocator, source_cols);
        var columns_moved = false;
        errdefer if (!columns_moved) freeLiveForeignKeyColumnList(allocator, columns);
        const ref_columns = try liveForeignKeyColumnList(allocator, target_cols);
        var ref_columns_moved = false;
        errdefer if (!ref_columns_moved) freeLiveForeignKeyColumnList(allocator, ref_columns);

        var fk = schema_types.MultiColumnForeignKey{
            .name = try allocator.dupe(u8, constraint_name),
            .columns = columns,
            .ref_table = try allocator.dupe(u8, target_table),
            .ref_columns = ref_columns,
        };
        columns_moved = true;
        ref_columns_moved = true;
        errdefer fk.deinit(allocator);
        if (on_delete) |action| fk.on_delete = try allocator.dupe(u8, action);
        if (on_update) |action| fk.on_update = try allocator.dupe(u8, action);
        if (deferrable) |mode| fk.deferrable = try allocator.dupe(u8, mode);

        try appendOwnedLiveMultiColumnForeignKey(
            allocator,
            composite_refs,
            try allocator.dupe(u8, table_name),
            fk,
        );
    }
}

fn collectForeignKeyColumns(
    pg: *@import("../driver/driver.zig").PgDriver,
    constraint_schema: []const u8,
    constraint_name: []const u8,
    table_name: ?[]const u8,
) ![]@import("../driver/row.zig").PgRow {
    if (table_name) |source_table| {
        const cmd = QailCmd.get("information_schema.key_column_usage")
            .select(&.{
                Expr.col("table_schema"),
                Expr.col("table_name"),
                Expr.col("column_name"),
                Expr.col("ordinal_position"),
                Expr.col("position_in_unique_constraint"),
            }).where(&.{
                .{ .condition = .{ .column = "constraint_schema", .op = .eq, .value = .{ .string = constraint_schema } } },
                .{ .condition = .{ .column = "constraint_name", .op = .eq, .value = .{ .string = constraint_name } } },
                .{ .condition = .{ .column = "table_name", .op = .eq, .value = .{ .string = source_table } } },
            }).orderBy(&.{
            .{ .column = "ordinal_position", .order = .asc },
        });
        return try pg.fetchAll(&cmd);
    }

    const cmd = QailCmd.get("information_schema.key_column_usage")
        .select(&.{
            Expr.col("table_schema"),
            Expr.col("table_name"),
            Expr.col("column_name"),
            Expr.col("ordinal_position"),
            Expr.col("position_in_unique_constraint"),
        }).where(&.{
            .{ .condition = .{ .column = "constraint_schema", .op = .eq, .value = .{ .string = constraint_schema } } },
            .{ .condition = .{ .column = "constraint_name", .op = .eq, .value = .{ .string = constraint_name } } },
        }).orderBy(&.{
        .{ .column = "ordinal_position", .order = .asc },
    });
    return try pg.fetchAll(&cmd);
}

fn freeLiveForeignKeyColumnList(allocator: Allocator, columns: []const []const u8) void {
    for (columns) |column| allocator.free(column);
    allocator.free(columns);
}

fn freeLiveIdentifierList(allocator: Allocator, identifiers: []const []const u8) void {
    for (identifiers) |identifier| allocator.free(identifier);
    allocator.free(identifiers);
}

fn allocLiveIdentifierList(allocator: Allocator, identifiers: []const []const u8) ![]u8 {
    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    try schema_types.writeIdentifierList(out.writer(), identifiers);
    return try out.toOwnedSlice();
}

fn liveConstraintColumnList(
    allocator: Allocator,
    rows: []@import("../driver/row.zig").PgRow,
) ![]const []const u8 {
    const columns = try allocator.alloc([]const u8, rows.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |column| allocator.free(column);
        allocator.free(columns);
    }

    for (rows, 0..) |row, i| {
        const column_name = row.getByName("column_name") orelse return error.InvalidLiveConstraintMetadata;
        if (!isLiveSchemaIdentifier(column_name)) return error.UnsupportedLiveIndexIdentifier;
        columns[i] = try allocator.dupe(u8, column_name);
        initialized += 1;
    }
    return columns;
}

fn liveForeignKeyColumnList(
    allocator: Allocator,
    rows: []@import("../driver/row.zig").PgRow,
) ![]const []const u8 {
    const columns = try allocator.alloc([]const u8, rows.len);
    var initialized: usize = 0;
    errdefer {
        for (columns[0..initialized]) |column| allocator.free(column);
        allocator.free(columns);
    }

    for (rows, 0..) |row, i| {
        const column_name = row.getByName("column_name") orelse return error.InvalidLiveForeignKeyMetadata;
        if (!isLiveSchemaIdentifier(column_name)) return error.UnsupportedLiveForeignKeyIdentifier;
        columns[i] = try allocator.dupe(u8, column_name);
        initialized += 1;
    }
    return columns;
}

fn liveForeignKeyActionToken(rule: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, rule, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "NO ACTION")) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "CASCADE")) return "cascade";
    if (std.ascii.eqlIgnoreCase(trimmed, "SET NULL")) return "set_null";
    if (std.ascii.eqlIgnoreCase(trimmed, "SET DEFAULT")) return "set_default";
    if (std.ascii.eqlIgnoreCase(trimmed, "RESTRICT")) return "restrict";
    return error.UnsupportedLiveForeignKeyAction;
}

fn liveForeignKeyDeferrableToken(is_deferrable: []const u8, initially_deferred: []const u8) !?[]const u8 {
    const can_defer = try livePgBool(is_deferrable);
    const starts_deferred = try livePgBool(initially_deferred);
    if (!can_defer and starts_deferred) return error.InvalidLiveForeignKeyMetadata;
    if (starts_deferred) return "initially_deferred";
    if (can_defer) return "deferrable";
    return null;
}

fn checkConstraintAnchorColumn(
    allocator: Allocator,
    table_name: []const u8,
    raw_conkey: []const u8,
    attnum_columns: *const std.StringHashMap([]u8),
    check_clause: []const u8,
) !?[]const u8 {
    const expression_anchor = checkExpressionAnchorColumn(check_clause);
    var first_participating: ?[]const u8 = null;

    var i: usize = 0;
    while (i < raw_conkey.len) {
        while (i < raw_conkey.len and isPgArraySeparator(raw_conkey[i])) : (i += 1) {}
        if (i >= raw_conkey.len) break;

        const start = i;
        if (raw_conkey[i] == '-') i += 1;
        while (i < raw_conkey.len and std.ascii.isDigit(raw_conkey[i])) : (i += 1) {}
        if (start == i or (raw_conkey[start] == '-' and start + 1 == i)) return error.InvalidCheckConkey;

        const attnum = std.fmt.parseInt(i32, raw_conkey[start..i], 10) catch return error.InvalidCheckConkey;
        if (attnum <= 0) continue;

        const key = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ table_name, attnum });
        const column_name = attnum_columns.get(key);
        allocator.free(key);
        if (column_name) |name| {
            if (first_participating == null) first_participating = name;
            if (expression_anchor) |anchor| {
                if (std.ascii.eqlIgnoreCase(anchor, name)) return name;
            }
        }

        if (i < raw_conkey.len and !isPgArraySeparator(raw_conkey[i])) return error.InvalidCheckConkey;
    }

    return first_participating;
}

fn isPgArraySeparator(ch: u8) bool {
    return ch == '{' or ch == '}' or ch == ',' or std.ascii.isWhitespace(ch);
}

fn checkExpressionAnchorColumn(check_clause: []const u8) ?[]const u8 {
    var i: usize = 0;
    var in_single = false;

    while (i < check_clause.len) {
        const ch = check_clause[i];

        if (in_single) {
            if (ch == '\'') {
                if (i + 1 < check_clause.len and check_clause[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                in_single = false;
            }
            i += 1;
            continue;
        }

        if (ch == '\'') {
            in_single = true;
            i += 1;
            continue;
        }

        if (ch == '"') {
            const quoted_start = i + 1;
            i += 1;
            while (i < check_clause.len) : (i += 1) {
                if (check_clause[i] == '"') break;
            }
            if (i >= check_clause.len) return null;
            const quoted = check_clause[quoted_start..i];
            i += 1;
            if (quoted.len == 0 or nextNonWhitespace(check_clause, i) == '(') continue;
            return quoted;
        }

        if (!isCheckIdentifierStart(ch)) {
            i += 1;
            continue;
        }

        const start = i;
        i += 1;
        while (i < check_clause.len and isCheckIdentifierContinue(check_clause[i])) : (i += 1) {}
        const token = unqualifiedCheckIdentifier(check_clause[start..i]);

        if (isCheckKeyword(token)) continue;
        if (isCastTypeToken(check_clause, start)) continue;
        if (nextNonWhitespace(check_clause, i) == '(') continue;

        return token;
    }

    return null;
}

fn isTrivialNotNullCheck(check_clause: []const u8) bool {
    var tokens: [4][]const u8 = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < check_clause.len) {
        while (i < check_clause.len and (std.ascii.isWhitespace(check_clause[i]) or check_clause[i] == '(' or check_clause[i] == ')')) : (i += 1) {}
        if (i >= check_clause.len) break;

        const start = i;
        while (i < check_clause.len and !std.ascii.isWhitespace(check_clause[i]) and check_clause[i] != '(' and check_clause[i] != ')') : (i += 1) {}
        const token = check_clause[start..i];

        if (std.ascii.eqlIgnoreCase(token, "and") or std.ascii.eqlIgnoreCase(token, "or")) return false;
        if (count >= tokens.len) return false;
        tokens[count] = token;
        count += 1;
    }

    return count >= 3 and
        std.ascii.eqlIgnoreCase(tokens[count - 3], "is") and
        std.ascii.eqlIgnoreCase(tokens[count - 2], "not") and
        std.ascii.eqlIgnoreCase(tokens[count - 1], "null");
}

fn isCheckIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isCheckIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

fn unqualifiedCheckIdentifier(token: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, token, '.')) |dot| {
        return token[dot + 1 ..];
    }
    return token;
}

fn isCastTypeToken(expr: []const u8, token_start: usize) bool {
    var idx = token_start;
    while (idx > 0 and std.ascii.isWhitespace(expr[idx - 1])) : (idx -= 1) {}
    return idx >= 2 and expr[idx - 1] == ':' and expr[idx - 2] == ':';
}

fn nextNonWhitespace(expr: []const u8, start: usize) ?u8 {
    var idx = start;
    while (idx < expr.len) : (idx += 1) {
        if (!std.ascii.isWhitespace(expr[idx])) return expr[idx];
    }
    return null;
}

fn isCheckKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{
        "and",
        "or",
        "not",
        "null",
        "is",
        "in",
        "between",
        "like",
        "ilike",
        "similar",
        "to",
        "true",
        "false",
        "unknown",
        "case",
        "when",
        "then",
        "else",
        "end",
        "coalesce",
        "distinct",
        "from",
        "as",
        "any",
        "all",
    };

    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(token, keyword)) return true;
    }
    return false;
}

fn writeLiveColumnChecks(
    writer: anytype,
    checks: *const std.StringHashMap(std.ArrayList(LiveColumnCheck)),
    composite: []const u8,
) !void {
    if (checks.get(composite)) |column_checks| {
        for (column_checks.items) |check| {
            try writer.print(" check ({s})", .{check.expr});
            if (check.name) |name| try writer.print(" check_name {s}", .{name});
        }
    }
}

fn writeLiveColumnReference(
    writer: anytype,
    refs: *const std.StringHashMap(LiveForeignKeyReference),
    composite: []const u8,
) !void {
    if (refs.get(composite)) |reference| {
        try writer.print(" references {s}", .{reference.reference});
        try schema_types.writeReferenceOptionsQail(
            writer,
            reference.on_delete,
            reference.on_update,
            reference.deferrable,
        );
    }
}

fn writeLiveTableForeignKeys(
    writer: anytype,
    refs: *const std.StringHashMap(std.ArrayList(schema_types.MultiColumnForeignKey)),
    table_name: []const u8,
) !void {
    const foreign_keys = refs.get(table_name) orelse return;
    for (foreign_keys.items) |fk| {
        try writer.writeAll("    ");
        try schema_types.writeMultiColumnForeignKeyQail(writer, &fk);
        try writer.writeAll("\n");
    }
}

fn writeLiveTableRls(
    writer: anytype,
    table_rls: *const std.StringHashMap(LiveTableRls),
    table_name: []const u8,
) !void {
    const rls = table_rls.get(table_name) orelse return;
    if (rls.enable) try writer.writeAll("    enable_rls\n");
    if (rls.force) try writer.writeAll("    force_rls\n");
}

fn writeLiveIndexes(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    base_tables: *const std.StringHashMap(void),
    writer: anytype,
    prefix_blank: bool,
) !bool {
    var constraint_indexes = std.StringHashMap(void).init(allocator);
    defer deinitStringSet(allocator, &constraint_indexes);
    try collectConstraintIndexNames(allocator, pg, &constraint_indexes);

    const cmd = QailCmd.get("pg_indexes")
        .select(&.{
            Expr.col("indexname"),
            Expr.col("tablename"),
            Expr.col("indexdef"),
        }).where(&.{
            .{ .condition = .{ .column = "schemaname", .op = .eq, .value = .{ .string = "public" } } },
        }).orderBy(&.{
        .{ .column = "tablename", .order = .asc },
        .{ .column = "indexname", .order = .asc },
    });
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    var wrote_any = false;
    for (rows) |row| {
        const index_name = row.getByName("indexname") orelse continue;
        const table_name = row.getByName("tablename") orelse continue;
        const index_def = row.getByName("indexdef") orelse continue;
        if (!base_tables.contains(table_name)) continue;
        if (constraint_indexes.contains(index_name)) continue;

        if (!wrote_any and prefix_blank) try writer.writeByte('\n');
        wrote_any = true;
        try writeLiveIndexLine(writer, index_name, table_name, index_def);
    }
    return wrote_any;
}

fn writeLiveIndexLine(writer: anytype, index_name: []const u8, table_name: []const u8, index_def: []const u8) !void {
    if (!isLiveSchemaIdentifier(index_name) or !isLiveSchemaIdentifier(table_name)) {
        return error.UnsupportedLiveIndexIdentifier;
    }

    const open = findSqlParen(index_def, 0) orelse return error.UnsupportedLiveIndexDefinition;
    const close = findMatchingSqlParen(index_def, open) orelse return error.UnsupportedLiveIndexDefinition;
    const columns = std.mem.trim(u8, index_def[open + 1 .. close], " \t\r\n");
    if (!isSafeLiveIndexElementList(columns)) return error.UnsupportedLiveIndexDefinition;

    const method = liveIndexMethod(index_def[0..open]) orelse return error.UnsupportedLiveIndexMethod;
    const unique = isUniqueLiveIndexDefinition(index_def);
    const trailing = std.mem.trim(u8, index_def[close + 1 ..], " \t\r\n");
    const where_pos = findTopLevelSqlKeyword(trailing, "WHERE");
    const before_where = if (where_pos) |pos| std.mem.trim(u8, trailing[0..pos], " \t\r\n") else trailing;
    const where_clause = if (where_pos) |pos| std.mem.trim(u8, trailing[pos + 5 ..], " \t\r\n") else null;

    var include: ?[]const u8 = null;
    if (before_where.len > 0) {
        if (!startsWithSqlKeywordLocal(before_where, "INCLUDE")) return error.UnsupportedLiveIndexDefinition;
        const include_open = findSqlParen(before_where, 7) orelse return error.UnsupportedLiveIndexDefinition;
        const include_close = findMatchingSqlParen(before_where, include_open) orelse return error.UnsupportedLiveIndexDefinition;
        const after_include = std.mem.trim(u8, before_where[include_close + 1 ..], " \t\r\n");
        if (after_include.len != 0) return error.UnsupportedLiveIndexDefinition;
        const include_columns = std.mem.trim(u8, before_where[include_open + 1 .. include_close], " \t\r\n");
        if (!isSafeLiveIndexIdentifierList(include_columns)) return error.UnsupportedLiveIndexDefinition;
        include = include_columns;
    }

    if (where_clause) |predicate| {
        if (!isSafeLivePolicyPredicate(predicate)) return error.UnsupportedLiveIndexDefinition;
    }

    if (unique) try writer.writeAll("unique ");
    try writer.writeAll("index ");
    try writer.print("{s} on {s}", .{ index_name, table_name });
    if (!std.ascii.eqlIgnoreCase(method, "btree")) {
        try writer.print(" using {s}", .{method});
    }
    try writer.print(" ({s})", .{columns});
    if (include) |include_columns| {
        try writer.print(" include ({s})", .{include_columns});
    }
    if (where_clause) |predicate| {
        if (predicate.len > 0) try writer.print(" where {s}", .{predicate});
    }
    try writer.writeByte('\n');
}

fn writeLiveUniqueConstraintIndexes(
    writer: anytype,
    indexes: []const schema_types.IndexDef,
    prefix_blank: bool,
) !bool {
    var wrote_any = false;
    for (indexes) |index| {
        if (!index.unique) return error.UnsupportedLiveIndexDefinition;
        if (!isLiveSchemaIdentifier(index.name) or !isLiveSchemaIdentifier(index.table)) {
            return error.UnsupportedLiveIndexIdentifier;
        }
        if (!isSafeLiveIndexIdentifierList(index.columns)) return error.UnsupportedLiveIndexDefinition;

        if (!wrote_any and prefix_blank) try writer.writeByte('\n');
        wrote_any = true;
        try writer.print("unique index {s} on {s} ({s})\n", .{
            index.name,
            index.table,
            index.columns,
        });
    }
    return wrote_any;
}

fn writeLivePolicies(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    base_tables: *const std.StringHashMap(void),
    writer: anytype,
    prefix_blank: bool,
) !void {
    const policy_cmd = QailCmd.get("pg_policies")
        .select(&.{
            Expr.col("policyname"),
            Expr.col("tablename"),
            Expr.col("cmd"),
            Expr.col("permissive"),
            Expr.col("roles"),
            Expr.col("qual"),
            Expr.col("with_check"),
        }).where(&.{
            .{ .condition = .{ .column = "schemaname", .op = .eq, .value = .{ .string = "public" } } },
        }).orderBy(&.{
        .{ .column = "tablename", .order = .asc },
        .{ .column = "policyname", .order = .asc },
    });
    const rows = try pg.fetchAll(&policy_cmd);
    defer deinitFetchedRows(allocator, rows);

    var wrote_any = false;
    for (rows) |row| {
        const policy_name = row.getByName("policyname") orelse continue;
        const table_name = row.getByName("tablename") orelse continue;
        if (!base_tables.contains(table_name)) continue;
        if (!isLiveSchemaIdentifier(policy_name) or !isLiveSchemaIdentifier(table_name)) {
            return error.UnsupportedLivePolicyIdentifier;
        }

        const target = livePolicyTarget(row.getByName("cmd") orelse "") orelse return error.UnsupportedLivePolicyCommand;
        const permissive = row.getByName("permissive") orelse "PERMISSIVE";
        const is_restrictive = if (std.ascii.eqlIgnoreCase(permissive, "RESTRICTIVE"))
            true
        else if (std.ascii.eqlIgnoreCase(permissive, "PERMISSIVE"))
            false
        else
            return error.UnsupportedLivePolicyPermissiveness;
        const role = try livePolicyRole(row.getByName("roles") orelse "{public}");

        const using_expr = row.getByName("qual");
        const with_check_expr = row.getByName("with_check");
        if (using_expr) |expr| {
            if (!isSafeLivePolicyPredicate(expr)) return error.UnsupportedLivePolicyPredicate;
        }
        if (with_check_expr) |expr| {
            if (!isSafeLivePolicyPredicate(expr)) return error.UnsupportedLivePolicyPredicate;
        }

        if (!wrote_any and prefix_blank) try writer.writeByte('\n');
        wrote_any = true;

        try writer.print("policy {s} on {s}", .{ policy_name, table_name });
        if (is_restrictive) try writer.writeAll(" restrictive");
        try writer.print(" for {s}", .{target});
        if (role) |role_name| try writer.print(" to {s}", .{role_name});
        if (using_expr) |expr| {
            const trimmed = std.mem.trim(u8, expr, " \t\r\n");
            if (trimmed.len > 0) try writer.print(" using ({s})", .{trimmed});
        }
        if (with_check_expr) |expr| {
            const trimmed = std.mem.trim(u8, expr, " \t\r\n");
            if (trimmed.len > 0) try writer.print(" with_check ({s})", .{trimmed});
        }
        try writer.writeByte('\n');
    }
}

fn livePolicyTarget(cmd: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(cmd, "ALL")) return "all";
    if (std.ascii.eqlIgnoreCase(cmd, "SELECT")) return "select";
    if (std.ascii.eqlIgnoreCase(cmd, "INSERT")) return "insert";
    if (std.ascii.eqlIgnoreCase(cmd, "UPDATE")) return "update";
    if (std.ascii.eqlIgnoreCase(cmd, "DELETE")) return "delete";
    return null;
}

fn isUniqueLiveIndexDefinition(def: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, def, " \t\r\n");
    const create = tokens.next() orelse return false;
    const unique = tokens.next() orelse return false;
    const index = tokens.next() orelse return false;
    return std.ascii.eqlIgnoreCase(create, "CREATE") and
        std.ascii.eqlIgnoreCase(unique, "UNIQUE") and
        std.ascii.eqlIgnoreCase(index, "INDEX");
}

fn liveIndexMethod(before_columns: []const u8) ?[]const u8 {
    const using_pos = findTopLevelSqlKeyword(before_columns, "USING") orelse return "btree";
    const method = std.mem.trim(u8, before_columns[using_pos + 5 ..], " \t\r\n");
    if (!isAllowedLiveIndexMethod(method)) return null;
    return method;
}

fn isAllowedLiveIndexMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "btree") or
        std.ascii.eqlIgnoreCase(method, "hash") or
        std.ascii.eqlIgnoreCase(method, "gin") or
        std.ascii.eqlIgnoreCase(method, "gist") or
        std.ascii.eqlIgnoreCase(method, "brin") or
        std.ascii.eqlIgnoreCase(method, "spgist") or
        std.ascii.eqlIgnoreCase(method, "hnsw") or
        std.ascii.eqlIgnoreCase(method, "ivfflat");
}

fn isSafeLiveIndexElementList(fragment: []const u8) bool {
    var parts = std.mem.splitScalar(u8, fragment, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (!isSafeLiveIndexElement(std.mem.trim(u8, part, " \t\r\n"))) return false;
    }
    return count > 0;
}

fn isSafeLiveIndexIdentifierList(fragment: []const u8) bool {
    var parts = std.mem.splitScalar(u8, fragment, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (!isLiveQualifiedIdentifier(std.mem.trim(u8, part, " \t\r\n"))) return false;
    }
    return count > 0;
}

fn isSafeLiveIndexElement(element: []const u8) bool {
    if (element.len == 0 or !isSafeLivePolicyPredicate(element)) return false;
    if (std.mem.indexOfScalar(u8, element, '(') != null or
        std.mem.indexOfScalar(u8, element, ')') != null or
        std.mem.indexOfScalar(u8, element, '\'') != null or
        std.mem.indexOfScalar(u8, element, '"') != null)
    {
        return false;
    }

    var tokens = std.mem.tokenizeAny(u8, element, " \t\r\n");
    const column = tokens.next() orelse return false;
    if (!isLiveQualifiedIdentifier(column)) return false;
    while (tokens.next()) |token| {
        if (!isAllowedLiveIndexModifier(token)) return false;
    }
    return true;
}

fn isAllowedLiveIndexModifier(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "asc") or
        std.ascii.eqlIgnoreCase(token, "desc") or
        std.ascii.eqlIgnoreCase(token, "nulls") or
        std.ascii.eqlIgnoreCase(token, "first") or
        std.ascii.eqlIgnoreCase(token, "last") or
        isAllowedLiveIndexOpclass(token);
}

fn isAllowedLiveIndexOpclass(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '_') == null) return false;
    if (token.len == 0 or !std.ascii.isAlphabetic(token[0])) return false;
    for (token[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isLiveQualifiedIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or std.mem.startsWith(u8, identifier, ".") or std.mem.endsWith(u8, identifier, ".")) {
        return false;
    }
    var parts = std.mem.splitScalar(u8, identifier, '.');
    while (parts.next()) |part| {
        if (!isLiveSchemaIdentifier(part)) return false;
    }
    return true;
}

fn startsWithSqlKeywordLocal(value: []const u8, keyword: []const u8) bool {
    if (value.len < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(value[0..keyword.len], keyword)) return false;
    if (value.len == keyword.len) return true;
    return std.ascii.isWhitespace(value[keyword.len]) or value[keyword.len] == '(';
}

fn findSqlParen(input: []const u8, start: usize) ?usize {
    var idx = start;
    var in_single = false;
    var in_double = false;
    while (idx < input.len) : (idx += 1) {
        const ch = input[idx];
        if (in_single) {
            if (ch == '\'') {
                if (idx + 1 < input.len and input[idx + 1] == '\'') {
                    idx += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                if (idx + 1 < input.len and input[idx + 1] == '"') {
                    idx += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == '(') return idx;
    }
    return null;
}

fn findMatchingSqlParen(input: []const u8, open: usize) ?usize {
    if (open >= input.len or input[open] != '(') return null;
    var idx = open + 1;
    var depth: usize = 1;
    var in_single = false;
    var in_double = false;
    while (idx < input.len) : (idx += 1) {
        const ch = input[idx];
        if (in_single) {
            if (ch == '\'') {
                if (idx + 1 < input.len and input[idx + 1] == '\'') {
                    idx += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                if (idx + 1 < input.len and input[idx + 1] == '"') {
                    idx += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == '(') {
            depth += 1;
            continue;
        }
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return idx;
        }
    }
    return null;
}

fn findTopLevelSqlKeyword(input: []const u8, keyword: []const u8) ?usize {
    var idx: usize = 0;
    var depth: usize = 0;
    var in_single = false;
    var in_double = false;
    while (idx < input.len) : (idx += 1) {
        const ch = input[idx];
        if (in_single) {
            if (ch == '\'') {
                if (idx + 1 < input.len and input[idx + 1] == '\'') {
                    idx += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                if (idx + 1 < input.len and input[idx + 1] == '"') {
                    idx += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == '(') {
            depth += 1;
            continue;
        }
        if (ch == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth != 0) continue;
        if (idx + keyword.len > input.len) continue;
        if (!std.ascii.eqlIgnoreCase(input[idx .. idx + keyword.len], keyword)) continue;
        const before_ok = idx == 0 or !isLiveKeywordChar(input[idx - 1]);
        const after = idx + keyword.len;
        const after_ok = after == input.len or !isLiveKeywordChar(input[after]);
        if (before_ok and after_ok) return idx;
    }
    return null;
}

fn isLiveKeywordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn livePolicyRole(raw_roles: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw_roles, " \t\r\n{}");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "public")) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ',') != null) return error.UnsupportedLivePolicyRoles;
    if (!isLiveSchemaIdentifier(trimmed)) return error.UnsupportedLivePolicyRoles;
    return trimmed;
}

fn isLiveSchemaIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    if (!std.ascii.isAlphabetic(identifier[0]) and identifier[0] != '_') return false;
    for (identifier[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isSafeLivePolicyPredicate(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.indexOfScalar(u8, trimmed, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return false;
    if (std.mem.indexOf(u8, trimmed, "--") != null) return false;
    if (std.mem.indexOf(u8, trimmed, "/*") != null) return false;
    if (std.mem.indexOf(u8, trimmed, "*/") != null) return false;
    return true;
}

pub fn normalizePostgresType(
    udt_name: []const u8,
    data_type: []const u8,
    default_expr: ?[]const u8,
) NormalizedType {
    var is_array = false;
    var base_type = udt_name;

    if (std.mem.eql(u8, data_type, "ARRAY") or std.mem.startsWith(u8, udt_name, "_")) {
        is_array = true;
        if (std.mem.startsWith(u8, base_type, "_") and base_type.len > 1) {
            base_type = base_type[1..];
        }
    }

    if (!is_array) {
        if (default_expr) |d| {
            const trimmed_default = std.mem.trim(u8, d, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed_default, "nextval(")) {
                if (std.mem.eql(u8, base_type, "int4")) {
                    return .{ .typ = "serial", .is_array = false, .suppress_default = true };
                }
                if (std.mem.eql(u8, base_type, "int8")) {
                    return .{ .typ = "bigserial", .is_array = false, .suppress_default = true };
                }
            }
        }
    }

    const typ = if (std.mem.eql(u8, base_type, "int2"))
        "i16"
    else if (std.mem.eql(u8, base_type, "int4"))
        "i32"
    else if (std.mem.eql(u8, base_type, "int8"))
        "i64"
    else if (std.mem.eql(u8, base_type, "float4"))
        "f32"
    else if (std.mem.eql(u8, base_type, "float8"))
        "f64"
    else if (std.mem.eql(u8, base_type, "bool"))
        "bool"
    else if (std.mem.eql(u8, base_type, "bpchar"))
        "char"
    else if (std.mem.eql(u8, base_type, "varchar"))
        "varchar"
    else if (std.mem.eql(u8, base_type, "numeric"))
        "numeric"
    else if (std.mem.eql(u8, base_type, "timestamptz"))
        "timestamptz"
    else if (std.mem.eql(u8, base_type, "timestamp"))
        "timestamp"
    else if (std.mem.eql(u8, base_type, "timetz"))
        "timetz"
    else if (std.mem.eql(u8, base_type, "time"))
        "time"
    else if (std.mem.eql(u8, base_type, "jsonb"))
        "jsonb"
    else if (std.mem.eql(u8, base_type, "json"))
        "json"
    else if (std.mem.eql(u8, base_type, "bytea"))
        "bytea"
    else if (std.mem.eql(u8, base_type, "name"))
        "text"
    else if (base_type.len > 0)
        base_type
    else
        data_type;

    return .{
        .typ = typ,
        .is_array = is_array,
        .suppress_default = false,
    };
}

pub fn renderLiveSchemaSnapshot(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
) !RenderedSchemaSnapshot {
    var base_tables = std.StringHashMap(void).init(allocator);
    defer deinitStringSet(allocator, &base_tables);
    try collectBaseTables(allocator, pg, &base_tables);

    var primary_keys = std.StringHashMap(void).init(allocator);
    defer deinitStringSet(allocator, &primary_keys);
    try collectConstrainedColumns(allocator, pg, "PRIMARY KEY", &primary_keys);

    var unique_columns = std.StringHashMap(void).init(allocator);
    defer deinitStringSet(allocator, &unique_columns);
    var unique_constraint_indexes = std.ArrayList(schema_types.IndexDef).initCapacity(allocator, 0) catch unreachable;
    defer deinitIndexDefList(allocator, &unique_constraint_indexes);
    try collectUniqueConstraints(allocator, pg, &base_tables, &unique_columns, &unique_constraint_indexes);

    var attnum_columns = std.StringHashMap([]u8).init(allocator);
    defer deinitStringMap(allocator, &attnum_columns);
    try collectColumnAttnums(allocator, pg, &attnum_columns);

    var column_checks = std.StringHashMap(std.ArrayList(LiveColumnCheck)).init(allocator);
    defer deinitCheckMap(allocator, &column_checks);
    try collectCheckConstraints(allocator, pg, &attnum_columns, &column_checks);

    var foreign_keys = std.StringHashMap(LiveForeignKeyReference).init(allocator);
    defer deinitLiveForeignKeyReferenceMap(allocator, &foreign_keys);
    var composite_foreign_keys = std.StringHashMap(std.ArrayList(schema_types.MultiColumnForeignKey)).init(allocator);
    defer deinitLiveMultiColumnForeignKeyMap(allocator, &composite_foreign_keys);
    try collectForeignKeyReferences(allocator, pg, &foreign_keys, &composite_foreign_keys);

    var table_rls = std.StringHashMap(LiveTableRls).init(allocator);
    defer deinitTableRlsMap(allocator, &table_rls);
    try collectTableRls(allocator, pg, &base_tables, &table_rls);

    const columns_cmd = QailCmd.get("information_schema.columns")
        .select(&.{
            Expr.col("table_name"),
            Expr.col("column_name"),
            Expr.col("data_type"),
            Expr.col("udt_name"),
            Expr.col("is_nullable"),
            Expr.col("column_default"),
            Expr.col("character_maximum_length"),
            Expr.col("numeric_precision"),
            Expr.col("numeric_scale"),
        }).where(&.{
            .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
        }).orderBy(&.{
        .{ .column = "table_name", .order = .asc },
        .{ .column = "ordinal_position", .order = .asc },
    });
    const rows = try pg.fetchAll(&columns_cmd);
    defer deinitFetchedRows(allocator, rows);

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    const writer = out.writer();

    var current_table: ?[]const u8 = null;
    var table_count: usize = 0;
    var column_count: usize = 0;

    for (rows) |row| {
        const table_name = row.getByName("table_name") orelse continue;
        if (!base_tables.contains(table_name)) continue;

        if (current_table == null or !std.mem.eql(u8, current_table.?, table_name)) {
            if (current_table != null) {
                try writeLiveTableForeignKeys(writer, &composite_foreign_keys, current_table.?);
                try writeLiveTableRls(writer, &table_rls, current_table.?);
                try writer.writeAll(")\n\n");
            }
            current_table = table_name;
            table_count += 1;
            try writer.print("table {s} (\n", .{table_name});
        }

        const column_name = row.getByName("column_name") orelse continue;
        const data_type = row.getByName("data_type") orelse "";
        const udt_name = row.getByName("udt_name") orelse data_type;
        const default_expr = row.getByName("column_default");
        const normalized = normalizePostgresType(udt_name, data_type, default_expr);
        const is_nullable = row.getByName("is_nullable") orelse "YES";
        const char_max_len = row.getByName("character_maximum_length");
        const numeric_precision = row.getByName("numeric_precision");
        const numeric_scale = row.getByName("numeric_scale");

        const composite = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ table_name, column_name });
        defer allocator.free(composite);
        const is_pk = primary_keys.contains(composite);
        const is_unique = unique_columns.contains(composite);

        try writer.print("    {s} {s}", .{ column_name, normalized.typ });
        if (std.mem.eql(u8, normalized.typ, "varchar") or std.mem.eql(u8, normalized.typ, "char")) {
            if (char_max_len) |len| {
                try writer.print("({s})", .{len});
            }
        } else if (std.mem.eql(u8, normalized.typ, "numeric")) {
            if (numeric_precision) |prec| {
                if (numeric_scale) |scale| {
                    if (scale.len > 0 and !std.mem.eql(u8, scale, "0")) {
                        try writer.print("({s},{s})", .{ prec, scale });
                    } else {
                        try writer.print("({s})", .{prec});
                    }
                } else {
                    try writer.print("({s})", .{prec});
                }
            }
        }
        if (normalized.is_array) {
            try writer.writeAll("[]");
        }
        if (is_pk) {
            try writer.writeAll(" primary_key");
        } else {
            if (std.mem.eql(u8, is_nullable, "NO")) {
                try writer.writeAll(" not null");
            }
            if (is_unique) {
                try writer.writeAll(" unique");
            }
        }
        if (default_expr) |default_sql| {
            if (default_sql.len > 0 and !normalized.suppress_default) {
                try writer.print(" default {s}", .{default_sql});
            }
        }
        try writeLiveColumnReference(writer, &foreign_keys, composite);
        try writeLiveColumnChecks(writer, &column_checks, composite);
        try writer.writeAll(",\n");
        column_count += 1;
    }

    if (current_table != null) {
        try writeLiveTableForeignKeys(writer, &composite_foreign_keys, current_table.?);
        try writeLiveTableRls(writer, &table_rls, current_table.?);
        try writer.writeAll(")\n");
    }
    const wrote_indexes = try writeLiveIndexes(allocator, pg, &base_tables, writer, current_table != null);
    const wrote_unique_constraint_indexes = try writeLiveUniqueConstraintIndexes(
        writer,
        unique_constraint_indexes.items,
        current_table != null or wrote_indexes,
    );
    try writeLivePolicies(
        allocator,
        pg,
        &base_tables,
        writer,
        current_table != null or wrote_indexes or wrote_unique_constraint_indexes,
    );

    return .{
        .schema = try out.toOwnedSlice(),
        .table_count = table_count,
        .column_count = column_count,
    };
}

test "live check anchor chooses expression column from pg conkey" {
    const allocator = std.testing.allocator;

    var attnums = std.StringHashMap([]u8).init(allocator);
    defer deinitStringMap(allocator, &attnums);
    try putOwnedStringMapValue(
        allocator,
        &attnums,
        try allocator.dupe(u8, "pricing_plans.1"),
        try allocator.dupe(u8, "segment_id"),
    );
    try putOwnedStringMapValue(
        allocator,
        &attnums,
        try allocator.dupe(u8, "pricing_plans.2"),
        try allocator.dupe(u8, "virtual_segment_id"),
    );

    const anchor = try checkConstraintAnchorColumn(
        allocator,
        "pricing_plans",
        "{1,2}",
        &attnums,
        "((virtual_segment_id IS NOT NULL) AND (segment_id IS NULL))",
    );
    try std.testing.expectEqualStrings("virtual_segment_id", anchor.?);
}

test "live check helpers skip trivial not null and function names" {
    try std.testing.expect(isTrivialNotNullCheck("(status IS NOT NULL)"));
    try std.testing.expect(!isTrivialNotNullCheck("(status IS NOT NULL) AND (kind IS NOT NULL)"));

    try std.testing.expectEqualStrings(
        "name",
        checkExpressionAnchorColumn("char_length(btrim((name)::text)) > 0").?,
    );
    try std.testing.expectEqualStrings(
        "count",
        checkExpressionAnchorColumn("COALESCE(count, 1) > 0").?,
    );
}

test "live type normalization trims serial nextval defaults" {
    const serial_type = normalizePostgresType(
        "int4",
        "integer",
        "  nextval('events_id_seq'::regclass)",
    );
    try std.testing.expectEqualStrings("serial", serial_type.typ);
    try std.testing.expect(serial_type.suppress_default);

    const bigserial_type = normalizePostgresType(
        "int8",
        "bigint",
        "\n\tnextval('events_id_seq'::regclass)",
    );
    try std.testing.expectEqualStrings("bigserial", bigserial_type.typ);
    try std.testing.expect(bigserial_type.suppress_default);
}

test "live snapshot renders multiple column checks" {
    const allocator = std.testing.allocator;

    var checks = std.StringHashMap(std.ArrayList(LiveColumnCheck)).init(allocator);
    defer deinitCheckMap(allocator, &checks);
    try appendOwnedColumnCheck(
        allocator,
        &checks,
        try allocator.dupe(u8, "inventory.quantity"),
        .{
            .expr = try allocator.dupe(u8, "quantity >= 0"),
            .name = try allocator.dupe(u8, "inventory_quantity_min"),
        },
    );
    try appendOwnedColumnCheck(
        allocator,
        &checks,
        try allocator.dupe(u8, "inventory.quantity"),
        .{
            .expr = try allocator.dupe(u8, "quantity <= 100"),
            .name = try allocator.dupe(u8, "inventory_quantity_max"),
        },
    );

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    try writeLiveColumnChecks(out.writer(), &checks, "inventory.quantity");
    const rendered = try out.toOwnedSlice();
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        " check (quantity >= 0) check_name inventory_quantity_min check (quantity <= 100) check_name inventory_quantity_max",
        rendered,
    );
}

test "live snapshot renders table row level security directives" {
    const allocator = std.testing.allocator;

    var table_rls = std.StringHashMap(LiveTableRls).init(allocator);
    defer deinitTableRlsMap(allocator, &table_rls);
    const owned_name = try allocator.dupe(u8, "orders");
    const gop = try table_rls.getOrPut(owned_name);
    if (gop.found_existing) allocator.free(owned_name);
    gop.value_ptr.* = .{ .enable = true, .force = true };

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    try writeLiveTableRls(out.writer(), &table_rls, "orders");
    const rendered = try out.toOwnedSlice();
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "    enable_rls\n    force_rls\n",
        rendered,
    );
}

test "live snapshot renders supported index definitions" {
    const allocator = std.testing.allocator;
    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();

    try writeLiveIndexLine(
        out.writer(),
        "idx_users_email_active",
        "users",
        "CREATE UNIQUE INDEX idx_users_email_active ON public.users USING btree (email, created_at DESC NULLS LAST) INCLUDE (id) WHERE deleted_at IS NULL",
    );
    const rendered = try out.toOwnedSlice();
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "unique index idx_users_email_active on users (email, created_at DESC NULLS LAST) include (id) where deleted_at IS NULL\n",
        rendered,
    );
}

test "live snapshot renders multi-column unique constraints as indexes" {
    const allocator = std.testing.allocator;
    var indexes = std.ArrayList(schema_types.IndexDef).initCapacity(allocator, 0) catch unreachable;
    defer deinitIndexDefList(allocator, &indexes);

    {
        const name = try allocator.dupe(u8, "schedules_route_schedule_unique");
        errdefer allocator.free(name);
        const table = try allocator.dupe(u8, "schedules");
        errdefer allocator.free(table);
        const columns = try allocator.dupe(u8, "route_id, schedule_id");
        errdefer allocator.free(columns);
        try indexes.append(allocator, .{
            .name = name,
            .table = table,
            .columns = columns,
            .unique = true,
        });
    }

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    const wrote = try writeLiveUniqueConstraintIndexes(out.writer(), indexes.items, true);
    try std.testing.expect(wrote);
    const rendered = try out.toOwnedSlice();
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "\nunique index schedules_route_schedule_unique on schedules (route_id, schedule_id)\n",
        rendered,
    );
}

test "live snapshot rejects unsupported expression indexes" {
    var out = io_compat.AllocatingWriter.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(
        error.UnsupportedLiveIndexDefinition,
        writeLiveIndexLine(
            out.writer(),
            "idx_users_lower_email",
            "users",
            "CREATE INDEX idx_users_lower_email ON public.users USING btree (lower(email))",
        ),
    );
}

test "live postgres boolean parser accepts catalog boolean encodings" {
    try std.testing.expect(try livePgBool("t"));
    try std.testing.expect(try livePgBool("true"));
    try std.testing.expect(try livePgBool("YES"));
    try std.testing.expect(!try livePgBool("f"));
    try std.testing.expect(!try livePgBool("false"));
    try std.testing.expect(!try livePgBool("NO"));
    try std.testing.expectError(error.InvalidLiveBoolean, livePgBool("maybe"));
}

test "live foreign key helpers render references with actions" {
    try std.testing.expect((try liveForeignKeyActionToken("NO ACTION")) == null);
    try std.testing.expectEqualStrings("cascade", (try liveForeignKeyActionToken("CASCADE")).?);
    try std.testing.expectEqualStrings("set_null", (try liveForeignKeyActionToken("SET NULL")).?);
    try std.testing.expectEqualStrings("set_default", (try liveForeignKeyActionToken("SET DEFAULT")).?);
    try std.testing.expectEqualStrings("restrict", (try liveForeignKeyActionToken("RESTRICT")).?);
    try std.testing.expectError(error.UnsupportedLiveForeignKeyAction, liveForeignKeyActionToken("DO NOTHING"));

    try std.testing.expect((try liveForeignKeyDeferrableToken("NO", "NO")) == null);
    try std.testing.expectEqualStrings("deferrable", (try liveForeignKeyDeferrableToken("YES", "NO")).?);
    try std.testing.expectEqualStrings("initially_deferred", (try liveForeignKeyDeferrableToken("YES", "YES")).?);
    try std.testing.expectError(error.InvalidLiveForeignKeyMetadata, liveForeignKeyDeferrableToken("NO", "YES"));

    const allocator = std.testing.allocator;
    var refs = std.StringHashMap(LiveForeignKeyReference).init(allocator);
    defer deinitLiveForeignKeyReferenceMap(allocator, &refs);
    try putOwnedLiveForeignKeyReference(
        allocator,
        &refs,
        try allocator.dupe(u8, "orders.user_id"),
        .{
            .reference = try allocator.dupe(u8, "users(id)"),
            .on_delete = try allocator.dupe(u8, "cascade"),
            .on_update = try allocator.dupe(u8, "restrict"),
            .deferrable = try allocator.dupe(u8, "initially_deferred"),
        },
    );

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    try writeLiveColumnReference(out.writer(), &refs, "orders.user_id");
    const rendered = try out.toOwnedSlice();
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(" references users(id) on_delete cascade on_update restrict initially_deferred", rendered);
}

test "live foreign key helpers render composite references" {
    const allocator = std.testing.allocator;

    var refs = std.StringHashMap(std.ArrayList(schema_types.MultiColumnForeignKey)).init(allocator);
    defer deinitLiveMultiColumnForeignKeyMap(allocator, &refs);

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "route_id");
    columns[1] = try allocator.dupe(u8, "schedule_id");
    const ref_columns = try allocator.alloc([]const u8, 2);
    ref_columns[0] = try allocator.dupe(u8, "route_id");
    ref_columns[1] = try allocator.dupe(u8, "schedule_id");

    try appendOwnedLiveMultiColumnForeignKey(
        allocator,
        &refs,
        try allocator.dupe(u8, "trips"),
        .{
            .name = try allocator.dupe(u8, "fk_trips_schedule"),
            .columns = columns,
            .ref_table = try allocator.dupe(u8, "schedules"),
            .ref_columns = ref_columns,
            .on_delete = try allocator.dupe(u8, "cascade"),
            .on_update = try allocator.dupe(u8, "restrict"),
            .deferrable = try allocator.dupe(u8, "deferrable"),
        },
    );

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    try writeLiveTableForeignKeys(out.writer(), &refs, "trips");
    const rendered = try out.toOwnedSlice();
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "    foreign_key (route_id, schedule_id) references schedules(route_id, schedule_id) constraint fk_trips_schedule on_delete cascade on_update restrict deferrable\n",
        rendered,
    );
}

test "live policy helpers map targets roles and predicate safety" {
    try std.testing.expectEqualStrings("select", livePolicyTarget("SELECT").?);
    try std.testing.expect(livePolicyTarget("MERGE") == null);

    try std.testing.expect((try livePolicyRole("{public}")) == null);
    try std.testing.expectEqualStrings("app_user", (try livePolicyRole("{app_user}")).?);
    try std.testing.expectError(error.UnsupportedLivePolicyRoles, livePolicyRole("{app_user,app_admin}"));

    try std.testing.expect(isLiveSchemaIdentifier("orders_policy"));
    try std.testing.expect(!isLiveSchemaIdentifier("orders-policy"));
    try std.testing.expect(isSafeLivePolicyPredicate("tenant_id = current_setting('app.tenant_id')::uuid"));
    try std.testing.expect(!isSafeLivePolicyPredicate("tenant_id = 1; drop table orders"));
}

pub fn pullSchema(allocator: Allocator, url: []const u8) !void {
    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();

    const snapshot = try renderLiveSchemaSnapshot(allocator, &pg);
    defer allocator.free(snapshot.schema);

    try io_compat.writeAllStdout(snapshot.schema);
    print("✓ Schema pulled: {d} table(s), {d} column(s)\n", .{ snapshot.table_count, snapshot.column_count });
}

pub fn checkSchema(allocator: Allocator, schema_path: []const u8) !void {
    const parser = @import("../parser/mod.zig");

    const schema_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(schema_content);

    var schema = parser.Schema.parse(allocator, schema_content) catch |err| {
        print("❌ Schema invalid: {s}\n", .{schema_path});
        print("  Parse error: {}\n", .{err});
        return err;
    };
    defer schema.deinit();

    var total_columns: usize = 0;
    for (schema.tables.items) |table| total_columns += table.columns.items.len;

    print("✅ Schema valid: {s}\n", .{schema_path});
    print("  Tables: {d}\n", .{schema.tables.items.len});
    print("  Columns: {d}\n", .{total_columns});
    print("  Policies: {d}\n", .{schema.policies.items.len});
    print("  Grants: {d}\n", .{schema.grants.items.len});
}

const DiffFormat = enum { sql, json, pretty };

fn parseDiffFormat(name: []const u8) DiffFormat {
    if (std.mem.eql(u8, name, "json")) return .json;
    if (std.mem.eql(u8, name, "pretty")) return .pretty;
    return .sql;
}

pub fn diffSchemas(allocator: Allocator, old_path: []const u8, new_path: []const u8, format_name: []const u8) !void {
    const parser = @import("../parser/mod.zig");

    const old_content = readFileAlloc(allocator, old_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading old schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(old_content);

    const new_content = readFileAlloc(allocator, new_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading new schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(new_content);

    var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
        print("Error parsing old schema: {}\n", .{err});
        return err;
    };
    defer old_schema.deinit();

    var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
        print("Error parsing new schema: {}\n", .{err});
        return err;
    };
    defer new_schema.deinit();

    var cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
        print("Error computing diff: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &cmds);

    const format = parseDiffFormat(format_name);
    if (cmds.items.len == 0) {
        switch (format) {
            .json => print("{{\"operations\":0,\"diff\":[]}}\n", .{}),
            else => print("✅ No schema differences\n", .{}),
        }
        return;
    }

    switch (format) {
        .sql => {
            const sql = parser.toSqlStatements(allocator, &cmds) catch |err| {
                print("Error generating SQL: {}\n", .{err});
                return err;
            };
            defer allocator.free(sql);
            print("{s}", .{sql});
        },
        .pretty => {
            print("📋 Schema Diff: {s} → {s}\n", .{ old_path, new_path });
            print("  Operations: {d}\n\n", .{cmds.items.len});
            for (cmds.items, 0..) |*cmd, i| {
                const sql = cmd.toSql(allocator) catch |err| {
                    print("{d}. {s} {s} (sql error: {})\n", .{ i + 1, @tagName(cmd.action), cmd.table, err });
                    continue;
                };
                defer allocator.free(sql);
                print("{d}. {s} {s}\n   {s};\n", .{ i + 1, @tagName(cmd.action), cmd.table, sql });
            }
        },
        .json => {
            print("{{\"operations\":{d},\"diff\":[", .{cmds.items.len});
            for (cmds.items, 0..) |*cmd, i| {
                if (i > 0) print(",", .{});
                const sql_opt = cmd.toSql(allocator) catch null;
                if (sql_opt) |sql| {
                    defer allocator.free(sql);
                    print("{{\"action\":\"{s}\",\"table\":\"{s}\",\"sql\":", .{ @tagName(cmd.action), cmd.table });
                    var writer = io_compat.AllocatingWriter.init(allocator);
                    defer writer.deinit();
                    try std.json.Stringify.value(sql, .{}, writer.writer());
                    const quoted = try writer.toOwnedSlice();
                    defer allocator.free(quoted);
                    print("{s}", .{quoted});
                    print("}}", .{});
                } else {
                    print("{{\"action\":\"{s}\",\"table\":\"{s}\"}}", .{ @tagName(cmd.action), cmd.table });
                }
            }
            print("]}}\n", .{});
        },
    }
}

pub fn lintSchema(allocator: Allocator, schema_path: []const u8, strict: bool) !void {
    const parser = @import("../parser/mod.zig");

    const schema_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(schema_content);

    var schema = parser.Schema.parse(allocator, schema_content) catch |err| {
        print("❌ Lint failed: invalid schema ({})\n", .{err});
        return err;
    };
    defer schema.deinit();

    var warnings: usize = 0;
    var errors: usize = 0;

    print("🔍 Linting: {s}\n", .{schema_path});

    if (schema.tables.items.len == 0) {
        warnings += 1;
        print("  [warn] schema has no tables\n", .{});
    }

    for (schema.tables.items) |table| {
        var has_primary_key = false;
        for (table.columns.items) |col| {
            if (col.primary_key) {
                has_primary_key = true;
                break;
            }
        }

        if (!has_primary_key) {
            warnings += 1;
            print("  [warn] table '{s}' has no primary key\n", .{table.name});
        }

        if (table.columns.items.len == 0) {
            errors += 1;
            print("  [error] table '{s}' has no columns\n", .{table.name});
        }
    }

    if (errors == 0 and warnings == 0) {
        print("✅ No issues found\n", .{});
        return;
    }

    print("\nSummary: {d} error(s), {d} warning(s)\n", .{ errors, warnings });

    if (errors > 0) return error.LintFailed;
    if (strict and warnings > 0) return error.LintFailed;
}

pub fn watchSchema(allocator: Allocator, schema_path: []const u8, url: ?[]const u8, auto_apply: bool) !void {
    const parser = @import("../parser/mod.zig");

    if (auto_apply and url == null) {
        print("Error: --auto-apply requires --url <postgres://...>\n", .{});
        return error.MissingArgument;
    }

    const initial_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(initial_content);

    var last_schema = parser.Schema.parse(allocator, initial_content) catch |err| {
        print("Error parsing initial schema: {}\n", .{err});
        return err;
    };
    defer last_schema.deinit();

    const io_iface = io_compat.runtimeIo();
    var last_stat = std.Io.Dir.cwd().statFile(io_iface, schema_path, .{}) catch |err| {
        print("Error stat'ing schema: {}\n", .{err});
        return err;
    };

    var pg: ?@import("../driver/driver.zig").PgDriver = null;
    defer if (pg) |*driver| driver.deinit();
    if (auto_apply) {
        const watch_url = url.?;
        var connected = connectPgUrl(allocator, watch_url) catch |err| {
            print("Error connecting for auto-apply: {}\n", .{err});
            return err;
        };
        errdefer connected.deinit();
        pg = connected;
    }

    print("👁️ Watching: {s}\n", .{schema_path});
    if (url) |watch_url| {
        print("Database: {s}\n", .{watch_url});
    }
    if (auto_apply) {
        print("Auto-apply: enabled\n", .{});
    }
    print("Press Ctrl+C to stop\n", .{});

    while (true) {
        std.Io.sleep(io_iface, std.Io.Duration.fromMilliseconds(500), .awake) catch {};

        const current_stat = std.Io.Dir.cwd().statFile(io_iface, schema_path, .{}) catch |err| {
            print("Watch error (stat): {}\n", .{err});
            continue;
        };
        if (current_stat.mtime.nanoseconds == last_stat.mtime.nanoseconds and current_stat.size == last_stat.size) {
            continue;
        }
        last_stat = current_stat;

        print("\n🔄 Schema changed, reloading...\n", .{});
        const new_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
            print("Error reading updated schema: {}\n", .{err});
            continue;
        };
        defer allocator.free(new_content);

        var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
            print("Error parsing updated schema: {}\n", .{err});
            continue;
        };

        var cmds = parser.diffSchemas(allocator, &last_schema, &new_schema) catch |err| {
            print("Error computing diff: {}\n", .{err});
            new_schema.deinit();
            continue;
        };
        defer deinitMigrationCmds(allocator, &cmds);

        if (cmds.items.len == 0) {
            print("No material schema changes detected\n", .{});
            last_schema.deinit();
            last_schema = new_schema;
            continue;
        }

        print("Detected {d} migration command(s)\n", .{cmds.items.len});
        for (cmds.items, 0..) |migration_cmd, i| {
            const stmt_sql = migration_cmd.toSql(allocator) catch |err| {
                print("  [{d}] <render failed: {}>\n", .{ i + 1, err });
                continue;
            };
            defer allocator.free(stmt_sql);
            print("  [{d}] {s};\n", .{ i + 1, stmt_sql });
        }

        var advance_baseline = true;
        if (auto_apply) {
            print("Applying migration commands...\n", .{});
            if (pg) |*driver| {
                driver.begin() catch |err| {
                    print("Error starting transaction: {}\n", .{err});
                    advance_baseline = false;
                };

                if (advance_baseline) {
                    executeMigrationCmds(allocator, driver, cmds.items, "watch") catch |err| {
                        print("Error applying watch commands: {}\n", .{err});
                        driver.rollback() catch {};
                        advance_baseline = false;
                    };
                }

                if (advance_baseline) {
                    driver.commit() catch |err| {
                        print("Error committing watch transaction: {}\n", .{err});
                        driver.rollback() catch {};
                        advance_baseline = false;
                    };
                }
            }
        }

        if (advance_baseline) {
            print("✅ Watch baseline updated\n", .{});
            last_schema.deinit();
            last_schema = new_schema;
        } else {
            print("⚠️ Keeping previous baseline for next retry\n", .{});
            new_schema.deinit();
        }
    }
}
