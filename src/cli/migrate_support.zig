const std = @import("std");
const Allocator = std.mem.Allocator;
const QailCmd = @import("../ast/cmd.zig").QailCmd;
const Expr = @import("../ast/expr.zig").Expr;

pub fn make(comptime Cli: type) type {
    return struct {
        const print = std.debug.print;

        pub const ShadowStateReceipt = struct {
            shadow_name: []u8,
            primary_url: []u8,
            schema_diff: []u8,

            pub fn deinit(self: *ShadowStateReceipt, allocator: Allocator) void {
                allocator.free(self.shadow_name);
                allocator.free(self.primary_url);
                allocator.free(self.schema_diff);
            }
        };

        pub fn deinitMigrationCmds(
            allocator: Allocator,
            cmds: *std.ArrayList(@import("../parser/mod.zig").MigrationCmd),
        ) void {
            for (cmds.items) |cmd| {
                if (cmd.table_columns.len > 0) allocator.free(cmd.table_columns);
            }
            cmds.deinit(allocator);
        }

        fn putOwnedStringSetKey(
            allocator: Allocator,
            set: *std.StringHashMap(void),
            key: []u8,
        ) !void {
            const gop = try set.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(key);
                return;
            }
            gop.value_ptr.* = {};
        }

        pub fn putStringSetKey(
            allocator: Allocator,
            set: *std.StringHashMap(void),
            key: []const u8,
        ) !void {
            const owned = try allocator.dupe(u8, key);
            try putOwnedStringSetKey(allocator, set, owned);
        }

        pub fn deinitStringSet(allocator: Allocator, set: *std.StringHashMap(void)) void {
            var it = set.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            set.deinit();
        }

        fn freeGeneratedCmdColumns(allocator: Allocator, cmd: *const QailCmd) void {
            if (cmd.columns.len == 0) return;
            const cols_ptr: [*]const Expr = cmd.columns.ptr;
            const cols_many: [*]Expr = @constCast(cols_ptr);
            allocator.free(cols_many[0..cmd.columns.len]);
        }

        pub fn executeMigrationCmds(
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

        pub fn deriveShadowDatabaseName(
            allocator: Allocator,
            primary_url: []const u8,
        ) ![]u8 {
            const driver_mod = @import("../driver/mod.zig");
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            const parsed = try driver_mod.connect_url.parseConnectionUrl(arena_state.allocator(), primary_url);
            return try std.fmt.allocPrint(allocator, "{s}_shadow", .{parsed.database});
        }

        pub fn rewriteDatabaseInUrl(
            allocator: Allocator,
            url: []const u8,
            database_name: []const u8,
        ) ![]u8 {
            const trimmed = std.mem.trim(u8, url, " \t\r\n");
            const query_idx = std.mem.indexOfScalar(u8, trimmed, '?');
            const authority_and_path = if (query_idx) |idx| trimmed[0..idx] else trimmed;
            const query = if (query_idx) |idx| trimmed[idx + 1 ..] else "";

            const at_idx = std.mem.lastIndexOfScalar(u8, authority_and_path, '@') orelse return error.InvalidDatabaseUrlMissingUser;
            const slash_rel = std.mem.indexOfScalar(u8, authority_and_path[at_idx + 1 ..], '/') orelse return error.InvalidDatabaseUrlMissingDatabase;
            const slash_idx = at_idx + 1 + slash_rel;
            const prefix = authority_and_path[0 .. slash_idx + 1];

            if (query.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s}{s}?{s}", .{ prefix, database_name, query });
            }
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, database_name });
        }

        pub fn slugifyMigrationName(allocator: Allocator, name: []const u8) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);

            for (name) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_') {
                    try out.append(allocator, std.ascii.toLower(c));
                } else if (c == ' ' or c == '-' or c == '.') {
                    if (out.items.len == 0 or out.items[out.items.len - 1] != '_') {
                        try out.append(allocator, '_');
                    }
                }
            }

            while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
                _ = out.pop();
            }

            if (out.items.len == 0) {
                try out.appendSlice(allocator, "migration");
            }

            return try out.toOwnedSlice(allocator);
        }

        fn shadowStateCreateCmd() QailCmd {
            const columns = [_]Expr{
                .{ .column_def = .{ .name = "id", .data_type = "serial", .is_primary_key = true } },
                .{ .column_def = .{ .name = "shadow_name", .data_type = "text", .is_not_null = true } },
                .{ .column_def = .{ .name = "primary_url", .data_type = "text", .is_not_null = true } },
                .{ .column_def = .{ .name = "schema_diff", .data_type = "text", .is_not_null = true } },
                .{ .column_def = .{ .name = "status", .data_type = "text", .is_not_null = true, .default_value = "'pending'" } },
                .{ .column_def = .{ .name = "created_at", .data_type = "timestamptz", .default_value = "NOW()" } },
            };

            return .{
                .kind = .make,
                .table = "_qail_shadow_state",
                .columns = &columns,
            };
        }

        pub fn ensureShadowStateTable(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
        ) !void {
            const exists_cmd = QailCmd.get("information_schema.tables")
                .select(&.{
                    Expr.col("table_name"),
                }).where(&.{
                    .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
                    .{ .condition = .{ .column = "table_name", .op = .eq, .value = .{ .string = "_qail_shadow_state" } } },
                }).limit(1);
            const exists_rows = try pg.fetchAll(&exists_cmd);
            defer Cli.deinitFetchedRows(allocator, exists_rows);

            if (exists_rows.len == 0) {
                const create_cmd = shadowStateCreateCmd();
                _ = try pg.execute(&create_cmd);
            }
        }

        pub fn saveShadowState(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
            primary_url: []const u8,
            schema_diff: []const u8,
            shadow_name: []const u8,
        ) !void {
            const Value = @import("../ast/cmd.zig").Value;

            try ensureShadowStateTable(allocator, pg);

            const clear_pending = QailCmd.del("_qail_shadow_state").where(&.{
                .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "pending" } } },
            });
            _ = pg.execute(&clear_pending) catch {};
            const clear_verified = QailCmd.del("_qail_shadow_state").where(&.{
                .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "verified" } } },
            });
            _ = pg.execute(&clear_verified) catch {};

            const insert_cmd = QailCmd{
                .kind = .add,
                .table = "_qail_shadow_state",
                .columns = &[_]Expr{
                    Expr.col("shadow_name"),
                    Expr.col("primary_url"),
                    Expr.col("schema_diff"),
                    Expr.col("status"),
                },
                .insert_values = &[_]Value{
                    Value.fromString(shadow_name),
                    Value.fromString(primary_url),
                    Value.fromString(schema_diff),
                    Value.fromString("pending"),
                },
            };
            _ = try pg.execute(&insert_cmd);
        }

        fn fetchShadowStateByStatus(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
            status: []const u8,
        ) !?ShadowStateReceipt {
            const cmd = QailCmd.get("_qail_shadow_state")
                .select(&.{
                    Expr.col("shadow_name"),
                    Expr.col("primary_url"),
                    Expr.col("schema_diff"),
                }).where(&.{
                    .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = status } } },
                }).limit(1);
            const rows = try pg.fetchAll(&cmd);
            defer Cli.deinitFetchedRows(allocator, rows);

            if (rows.len == 0) return null;

            const shadow_name = rows[0].getByName("shadow_name") orelse return error.InvalidShadowStateRow;
            const primary_url = rows[0].getByName("primary_url") orelse return error.InvalidShadowStateRow;
            const schema_diff = rows[0].getByName("schema_diff") orelse return error.InvalidShadowStateRow;

            var receipt = ShadowStateReceipt{
                .shadow_name = try allocator.dupe(u8, shadow_name),
                .primary_url = try allocator.dupe(u8, primary_url),
                .schema_diff = try allocator.dupe(u8, schema_diff),
            };
            errdefer receipt.deinit(allocator);

            return receipt;
        }

        pub fn loadActiveShadowState(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
        ) !?ShadowStateReceipt {
            try ensureShadowStateTable(allocator, pg);
            if (try fetchShadowStateByStatus(allocator, pg, "pending")) |state| return state;
            if (try fetchShadowStateByStatus(allocator, pg, "verified")) |state| return state;
            return null;
        }

        pub fn updateShadowStateStatus(
            pg: *@import("../driver/driver.zig").PgDriver,
            status: []const u8,
        ) !void {
            const update_pending = QailCmd.set("_qail_shadow_state")
                .values(&.{
                    .{ .column = "status", .value = .{ .string = status } },
                }).where(&.{
                .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "pending" } } },
            });
            _ = try pg.execute(&update_pending);

            const update_verified = QailCmd.set("_qail_shadow_state")
                .values(&.{
                    .{ .column = "status", .value = .{ .string = status } },
                }).where(&.{
                .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "verified" } } },
            });
            _ = pg.execute(&update_verified) catch {};
        }
    };
}
