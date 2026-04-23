const std = @import("std");
const Allocator = std.mem.Allocator;
const QailCmd = @import("../ast/cmd.zig").QailCmd;
const Expr = @import("../ast/expr.zig").Expr;
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

fn connectPgUrl(
    allocator: Allocator,
    url: []const u8,
) !@import("../driver/driver.zig").PgDriver {
    const driver_mod = @import("../driver/mod.zig");
    return try driver_mod.driver.PgDriver.connectUrl(allocator, url);
}

fn freeGeneratedCmdColumns(allocator: Allocator, cmd: *const QailCmd) void {
    if (cmd.columns.len == 0) return;
    const cols_ptr: [*]const Expr = cmd.columns.ptr;
    const cols_many: [*]Expr = @constCast(cols_ptr);
    allocator.free(cols_many[0..cmd.columns.len]);
}

fn executeMigrationCmds(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    cmds: []const @import("../parser/mod.zig").MigrationCmd,
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
        defer freeGeneratedCmdColumns(allocator, &qail_cmd);

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
            if (std.mem.startsWith(u8, d, "nextval(")) {
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
    try collectConstrainedColumns(allocator, pg, "UNIQUE", &unique_columns);

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
        try writer.writeAll(",\n");
        column_count += 1;
    }

    if (current_table != null) {
        try writer.writeAll(")\n");
    }

    return .{
        .schema = try out.toOwnedSlice(),
        .table_count = table_count,
        .column_count = column_count,
    };
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
