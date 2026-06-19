const std = @import("std");

const MigrationFileNameParts = struct {
    stem: []const u8,
    name: []const u8,
};

fn isMigrationFileStemByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn parseMigrationUpFileName(file_name: []const u8) !MigrationFileNameParts {
    if (!std.mem.endsWith(u8, file_name, ".up.qail")) return error.NotUpMigrationFile;

    const stem = file_name[0 .. file_name.len - ".up.qail".len];
    return parseMigrationStem(stem);
}

fn parseMigrationStem(stem: []const u8) !MigrationFileNameParts {
    if (stem.len == 0) return error.InvalidMigrationFileName;
    if (!std.ascii.isAlphanumeric(stem[0])) return error.InvalidMigrationFileName;

    for (stem) |c| {
        if (!isMigrationFileStemByte(c)) return error.InvalidMigrationFileName;
    }

    const split_idx = std.mem.indexOfScalar(u8, stem, '_');
    const name = if (split_idx) |idx| blk: {
        if (idx == 0 or idx + 1 >= stem.len) return error.InvalidMigrationFileName;
        break :blk stem[idx + 1 ..];
    } else stem;

    if (name.len == 0) return error.InvalidMigrationFileName;
    if (!std.ascii.isAlphanumeric(name[0])) return error.InvalidMigrationFileName;
    return .{ .stem = stem, .name = name };
}

fn pathContainsMigrationPhaseToken(path: []const u8, token: []const u8) bool {
    var token_start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and std.ascii.isAlphanumeric(path[i])) continue;

        if (i > token_start and std.mem.eql(u8, path[token_start..i], token)) {
            return true;
        }
        token_start = i + 1;
    }
    return false;
}

pub fn make(comptime Cli: type) type {
    const Allocator = std.mem.Allocator;
    const QailCmd = @import("../ast/cmd.zig").QailCmd;
    const Expr = @import("../ast/expr.zig").Expr;
    const MigrationCmd = @import("../parser/mod.zig").MigrationCmd;
    const io_compat = @import("../runtime/io.zig");
    const data_safety = @import("../data_safety.zig");
    const schema_cli = @import("schema.zig");
    const commands = @import("commands.zig").make(Cli);
    const migrate_support = @import("migrate_support.zig").make(Cli);
    const print = std.debug.print;
    const MigrationDirection = Cli.MigrationDirection;
    const ApplyPhase = Cli.ApplyPhase;
    const MigrateAction = Cli.MigrateAction;

    return struct {
        fn runMigrateStatus(allocator: Allocator, url: []const u8) !void {
            const parser = @import("../parser/mod.zig");

            print("📊 Migration Status\n\n", .{});

            var pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return err;
            };
            defer pg.deinit();

            const mig_cmd = parser.getMigrationTableCmd();
            _ = pg.execute(&mig_cmd) catch |err| {
                print("Error creating migration table: {}\n", .{err});
                return err;
            };

            const status_cmd = QailCmd.get("_qail_migrations")
                .select(&.{
                    Expr.col("version"),
                    Expr.col("name"),
                    Expr.col("applied_at"),
                    Expr.col("checksum"),
                }).orderBy(&.{
                .{ .column = "applied_at", .order = .asc },
            });
            const status_rows = pg.fetchAll(&status_cmd) catch |err| {
                print("Error querying migrations: {}\n", .{err});
                return err;
            };
            defer Cli.deinitFetchedRows(allocator, status_rows);
            const row_count = status_rows.len;

            print("  URL: {s}\n", .{url});
            print("  Migration table: _qail_migrations\n\n", .{});

            if (row_count > 0) {
                print("  ✓ Found {} migration(s) applied\n\n", .{row_count});
                print("  Version           Name              Applied At                Checksum\n", .{});
                print("  ---------------------------------------------------------------------------\n", .{});
                for (status_rows) |row| {
                    const version = row.getByName("version") orelse "-";
                    const name = row.getByName("name") orelse "-";
                    const applied_at = row.getByName("applied_at") orelse "-";
                    const checksum = row.getByName("checksum") orelse "-";
                    print("  {s:16}  {s:16}  {s:24}  {s}\n", .{ version, name, applied_at, checksum });
                }
                print("\n", .{});
                print("  Run 'qail migrate up' to apply new migrations\n", .{});
            } else {
                print("  No migrations applied yet\n\n", .{});
                print("  Run 'qail migrate up old.qail:new.qail <URL>' to apply\n", .{});
            }
        }

        fn writeShadowLiveBaseSnapshot(allocator: Allocator, schema_content: []const u8) ![]u8 {
            const io_iface = io_compat.runtimeIo();
            try std.Io.Dir.cwd().createDirPath(io_iface, "migrations");
            const ts_ms = std.Io.Clock.now(.real, io_iface).toMilliseconds();
            const path = try std.fmt.allocPrint(allocator, "migrations/.shadow_live_{d}.qail", .{ts_ms});
            errdefer allocator.free(path);
            try std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = path,
                .data = schema_content,
                .flags = .{
                    .truncate = true,
                },
            });
            return path;
        }

        fn runMigrateShadow(allocator: Allocator, schema_diff: []const u8, url: []const u8, live: bool) !void {
            const parser = @import("../parser/mod.zig");
            const parsed_diff = parseSchemaDiffPath(schema_diff);

            var old_schema: parser.Schema = undefined;
            var old_loaded = false;
            defer if (old_loaded) old_schema.deinit();

            var new_schema: parser.Schema = undefined;
            var new_loaded = false;
            defer if (new_loaded) new_schema.deinit();

            var old_label: []const u8 = undefined;
            var new_label: []const u8 = undefined;

            var effective_schema_diff: ?[]u8 = null;
            defer if (effective_schema_diff) |owned| allocator.free(owned);

            if (live) {
                var target_schema_path = schema_diff;
                if (parsed_diff.old != null and parsed_diff.new != null) {
                    target_schema_path = parsed_diff.new.?;
                    print("  Note: --live ignores provided old schema path and uses live database snapshot.\n", .{});
                }

                const new_content = readFileAlloc(allocator, target_schema_path, 8 * 1024 * 1024) catch |err| {
                    print("Error reading target schema: {}\n", .{err});
                    return err;
                };
                defer allocator.free(new_content);

                new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                    print("Error parsing target schema: {}\n", .{err});
                    return err;
                };
                new_loaded = true;

                var primary_live_pg = Cli.connectPgUrl(allocator, url) catch |err| {
                    print("Error connecting to primary database for live shadow baseline: {}\n", .{err});
                    return err;
                };
                defer primary_live_pg.deinit();

                const live_snapshot = schema_cli.renderLiveSchemaSnapshot(allocator, &primary_live_pg) catch |err| {
                    print("Error introspecting live schema: {}\n", .{err});
                    return err;
                };
                defer allocator.free(live_snapshot.schema);

                old_schema = parser.Schema.parse(allocator, live_snapshot.schema) catch |err| {
                    print("Error parsing live schema snapshot: {}\n", .{err});
                    return err;
                };
                old_loaded = true;

                const live_snapshot_path = writeShadowLiveBaseSnapshot(allocator, live_snapshot.schema) catch |err| {
                    print("Error saving live schema snapshot for promote parity: {}\n", .{err});
                    return err;
                };
                defer allocator.free(live_snapshot_path);

                effective_schema_diff = try std.fmt.allocPrint(allocator, "{s}:{s}", .{
                    live_snapshot_path,
                    target_schema_path,
                });

                old_label = "live://primary";
                new_label = target_schema_path;
                print("  Live baseline snapshot: {s}\n", .{live_snapshot_path});
            } else {
                if (parsed_diff.old == null or parsed_diff.new == null) {
                    print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                    return;
                }

                old_label = parsed_diff.old.?;
                new_label = parsed_diff.new.?;

                const old_content = readFileAlloc(allocator, old_label, 8 * 1024 * 1024) catch |err| {
                    print("Error reading old schema: {}\n", .{err});
                    return err;
                };
                defer allocator.free(old_content);

                const new_content = readFileAlloc(allocator, new_label, 8 * 1024 * 1024) catch |err| {
                    print("Error reading new schema: {}\n", .{err});
                    return err;
                };
                defer allocator.free(new_content);

                old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
                    print("Error parsing old schema: {}\n", .{err});
                    return err;
                };
                old_loaded = true;

                new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                    print("Error parsing new schema: {}\n", .{err});
                    return err;
                };
                new_loaded = true;
            }

            print("🌑 Shadow Migration\n\n", .{});
            if (live) {
                print("  Mode: live baseline from primary\n", .{});
            }
            print("  Diff: {s} → {s}\n", .{ old_label, new_label });
            print("  Primary URL: {s}\n\n", .{url});

            const shadow_name = try migrate_support.deriveShadowDatabaseName(allocator, url);
            defer allocator.free(shadow_name);

            const admin_url = try migrate_support.rewriteDatabaseInUrl(allocator, url, "postgres");
            defer allocator.free(admin_url);
            var admin_pg = Cli.connectPgUrl(allocator, admin_url) catch |err| {
                print("Error connecting to admin database: {}\n", .{err});
                return err;
            };
            defer admin_pg.deinit();

            const check_shadow = QailCmd.get("pg_catalog.pg_database")
                .select(&.{
                    Expr.col("datname"),
                }).where(&.{
                    .{ .condition = .{ .column = "datname", .op = .eq, .value = .{ .string = shadow_name } } },
                }).limit(1);
            const shadow_rows = try admin_pg.fetchAll(&check_shadow);
            defer Cli.deinitFetchedRows(allocator, shadow_rows);

            if (shadow_rows.len > 0) {
                print("  [1/4] Recreating existing shadow database: {s}\n", .{shadow_name});
                const drop_cmd = QailCmd.dropDatabase(shadow_name);
                _ = try admin_pg.execute(&drop_cmd);
            } else {
                print("  [1/4] Creating shadow database: {s}\n", .{shadow_name});
            }
            const create_cmd = QailCmd.createDatabase(shadow_name);
            _ = try admin_pg.execute(&create_cmd);

            const shadow_url = try migrate_support.rewriteDatabaseInUrl(allocator, url, shadow_name);
            defer allocator.free(shadow_url);
            var shadow_pg = Cli.connectPgUrl(allocator, shadow_url) catch |err| {
                print("Error connecting to shadow database: {}\n", .{err});
                return err;
            };
            defer shadow_pg.deinit();

            var empty_schema = parser.Schema.init(allocator);
            defer empty_schema.deinit();

            var base_cmds = parser.diffSchemas(allocator, &empty_schema, &old_schema) catch |err| {
                print("Error building shadow base schema commands: {}\n", .{err});
                return err;
            };
            defer migrate_support.deinitMigrationCmds(allocator, &base_cmds);

            var diff_cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                print("Error building shadow migration commands: {}\n", .{err});
                return err;
            };
            defer migrate_support.deinitMigrationCmds(allocator, &diff_cmds);

            print("  [2/4] Applying base schema to shadow ({d} command(s))\n", .{base_cmds.items.len});
            try migrate_support.executeMigrationCmds(allocator, &shadow_pg, base_cmds.items, "base");

            print("  [3/4] Applying migration diff to shadow ({d} command(s))\n", .{diff_cmds.items.len});
            try migrate_support.executeMigrationCmds(allocator, &shadow_pg, diff_cmds.items, "diff");

            var primary_pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to primary database: {}\n", .{err});
                return err;
            };
            defer primary_pg.deinit();

            const state_schema_diff = if (effective_schema_diff) |owned| owned else schema_diff;

            print("  [4/4] Saving shadow migration receipt\n", .{});
            try migrate_support.saveShadowState(allocator, &primary_pg, url, state_schema_diff, shadow_name);

            print("\n✅ Shadow migration prepared\n", .{});
            print("  Shadow DB: {s}\n", .{shadow_name});
            print("  Promote: qail migrate promote {s}\n", .{url});
            print("  Abort:   qail migrate abort {s}\n", .{url});
        }

        fn runMigratePromote(allocator: Allocator, url: []const u8) !void {
            const parser = @import("../parser/mod.zig");

            print("🔄 Shadow Promotion\n\n", .{});
            print("  URL: {s}\n\n", .{url});

            var primary_pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to primary database: {}\n", .{err});
                return err;
            };
            defer primary_pg.deinit();

            var state = (try migrate_support.loadActiveShadowState(allocator, &primary_pg)) orelse {
                print("No pending shadow migration found. Run 'qail migrate shadow' first.\n", .{});
                return error.MissingShadowState;
            };
            defer state.deinit(allocator);

            const diff = parseSchemaDiffPath(state.schema_diff);
            if (diff.old == null or diff.new == null) {
                print("Error: Saved shadow state has invalid schema diff path: {s}\n", .{state.schema_diff});
                return error.InvalidShadowStateRow;
            }

            const old_content = readFileAlloc(allocator, diff.old.?, 8 * 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return err;
            };
            defer allocator.free(old_content);

            const new_content = readFileAlloc(allocator, diff.new.?, 8 * 1024 * 1024) catch |err| {
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

            var diff_cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                print("Error computing promotion diff: {}\n", .{err});
                return err;
            };
            defer migrate_support.deinitMigrationCmds(allocator, &diff_cmds);

            print("  [1/3] Applying {d} migration command(s) on primary\n", .{diff_cmds.items.len});
            try primary_pg.begin();
            migrate_support.executeMigrationCmds(allocator, &primary_pg, diff_cmds.items, "promote") catch |err| {
                primary_pg.rollback() catch {};
                return err;
            };
            try primary_pg.commit();

            print("  [2/3] Dropping shadow database: {s}\n", .{state.shadow_name});
            const admin_url = try migrate_support.rewriteDatabaseInUrl(allocator, url, "postgres");
            defer allocator.free(admin_url);
            var admin_pg = Cli.connectPgUrl(allocator, admin_url) catch |err| {
                print("Error connecting to admin database: {}\n", .{err});
                return err;
            };
            defer admin_pg.deinit();
            const drop_cmd = QailCmd.dropDatabase(state.shadow_name);
            _ = try admin_pg.execute(&drop_cmd);

            print("  [3/3] Marking shadow state as promoted\n", .{});
            try migrate_support.updateShadowStateStatus(&primary_pg, "promoted");
            print("\n✅ Shadow promoted successfully\n", .{});
        }

        fn runMigrateAbort(allocator: Allocator, url: []const u8) !void {
            print("❌ Shadow Abort\n\n", .{});
            print("  URL: {s}\n\n", .{url});

            var primary_pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to primary database: {}\n", .{err});
                return err;
            };
            defer primary_pg.deinit();

            var state = (try migrate_support.loadActiveShadowState(allocator, &primary_pg)) orelse {
                print("No pending shadow migration found.\n", .{});
                return error.MissingShadowState;
            };
            defer state.deinit(allocator);

            print("  [1/2] Dropping shadow database: {s}\n", .{state.shadow_name});
            const admin_url = try migrate_support.rewriteDatabaseInUrl(allocator, url, "postgres");
            defer allocator.free(admin_url);
            var admin_pg = Cli.connectPgUrl(allocator, admin_url) catch |err| {
                print("Error connecting to admin database: {}\n", .{err});
                return err;
            };
            defer admin_pg.deinit();
            const drop_cmd = QailCmd.dropDatabase(state.shadow_name);
            _ = try admin_pg.execute(&drop_cmd);

            print("  [2/2] Marking shadow state as aborted\n", .{});
            try migrate_support.updateShadowStateStatus(&primary_pg, "aborted");
            print("\n✅ Shadow migration aborted\n", .{});
        }

        fn ensureMigrationTable(
            pg: *@import("../driver/driver.zig").PgDriver,
        ) !void {
            const parser = @import("../parser/mod.zig");
            const mig_cmd = parser.getMigrationTableCmd();
            _ = try pg.execute(&mig_cmd);
        }

        fn recordMigrationReceiptWithVersion(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
            version: []const u8,
            name: []const u8,
            sql_up: []const u8,
        ) !void {
            const parser = @import("../parser/mod.zig");
            const Value = @import("../ast/cmd.zig").Value;

            try ensureMigrationTable(pg);

            const checksum = parser.computeChecksum(sql_up);
            const checksum_str = try std.fmt.allocPrint(allocator, "{x:0>16}", .{checksum});
            defer allocator.free(checksum_str);

            const record_cmd = QailCmd{
                .kind = .add,
                .table = "_qail_migrations",
                .columns = &[_]Expr{
                    Expr.col("version"),
                    Expr.col("name"),
                    Expr.col("applied_at"),
                    Expr.col("checksum"),
                    Expr.col("sql_up"),
                    Expr.col("sql_down"),
                },
                .insert_values = &[_]Value{
                    Value.fromString(version),
                    Value.fromString(name),
                    Value.fromString("now"),
                    Value.fromString(checksum_str),
                    Value.fromString(sql_up),
                    Value.fromString(""),
                },
            };
            _ = try pg.execute(&record_cmd);
        }

        fn tryRecordMigrationReceiptWithVersionAuto(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
            version: []const u8,
            name: []const u8,
            sql_up: []const u8,
        ) !bool {
            const parser = @import("../parser/mod.zig");
            const Value = @import("../ast/cmd.zig").Value;

            try ensureMigrationTable(pg);

            const checksum = parser.computeChecksum(sql_up);
            const checksum_str = try std.fmt.allocPrint(allocator, "{x:0>16}", .{checksum});
            defer allocator.free(checksum_str);

            const record_cmd = QailCmd{
                .kind = .put,
                .table = "_qail_migrations",
                .columns = &[_]Expr{
                    Expr.col("version"),
                    Expr.col("name"),
                    Expr.col("applied_at"),
                    Expr.col("checksum"),
                    Expr.col("sql_up"),
                    Expr.col("sql_down"),
                },
                .insert_values = &[_]Value{
                    Value.fromString(version),
                    Value.fromString(name),
                    Value.fromString("now"),
                    Value.fromString(checksum_str),
                    Value.fromString(sql_up),
                    Value.fromString(""),
                },
            };

            const affected = try pg.execute(&record_cmd);
            return affected > 0;
        }

        fn recordMigrationReceipt(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
            name: []const u8,
            sql_up: []const u8,
        ) ![14]u8 {
            const parser = @import("../parser/mod.zig");
            const max_attempts: usize = 1024;
            var attempt: usize = 0;

            while (attempt < max_attempts) : (attempt += 1) {
                const version = parser.generateVersion();
                const inserted = try tryRecordMigrationReceiptWithVersionAuto(
                    allocator,
                    pg,
                    &version,
                    name,
                    sql_up,
                );
                if (inserted) return version;
            }

            return error.ExecuteError;
        }

        fn runMigrateRollback(
            allocator: Allocator,
            schema_diff: []const u8,
            url: []const u8,
            operation: []const u8,
            wait_for_lock: bool,
            lock_timeout_secs: ?u64,
        ) !void {
            const parser = @import("../parser/mod.zig");
            const diff = parseSchemaDiffPath(schema_diff);
            if (diff.old == null or diff.new == null) {
                print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                return;
            }

            print("⏪ Applying rollback: {s}\n", .{schema_diff});
            print("Database: {s}\n\n", .{url});

            const old_content = readFileAlloc(allocator, diff.old.?, 8 * 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return err;
            };
            defer allocator.free(old_content);

            const new_content = readFileAlloc(allocator, diff.new.?, 8 * 1024 * 1024) catch |err| {
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

            // Reverse the diff direction to roll schema back from `new` to `old`.
            var rollback_cmds = parser.diffSchemas(allocator, &new_schema, &old_schema) catch |err| {
                print("Error computing rollback diff: {}\n", .{err});
                return err;
            };
            defer migrate_support.deinitMigrationCmds(allocator, &rollback_cmds);

            if (rollback_cmds.items.len == 0) {
                print("✅ No rollback needed\n", .{});
                return;
            }

            const rollback_sql = parser.toSqlStatements(allocator, &rollback_cmds) catch |err| {
                print("Error generating rollback SQL: {}\n", .{err});
                return err;
            };
            defer allocator.free(rollback_sql);

            print("Executing {d} rollback operation(s)...\n", .{rollback_cmds.items.len});
            var pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return err;
            };
            defer pg.deinit();
            try Cli.acquireMigrationLock(
                allocator,
                &pg,
                operation,
                url,
                wait_for_lock,
                lock_timeout_secs,
            );

            try pg.begin();
            migrate_support.executeMigrationCmds(allocator, &pg, rollback_cmds.items, "rollback") catch |err| {
                pg.rollback() catch {};
                return err;
            };

            var receipt_version: ?[14]u8 = null;
            receipt_version = recordMigrationReceipt(allocator, &pg, "rollback_migration", rollback_sql) catch |err| blk: {
                print("Warning: failed to record rollback receipt: {}\n", .{err});
                break :blk null;
            };

            try pg.commit();
            print("\n✅ Rollback applied successfully!\n", .{});
            if (receipt_version) |version| {
                print("  Recorded as migration: {s}\n", .{&version});
            }
        }

        fn runMigrateReset(
            allocator: Allocator,
            schema_path: []const u8,
            url: []const u8,
            wait_for_lock: bool,
            lock_timeout_secs: ?u64,
        ) !void {
            const parser = @import("../parser/mod.zig");

            print("🔄 Resetting database to schema: {s}\n", .{schema_path});
            print("Database: {s}\n\n", .{url});

            const target_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
                print("Error reading target schema: {}\n", .{err});
                return err;
            };
            defer allocator.free(target_content);

            var target_schema = parser.Schema.parse(allocator, target_content) catch |err| {
                print("Error parsing target schema: {}\n", .{err});
                return err;
            };
            defer target_schema.deinit();

            var pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return err;
            };
            defer pg.deinit();
            try Cli.acquireMigrationLock(
                allocator,
                &pg,
                "migrate reset",
                url,
                wait_for_lock,
                lock_timeout_secs,
            );

            const live_snapshot = schema_cli.renderLiveSchemaSnapshot(allocator, &pg) catch |err| {
                print("Error introspecting live schema: {}\n", .{err});
                return err;
            };
            defer allocator.free(live_snapshot.schema);

            var live_schema = parser.Schema.parse(allocator, live_snapshot.schema) catch |err| {
                print("Error parsing live schema snapshot: {}\n", .{err});
                return err;
            };
            defer live_schema.deinit();

            var empty_schema = parser.Schema.init(allocator);
            defer empty_schema.deinit();

            var drop_cmds = parser.diffSchemas(allocator, &live_schema, &empty_schema) catch |err| {
                print("Error computing reset drop plan: {}\n", .{err});
                return err;
            };
            defer migrate_support.deinitMigrationCmds(allocator, &drop_cmds);

            var create_cmds = parser.diffSchemas(allocator, &empty_schema, &target_schema) catch |err| {
                print("Error computing reset create plan: {}\n", .{err});
                return err;
            };
            defer migrate_support.deinitMigrationCmds(allocator, &create_cmds);

            print("  Live schema: {d} table(s), {d} column(s)\n", .{ live_snapshot.table_count, live_snapshot.column_count });
            print("  Drop commands: {d}\n", .{drop_cmds.items.len});
            print("  Create commands: {d}\n\n", .{create_cmds.items.len});

            try pg.begin();

            if (drop_cmds.items.len > 0) {
                migrate_support.executeMigrationCmds(allocator, &pg, drop_cmds.items, "reset-drop") catch |err| {
                    pg.rollback() catch {};
                    return err;
                };
            }

            const clear_history = QailCmd.del("_qail_migrations");
            _ = pg.execute(&clear_history) catch |err| {
                print("Warning: failed to clear migration history (continuing): {}\n", .{err});
            };

            if (create_cmds.items.len > 0) {
                migrate_support.executeMigrationCmds(allocator, &pg, create_cmds.items, "reset-create") catch |err| {
                    pg.rollback() catch {};
                    return err;
                };
            }

            const reset_summary = try std.fmt.allocPrint(
                allocator,
                "source=reset;drop_cmds={d};create_cmds={d}",
                .{ drop_cmds.items.len, create_cmds.items.len },
            );
            defer allocator.free(reset_summary);

            var receipt_version: ?[14]u8 = null;
            receipt_version = recordMigrationReceipt(allocator, &pg, "reset_migration", reset_summary) catch |err| blk: {
                print("Warning: failed to record reset receipt: {}\n", .{err});
                break :blk null;
            };

            try pg.commit();
            print("✅ Reset applied successfully\n", .{});
            if (receipt_version) |version| {
                print("  Recorded as migration: {s}\n", .{&version});
            }
        }

        const MigrationFileEntry = struct {
            version: []u8,
            name: []u8,
            path: []u8,

            fn deinit(self: *MigrationFileEntry, allocator: Allocator) void {
                allocator.free(self.version);
                allocator.free(self.name);
                allocator.free(self.path);
            }
        };

        fn deinitMigrationFileEntries(
            allocator: Allocator,
            entries: *std.ArrayList(MigrationFileEntry),
        ) void {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        fn lessThanMigrationFileEntry(_: void, a: MigrationFileEntry, b: MigrationFileEntry) bool {
            return std.mem.lessThan(u8, a.version, b.version);
        }

        pub fn parseApplyPhaseValue(value: []const u8) ?ApplyPhase {
            if (std.mem.eql(u8, value, "all")) return .all;
            if (std.mem.eql(u8, value, "expand")) return .expand;
            if (std.mem.eql(u8, value, "backfill")) return .backfill;
            if (std.mem.eql(u8, value, "contract")) return .contract;
            return null;
        }

        fn applyPhaseToken(phase: ApplyPhase) []const u8 {
            return switch (phase) {
                .all => "all",
                .expand => "expand",
                .backfill => "backfill",
                .contract => "contract",
            };
        }

        fn detectMigrationPhaseFromContent(content: []const u8) ?ApplyPhase {
            var lines = std.mem.splitScalar(u8, content, '\n');
            var scanned: usize = 0;
            while (lines.next()) |line| {
                if (scanned >= 64) break;
                scanned += 1;
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                var payload: ?[]const u8 = null;
                if (std.mem.startsWith(u8, trimmed, "-- @phase:")) {
                    payload = std.mem.trim(u8, trimmed["-- @phase:".len..], " \t");
                } else if (std.mem.startsWith(u8, trimmed, "# @phase:")) {
                    payload = std.mem.trim(u8, trimmed["# @phase:".len..], " \t");
                } else if (std.mem.startsWith(u8, trimmed, "--")) {
                    continue;
                } else {
                    break;
                }

                if (payload) |value| {
                    return parseApplyPhaseValue(value);
                }
            }
            return null;
        }

        fn migrationFileMatchesPhase(
            allocator: Allocator,
            path: []const u8,
            phase: ApplyPhase,
        ) !bool {
            if (phase == .all) return true;

            const content = readFileAlloc(allocator, path, 512 * 1024) catch |err| {
                if (err == error.FileNotFound) return false;
                return err;
            };
            defer allocator.free(content);

            if (detectMigrationPhaseFromContent(content)) |phase_tag| {
                return phase_tag == phase;
            }

            return pathContainsMigrationPhaseToken(path, applyPhaseToken(phase));
        }

        fn migrationPathExists(path: []const u8) !bool {
            _ = std.Io.Dir.cwd().statFile(io_compat.runtimeIo(), path, .{}) catch |err| {
                if (err == error.FileNotFound) return false;
                return err;
            };
            return true;
        }

        fn appendMigrationFileEntry(
            allocator: Allocator,
            entries: *std.ArrayList(MigrationFileEntry),
            version: []const u8,
            name: []const u8,
            path: []const u8,
        ) !void {
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.version, version)) {
                    return error.DuplicateMigrationVersion;
                }
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateMigrationName;
                }
            }

            const version_copy = try allocator.dupe(u8, version);
            errdefer allocator.free(version_copy);
            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);

            try entries.append(allocator, .{
                .version = version_copy,
                .name = name_copy,
                .path = path_copy,
            });
        }

        fn migrationDownPath(allocator: Allocator, version: []const u8) ![]u8 {
            const flat = try std.fmt.allocPrint(allocator, "migrations/{s}.down.qail", .{version});
            errdefer allocator.free(flat);
            if (try migrationPathExists(flat)) return flat;

            allocator.free(flat);
            return try std.fmt.allocPrint(allocator, "migrations/{s}/down.qail", .{version});
        }

        fn collectUpMigrationFiles(allocator: Allocator) !std.ArrayList(MigrationFileEntry) {
            var entries: std.ArrayList(MigrationFileEntry) = .empty;
            errdefer deinitMigrationFileEntries(allocator, &entries);

            const io_iface = io_compat.runtimeIo();
            var dir = std.Io.Dir.cwd().openDir(io_iface, "migrations", .{ .iterate = true }) catch |err| {
                if (err == error.FileNotFound) return entries;
                return err;
            };
            defer dir.close(io_iface);

            var iter = dir.iterate();
            while (try iter.next(io_iface)) |entry| {
                switch (entry.kind) {
                    .file => {
                        if (std.mem.endsWith(u8, entry.name, ".up.sql")) return error.UnsupportedSqlMigrationFile;
                        const parts = parseMigrationUpFileName(entry.name) catch |err| switch (err) {
                            error.NotUpMigrationFile => continue,
                            else => return err,
                        };
                        const path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{entry.name});
                        defer allocator.free(path);
                        try appendMigrationFileEntry(allocator, &entries, parts.stem, parts.name, path);
                    },
                    .directory => {
                        const up_qail = try std.fmt.allocPrint(allocator, "migrations/{s}/up.qail", .{entry.name});
                        defer allocator.free(up_qail);
                        const up_sql = try std.fmt.allocPrint(allocator, "migrations/{s}/up.sql", .{entry.name});
                        defer allocator.free(up_sql);

                        if (try migrationPathExists(up_sql)) return error.UnsupportedSqlMigrationFile;
                        if (!try migrationPathExists(up_qail)) continue;

                        const parts = try parseMigrationStem(entry.name);
                        try appendMigrationFileEntry(allocator, &entries, parts.stem, parts.name, up_qail);
                    },
                    else => continue,
                }
            }

            std.mem.sort(MigrationFileEntry, entries.items, {}, lessThanMigrationFileEntry);
            return entries;
        }

        fn loadAppliedMigrationVersions(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
        ) !std.StringHashMap(void) {
            var applied = std.StringHashMap(void).init(allocator);
            errdefer migrate_support.deinitStringSet(allocator, &applied);

            try ensureMigrationTable(pg);

            const applied_cmd = QailCmd.get("_qail_migrations")
                .select(&.{
                    Expr.col("version"),
                }).orderBy(&.{
                .{ .column = "version", .order = .asc },
            });
            const rows = try pg.fetchAll(&applied_cmd);
            defer Cli.deinitFetchedRows(allocator, rows);

            for (rows) |row| {
                const version = row.getByName("version") orelse continue;
                try migrate_support.putStringSetKey(allocator, &applied, version);
            }

            return applied;
        }

        fn runMigrateApply(
            allocator: Allocator,
            url: []const u8,
            direction: MigrationDirection,
            phase: ApplyPhase,
            wait_for_lock: bool,
            lock_timeout_secs: ?u64,
        ) !void {
            const parser = @import("../parser/mod.zig");

            print("📦 Applying folder migrations\n\n", .{});
            print("  URL: {s}\n", .{url});
            print("  Directory: migrations/\n\n", .{});
            if (phase != .all) {
                print("  Phase filter: {s}\n\n", .{applyPhaseToken(phase)});
            }

            if (direction == .down) {
                if (phase != .all) {
                    var preview_pg = Cli.connectPgUrl(allocator, url) catch |err| {
                        print("Error connecting to database: {}\n", .{err});
                        return err;
                    };
                    defer preview_pg.deinit();

                    var applied = try loadAppliedMigrationHistory(allocator, &preview_pg);
                    defer deinitAppliedMigrationEntries(allocator, &applied);

                    if (applied.items.len == 0) {
                        print("No applied migrations found.\n", .{});
                        return;
                    }

                    var rollback_count: usize = 0;
                    var target_version: []const u8 = "base";
                    var idx = applied.items.len;
                    while (idx > 0) {
                        idx -= 1;
                        const entry = applied.items[idx];

                        const matches_phase = blk: {
                            const down_path = try migrationDownPath(allocator, entry.version);
                            defer allocator.free(down_path);
                            break :blk try migrationFileMatchesPhase(allocator, down_path, phase);
                        };
                        if (!matches_phase) break;

                        rollback_count += 1;
                        target_version = if (idx == 0) "base" else applied.items[idx - 1].version;
                    }

                    if (rollback_count == 0) {
                        print("✅ No rollback tail migrations for phase '{s}'\n", .{applyPhaseToken(phase)});
                        return;
                    }

                    print(
                        "↩ Rolling back {d} migration(s) for phase '{s}'\n",
                        .{ rollback_count, applyPhaseToken(phase) },
                    );
                    try runMigrateRollbackToVersion(
                        allocator,
                        target_version,
                        url,
                        "migrate apply",
                        wait_for_lock,
                        lock_timeout_secs,
                    );
                    return;
                }

                try runMigrateRollbackToVersion(
                    allocator,
                    "base",
                    url,
                    "migrate apply",
                    wait_for_lock,
                    lock_timeout_secs,
                );
                return;
            }

            var migration_files = try collectUpMigrationFiles(allocator);
            defer deinitMigrationFileEntries(allocator, &migration_files);

            if (migration_files.items.len == 0) {
                print("No migration files found in migrations/\n", .{});
                return;
            }

            var pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return err;
            };
            defer pg.deinit();
            try Cli.acquireMigrationLock(
                allocator,
                &pg,
                "migrate apply",
                url,
                wait_for_lock,
                lock_timeout_secs,
            );

            var applied_versions = try loadAppliedMigrationVersions(allocator, &pg);
            defer migrate_support.deinitStringSet(allocator, &applied_versions);

            var pending_count: usize = 0;
            for (migration_files.items) |entry| {
                if (!try migrationFileMatchesPhase(allocator, entry.path, phase)) continue;
                if (!applied_versions.contains(entry.version)) pending_count += 1;
            }

            if (pending_count == 0) {
                print("✅ No pending migrations\n", .{});
                return;
            }

            var applied_count: usize = 0;
            for (migration_files.items) |entry| {
                if (!try migrationFileMatchesPhase(allocator, entry.path, phase)) continue;
                if (applied_versions.contains(entry.version)) continue;

                print("  [{d}/{d}] {s}\n", .{ applied_count + 1, pending_count, entry.path });

                const migration_content = readFileAlloc(allocator, entry.path, 16 * 1024 * 1024) catch |err| {
                    print("Error reading migration file {s}: {}\n", .{ entry.path, err });
                    return err;
                };
                defer allocator.free(migration_content);

                var statements = commands.collectExecStatements(allocator, null, entry.path) catch |err| {
                    print("Error collecting migration statements from {s}: {}\n", .{ entry.path, err });
                    return err;
                };
                defer statements.deinit(allocator);

                try pg.begin();

                var success = true;
                for (statements.items.items, 0..) |stmt, stmt_idx| {
                    var cmd = parser.parse(allocator, stmt) catch |err| {
                        print("Parse error in {s} statement {d}: {}\n", .{ entry.path, stmt_idx + 1, err });
                        success = false;
                        break;
                    };
                    defer Cli.freeParsedCmd(allocator, &cmd);

                    if (commands.cmdReturnsRows(cmd.kind)) {
                        const rows = pg.fetchAll(&cmd) catch |err| {
                            print("Execution error in {s} statement {d}: {}\n", .{ entry.path, stmt_idx + 1, err });
                            success = false;
                            break;
                        };
                        defer Cli.deinitFetchedRows(allocator, rows);
                    } else {
                        _ = pg.execute(&cmd) catch |err| {
                            print("Execution error in {s} statement {d}: {}\n", .{ entry.path, stmt_idx + 1, err });
                            success = false;
                            break;
                        };
                    }
                }

                if (!success) {
                    pg.rollback() catch {};
                    return error.MigrationApplyFailed;
                }

                recordMigrationReceiptWithVersion(
                    allocator,
                    &pg,
                    entry.version,
                    entry.name,
                    migration_content,
                ) catch |err| {
                    pg.rollback() catch {};
                    print("Failed to record migration receipt for {s}: {}\n", .{ entry.version, err });
                    return err;
                };

                try pg.commit();
                applied_count += 1;
                try migrate_support.putStringSetKey(allocator, &applied_versions, entry.version);

                print("    ✓ Applied {s}\n", .{entry.version});
            }

            print("\n✅ Applied {d} migration(s)\n", .{applied_count});
        }

        const AppliedMigrationEntry = struct {
            version: []u8,
            name: []u8,

            fn deinit(self: *AppliedMigrationEntry, allocator: Allocator) void {
                allocator.free(self.version);
                allocator.free(self.name);
            }
        };

        fn deinitAppliedMigrationEntries(
            allocator: Allocator,
            entries: *std.ArrayList(AppliedMigrationEntry),
        ) void {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        fn loadAppliedMigrationHistory(
            allocator: Allocator,
            pg: *@import("../driver/driver.zig").PgDriver,
        ) !std.ArrayList(AppliedMigrationEntry) {
            var entries: std.ArrayList(AppliedMigrationEntry) = .empty;
            errdefer deinitAppliedMigrationEntries(allocator, &entries);

            try ensureMigrationTable(pg);

            const status_cmd = QailCmd.get("_qail_migrations")
                .select(&.{
                    Expr.col("version"),
                    Expr.col("name"),
                }).orderBy(&.{
                .{ .column = "version", .order = .asc },
            });
            const rows = try pg.fetchAll(&status_cmd);
            defer Cli.deinitFetchedRows(allocator, rows);

            for (rows) |row| {
                const version = row.getByName("version") orelse continue;
                const name = row.getByName("name") orelse "";
                try entries.append(allocator, .{
                    .version = try allocator.dupe(u8, version),
                    .name = try allocator.dupe(u8, name),
                });
            }

            return entries;
        }

        fn runMigrateRollbackToVersion(
            allocator: Allocator,
            to: []const u8,
            url: []const u8,
            operation: []const u8,
            wait_for_lock: bool,
            lock_timeout_secs: ?u64,
        ) !void {
            const parser = @import("../parser/mod.zig");

            print("⏮️ Rollback to target version\n\n", .{});
            print("  URL: {s}\n", .{url});
            print("  Target: {s}\n\n", .{to});

            var pg = Cli.connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return err;
            };
            defer pg.deinit();
            try Cli.acquireMigrationLock(
                allocator,
                &pg,
                operation,
                url,
                wait_for_lock,
                lock_timeout_secs,
            );

            var applied = try loadAppliedMigrationHistory(allocator, &pg);
            defer deinitAppliedMigrationEntries(allocator, &applied);

            if (applied.items.len == 0) {
                print("No applied migrations found.\n", .{});
                return;
            }

            var start_idx: usize = 0;
            if (!std.mem.eql(u8, to, "base")) {
                const target_idx = for (applied.items, 0..) |entry, idx| {
                    if (std.mem.eql(u8, entry.version, to)) break idx;
                } else {
                    print("Target version not found in _qail_migrations: {s}\n", .{to});
                    return error.MigrationTargetNotFound;
                };
                start_idx = target_idx + 1;
            }

            if (start_idx >= applied.items.len) {
                print("✅ Already at requested version\n", .{});
                return;
            }

            const rollback_count = applied.items.len - start_idx;
            print("Rolling back {d} migration(s)...\n", .{rollback_count});

            try pg.begin();

            var idx = applied.items.len;
            while (idx > start_idx) {
                idx -= 1;
                const entry = applied.items[idx];

                const down_path = try migrationDownPath(allocator, entry.version);
                defer allocator.free(down_path);

                print("  ↩ {s}\n", .{entry.version});

                var statements = commands.collectExecStatements(allocator, null, down_path) catch |err| {
                    pg.rollback() catch {};
                    print("Failed to load rollback migration {s}: {}\n", .{ down_path, err });
                    return err;
                };
                defer statements.deinit(allocator);

                for (statements.items.items, 0..) |stmt, stmt_idx| {
                    var cmd = parser.parse(allocator, stmt) catch |err| {
                        pg.rollback() catch {};
                        print("Parse error in {s} statement {d}: {}\n", .{ down_path, stmt_idx + 1, err });
                        return err;
                    };
                    defer Cli.freeParsedCmd(allocator, &cmd);

                    if (commands.cmdReturnsRows(cmd.kind)) {
                        const rows = pg.fetchAll(&cmd) catch |err| {
                            pg.rollback() catch {};
                            print("Execution error in {s} statement {d}: {}\n", .{ down_path, stmt_idx + 1, err });
                            return err;
                        };
                        defer Cli.deinitFetchedRows(allocator, rows);
                    } else {
                        _ = pg.execute(&cmd) catch |err| {
                            pg.rollback() catch {};
                            print("Execution error in {s} statement {d}: {}\n", .{ down_path, stmt_idx + 1, err });
                            return err;
                        };
                    }
                }

                const delete_cmd = QailCmd.del("_qail_migrations").where(&.{
                    .{ .condition = .{ .column = "version", .op = .eq, .value = .{ .string = entry.version } } },
                });
                _ = pg.execute(&delete_cmd) catch |err| {
                    pg.rollback() catch {};
                    print("Failed to delete migration receipt {s}: {}\n", .{ entry.version, err });
                    return err;
                };
            }

            const rollback_summary = try std.fmt.allocPrint(
                allocator,
                "source=rollback_to;to={s};rolled_back={d}",
                .{ to, rollback_count },
            );
            defer allocator.free(rollback_summary);

            _ = recordMigrationReceipt(allocator, &pg, "rollback_to", rollback_summary) catch |err| {
                pg.rollback() catch {};
                print("Failed to record rollback receipt: {}\n", .{err});
                return err;
            };

            try pg.commit();
            print("✅ Rolled back {d} migration(s)\n", .{rollback_count});
        }

        pub fn runMigrate(allocator: Allocator, action: MigrateAction) !void {
            const parser = @import("../parser/mod.zig");

            switch (action) {
                .status => |url| {
                    const resolved_url = try Cli.resolveDatabaseUrl(url);
                    try runMigrateStatus(allocator, resolved_url);
                },
                .plan => |p| {
                    // Parse schema_diff as old.qail:new.qail
                    const diff = parseSchemaDiffPath(p.schema_diff);
                    if (diff.old == null or diff.new == null) {
                        print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                        return;
                    }

                    print("📋 Migration Plan (dry-run)\n\n", .{});
                    print("  {s} → {s}\n\n", .{ diff.old.?, diff.new.? });

                    // Load schema files
                    const old_content = readFileAlloc(allocator, diff.old.?, 1024 * 1024) catch |err| {
                        print("Error reading old schema: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(old_content);

                    const new_content = readFileAlloc(allocator, diff.new.?, 1024 * 1024) catch |err| {
                        print("Error reading new schema: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(new_content);

                    // Parse schemas
                    var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
                        print("Error parsing old schema: {}\n", .{err});
                        return;
                    };
                    defer old_schema.deinit();

                    var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                        print("Error parsing new schema: {}\n", .{err});
                        return;
                    };
                    defer new_schema.deinit();

                    // Compute diff
                    var cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                        print("Error computing diff: {}\n", .{err});
                        return;
                    };
                    defer migrate_support.deinitMigrationCmds(allocator, &cmds);

                    if (cmds.items.len == 0) {
                        print("✅ No migrations needed - schemas are identical\n", .{});
                        return;
                    }

                    // Generate SQL
                    const sql = parser.toSqlStatements(allocator, &cmds) catch |err| {
                        print("Error generating SQL: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(sql);

                    print("┌─ UP ({d} operations) ─────────────────────────────────┐\n", .{cmds.items.len});
                    print("{s}", .{sql});
                    print("└──────────────────────────────────────────────────────────────┘\n\n", .{});

                    // Generate and show DOWN migrations
                    print("┌─ DOWN ({d} operations) ──────────────────────────────┐\n", .{cmds.items.len});
                    for (cmds.items) |*migration_cmd| {
                        const down_sql = migration_cmd.toDownSql(allocator) catch continue;
                        defer allocator.free(down_sql);
                        print("│ {s}\n", .{down_sql});
                    }
                    print("└──────────────────────────────────────────────────────────────┘\n", .{});

                    if (p.output) |output_path| {
                        var out = io_compat.AllocatingWriter.init(allocator);
                        defer out.deinit();
                        const writer = out.writer();
                        try writer.print("-- Migration UP ({d} operations)\n", .{cmds.items.len});
                        try writer.writeAll(sql);
                        if (sql.len == 0 or sql[sql.len - 1] != '\n') {
                            try writer.writeAll("\n");
                        }
                        try writer.print("\n-- Migration DOWN ({d} operations)\n", .{cmds.items.len});
                        for (cmds.items) |*migration_cmd| {
                            const down_sql = migration_cmd.toDownSql(allocator) catch continue;
                            defer allocator.free(down_sql);
                            try writer.print("{s};\n", .{down_sql});
                        }

                        const output_content = try out.toOwnedSlice();
                        defer allocator.free(output_content);

                        std.Io.Dir.cwd().writeFile(io_compat.runtimeIo(), .{
                            .sub_path = output_path,
                            .data = output_content,
                            .flags = .{
                                .truncate = true,
                            },
                        }) catch |err| {
                            print("Error writing plan output {s}: {}\n", .{ output_path, err });
                            return err;
                        };
                        print("✅ Plan saved to {s}\n", .{output_path});
                    }
                },
                .up => |u| {
                    const resolved_url = try Cli.resolveDatabaseUrl(u.url);
                    if (u.allow_destructive or u.allow_no_shadow_receipt or u.allow_lock_risk) {
                        print("⚠️ migrate up: allow-* guard flags are parsed; zig CLI guardrails are currently limited\n", .{});
                    }
                    const diff = parseSchemaDiffPath(u.schema_diff);
                    if (diff.old == null or diff.new == null) {
                        print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                        return;
                    }

                    print("⬆️ Applying migration: {s}\n", .{u.schema_diff});
                    print("Database: {s}\n\n", .{resolved_url});

                    // Load schema files
                    const old_content = readFileAlloc(allocator, diff.old.?, 1024 * 1024) catch |err| {
                        print("Error reading old schema: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(old_content);

                    const new_content = readFileAlloc(allocator, diff.new.?, 1024 * 1024) catch |err| {
                        print("Error reading new schema: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(new_content);

                    // Parse schemas
                    var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
                        print("Error parsing old schema: {}\n", .{err});
                        return;
                    };
                    defer old_schema.deinit();

                    var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                        print("Error parsing new schema: {}\n", .{err});
                        return;
                    };
                    defer new_schema.deinit();

                    // Compute diff
                    var cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                        print("Error computing diff: {}\n", .{err});
                        return;
                    };
                    defer {
                        // Free table_columns allocations first
                        for (cmds.items) |cmd| {
                            if (cmd.table_columns.len > 0) {
                                allocator.free(cmd.table_columns);
                            }
                        }
                        cmds.deinit(allocator);
                    }

                    if (cmds.items.len == 0) {
                        print("✅ No migrations needed\n", .{});
                        return;
                    }

                    if (u.codebase) |codebase| {
                        const scanner_mod = @import("../analyzer/scanner.zig");
                        const impact_mod = @import("../analyzer/impact.zig");

                        print("🔎 Codebase impact scan: {s}\n", .{codebase});
                        var scanner = scanner_mod.CodebaseScanner.init(allocator);
                        defer scanner.deinit();

                        scanner.scan(codebase) catch |err| {
                            print("Error scanning codebase: {}\n", .{err});
                            return err;
                        };

                        var impact = impact_mod.MigrationImpact.analyze(
                            allocator,
                            cmds.items,
                            scanner.refs.items,
                        ) catch |err| {
                            print("Error analyzing migration impact: {}\n", .{err});
                            return err;
                        };
                        defer impact.deinit();

                        const impact_report = impact.report(allocator) catch |err| {
                            print("Error rendering impact report: {}\n", .{err});
                            return err;
                        };
                        defer allocator.free(impact_report);

                        print("  Operations: {d}\n", .{cmds.items.len});
                        print("  Query references scanned: {d}\n", .{scanner.refs.items.len});
                        print("{s}\n", .{impact_report});

                        if (!impact.safe_to_run and !u.force) {
                            print("❌ Unsafe migration impact detected. Re-run with --force to proceed.\n", .{});
                            return error.MigrationUnsafe;
                        }
                        if (!impact.safe_to_run and u.force) {
                            print("⚠️ Unsafe migration impact ignored due to --force\n", .{});
                        }
                    }

                    // Generate SQL
                    const sql = parser.toSqlStatements(allocator, &cmds) catch |err| {
                        print("Error generating SQL: {}\n", .{err});
                        return;
                    };
                    defer allocator.free(sql);

                    print("Executing {d} operation(s)...\n", .{cmds.items.len});

                    var pg = Cli.connectPgUrl(allocator, resolved_url) catch |err| {
                        print("Error connecting to database: {}\n", .{err});
                        return;
                    };
                    defer pg.deinit();
                    try Cli.acquireMigrationLock(
                        allocator,
                        &pg,
                        "migrate up",
                        resolved_url,
                        u.wait_for_lock,
                        u.lock_timeout_secs,
                    );

                    // === PHASE 1: Impact Analysis ===
                    var analysis = data_safety.ImpactAnalysis.init(allocator);
                    data_safety.analyzeImpact(allocator, cmds.items, &pg, &analysis) catch |err| {
                        print("Warning: Could not analyze impact: {}\n", .{err});
                        // Continue anyway - analysis is advisory
                    };
                    defer analysis.deinit();

                    var migration_version: []const u8 = "";

                    if (analysis.hasDestructive()) {
                        data_safety.displayImpact(&analysis);

                        const choice = data_safety.promptBackupOptions();
                        switch (choice) {
                            .proceed => {
                                print("Proceeding without backup...\n", .{});
                            },
                            .backup_to_file => {
                                print("File backup not yet implemented. Proceeding...\n", .{});
                            },
                            .backup_to_db => {
                                // Generate version for this migration
                                const version_buf = parser.generateVersion();
                                migration_version = &version_buf;
                                _ = data_safety.createDbSnapshots(allocator, &pg, migration_version, &analysis) catch |err| {
                                    print("Warning: Backup failed: {}. Aborting.\n", .{err});
                                    return;
                                };
                            },
                            .cancel => {
                                print("Migration cancelled.\n", .{});
                                return;
                            },
                        }
                    }

                    // Begin transaction
                    pg.begin() catch |err| {
                        print("Error starting transaction: {}\n", .{err});
                        return;
                    };

                    // Execute each migration command using AST-native execution
                    var success = true;
                    for (cmds.items) |migration_cmd| {
                        // Convert to AST command (no raw SQL!)
                        const qail_cmd = migration_cmd.toQailCmd(allocator) catch |err| {
                            print("Error converting migration: {}\n", .{err});
                            success = false;
                            break;
                        };
                        defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);

                        // Show what we're executing
                        const stmt_sql = migration_cmd.toSql(allocator) catch continue;
                        defer allocator.free(stmt_sql);
                        print("  {s};\n", .{stmt_sql});

                        // Execute via AST-native path
                        _ = pg.execute(&qail_cmd) catch |err| {
                            print("Error executing: {}\n", .{err});
                            success = false;
                            break;
                        };
                    }

                    if (success) {
                        // Record migration in history (AST-native - no raw SQL!)
                        const version = recordMigrationReceipt(
                            allocator,
                            &pg,
                            "auto_migration",
                            sql,
                        ) catch |err| {
                            pg.rollback() catch {};
                            print("Failed to record migration receipt: {}\n", .{err});
                            return err;
                        };

                        pg.commit() catch |err| {
                            print("Error committing: {}\n", .{err});
                            return;
                        };
                        print("\n✅ Migration applied successfully!\n", .{});
                        print("  Recorded as migration: {s}\n", .{&version});
                    } else {
                        pg.rollback() catch {};
                        print("\n❌ Migration failed, rolled back\n", .{});
                    }
                },
                .down => |d| {
                    const resolved_url = try Cli.resolveDatabaseUrl(d.url);
                    try runMigrateRollback(
                        allocator,
                        d.schema_diff,
                        resolved_url,
                        "migrate down",
                        d.wait_for_lock,
                        d.lock_timeout_secs,
                    );
                },
                .apply => |a| {
                    const resolved_url = try Cli.resolveDatabaseUrl(a.url);
                    if (a.codebase != null or a.allow_contract_with_references or a.allow_destructive or a.allow_no_shadow_receipt or a.allow_lock_risk or a.adopt_existing or a.backfill_chunk_size != 5000) {
                        print("⚠️ migrate apply: advanced safety/backfill flags are parsed; execution currently uses base folder apply flow\n", .{});
                    }
                    try runMigrateApply(
                        allocator,
                        resolved_url,
                        a.direction,
                        a.phase,
                        a.wait_for_lock,
                        a.lock_timeout_secs,
                    );
                },
                .rollback => |r| {
                    const resolved_url = try Cli.resolveDatabaseUrl(r.url);
                    if (r.to) |target| {
                        try runMigrateRollbackToVersion(
                            allocator,
                            target,
                            resolved_url,
                            "migrate rollback",
                            r.wait_for_lock,
                            r.lock_timeout_secs,
                        );
                    } else if (r.schema_diff) |schema_diff| {
                        try runMigrateRollback(
                            allocator,
                            schema_diff,
                            resolved_url,
                            "migrate rollback",
                            r.wait_for_lock,
                            r.lock_timeout_secs,
                        );
                    } else {
                        return error.MissingArgument;
                    }
                },
                .reset => |r| {
                    const resolved_url = try Cli.resolveDatabaseUrl(r.url);
                    try runMigrateReset(
                        allocator,
                        r.schema,
                        resolved_url,
                        r.wait_for_lock,
                        r.lock_timeout_secs,
                    );
                },
                .create => |c| {
                    const timestamp_ms = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds();
                    const io_iface = io_compat.runtimeIo();

                    try std.Io.Dir.cwd().createDirPath(io_iface, "migrations");

                    const safe_name = try migrate_support.slugifyMigrationName(allocator, c.name);
                    defer allocator.free(safe_name);

                    const migration_id = try std.fmt.allocPrint(allocator, "{d}_{s}", .{ timestamp_ms, safe_name });
                    defer allocator.free(migration_id);

                    const up_filename = try std.fmt.allocPrint(allocator, "{s}.up.qail", .{migration_id});
                    defer allocator.free(up_filename);
                    const down_filename = try std.fmt.allocPrint(allocator, "{s}.down.qail", .{migration_id});
                    defer allocator.free(down_filename);

                    const up_path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{up_filename});
                    defer allocator.free(up_path);
                    const down_path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{down_filename});
                    defer allocator.free(down_path);

                    var header = io_compat.AllocatingWriter.init(allocator);
                    defer header.deinit();
                    const header_writer = header.writer();
                    try header_writer.print("-- @name: {s}\n", .{migration_id});
                    try header_writer.print("-- @created_unix_ms: {d}\n", .{timestamp_ms});
                    if (c.author) |author| {
                        try header_writer.print("-- @author: {s}\n", .{author});
                    }
                    if (c.depends) |depends| {
                        try header_writer.print("-- @depends: {s}\n", .{depends});
                    }
                    const meta_header = try header.toOwnedSlice();
                    defer allocator.free(meta_header);

                    var up_body = io_compat.AllocatingWriter.init(allocator);
                    defer up_body.deinit();
                    const up_writer = up_body.writer();
                    try up_writer.print("{s}\n\n", .{meta_header});
                    try up_writer.writeAll(
                        \\
                        \\-- Add your UP migration below:
                        \\-- Example: table users (id uuid primary_key)
                        \\
                    );
                    const up_content = try up_body.toOwnedSlice();
                    defer allocator.free(up_content);

                    var down_body = io_compat.AllocatingWriter.init(allocator);
                    defer down_body.deinit();
                    const down_writer = down_body.writer();
                    try down_writer.print("{s}\n\n", .{meta_header});
                    try down_writer.writeAll(
                        \\
                        \\-- Add your DOWN (rollback) migration below:
                        \\-- Example: drop users
                        \\
                    );
                    const down_content = try down_body.toOwnedSlice();
                    defer allocator.free(down_content);

                    var created_up = false;
                    errdefer if (created_up) {
                        std.Io.Dir.cwd().deleteFile(io_iface, up_path) catch {};
                    };

                    std.Io.Dir.cwd().writeFile(io_iface, .{
                        .sub_path = up_path,
                        .data = up_content,
                        .flags = .{
                            .truncate = false,
                            .exclusive = true,
                        },
                    }) catch |err| {
                        if (err == error.PathAlreadyExists) {
                            print("Migration file already exists: {s}\n", .{up_path});
                            return error.PathAlreadyExists;
                        }
                        return err;
                    };
                    created_up = true;

                    std.Io.Dir.cwd().writeFile(io_iface, .{
                        .sub_path = down_path,
                        .data = down_content,
                        .flags = .{
                            .truncate = false,
                            .exclusive = true,
                        },
                    }) catch |err| {
                        if (err == error.PathAlreadyExists) {
                            print("Migration file already exists: {s}\n", .{down_path});
                            return error.PathAlreadyExists;
                        }
                        return err;
                    };
                    created_up = false;

                    print("📝 Created migration files:\n", .{});
                    print("  ✓ {s}\n", .{up_path});
                    print("  ✓ {s}\n", .{down_path});
                },
                .shadow => |s| {
                    const resolved_url = try Cli.resolveDatabaseUrl(s.url);
                    try runMigrateShadow(allocator, s.schema_diff, resolved_url, s.live);
                },
                .promote => |url| {
                    const resolved_url = try Cli.resolveDatabaseUrl(url);
                    try runMigratePromote(allocator, resolved_url);
                },
                .abort => |url| {
                    const resolved_url = try Cli.resolveDatabaseUrl(url);
                    try runMigrateAbort(allocator, resolved_url);
                },
                .analyze => |a| {
                    const scanner_mod = @import("../analyzer/scanner.zig");
                    const impact_mod = @import("../analyzer/impact.zig");

                    const diff = parseSchemaDiffPath(a.schema_diff);
                    if (diff.old == null or diff.new == null) {
                        print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                        return;
                    }

                    if (!a.json) {
                        print("🔍 Migration Impact Analysis\n\n", .{});
                        print("  Diff: {s} → {s}\n", .{ diff.old.?, diff.new.? });
                        print("  Codebase: {s}\n\n", .{a.codebase});
                    }

                    const old_content = readFileAlloc(allocator, diff.old.?, 8 * 1024 * 1024) catch |err| {
                        print("Error reading old schema: {}\n", .{err});
                        return err;
                    };
                    defer allocator.free(old_content);

                    const new_content = readFileAlloc(allocator, diff.new.?, 8 * 1024 * 1024) catch |err| {
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
                    defer migrate_support.deinitMigrationCmds(allocator, &cmds);

                    if (cmds.items.len == 0) {
                        print("✅ No schema changes detected\n", .{});
                        return;
                    }

                    var scanner = scanner_mod.CodebaseScanner.init(allocator);
                    defer scanner.deinit();

                    scanner.scan(a.codebase) catch |err| {
                        print("Error scanning codebase: {}\n", .{err});
                        return err;
                    };

                    var impact = impact_mod.MigrationImpact.analyze(
                        allocator,
                        cmds.items,
                        scanner.refs.items,
                    ) catch |err| {
                        print("Error analyzing migration impact: {}\n", .{err});
                        return err;
                    };
                    defer impact.deinit();

                    const report = impact.report(allocator) catch |err| {
                        print("Error rendering report: {}\n", .{err});
                        return err;
                    };
                    defer allocator.free(report);

                    if (a.json) {
                        const payload = .{
                            .schema_diff = a.schema_diff,
                            .codebase = a.codebase,
                            .operations = cmds.items.len,
                            .query_references_scanned = scanner.refs.items.len,
                            .safe_to_run = impact.safe_to_run,
                            .report = report,
                        };
                        var encoded = io_compat.AllocatingWriter.init(allocator);
                        defer encoded.deinit();
                        try std.json.Stringify.value(payload, .{}, encoded.writer());
                        const json_payload = try encoded.toOwnedSlice();
                        defer allocator.free(json_payload);
                        print("{s}\n", .{json_payload});
                    } else {
                        print("  Operations: {d}\n", .{cmds.items.len});
                        print("  Query references scanned: {d}\n\n", .{scanner.refs.items.len});
                        print("{s}", .{report});
                    }

                    if (a.ci and !impact.safe_to_run) {
                        print("::error::Migration impact check failed for {s}\n", .{a.schema_diff});
                    }

                    if (!impact.safe_to_run) {
                        return error.MigrationUnsafe;
                    }
                },
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

        /// Parse schema diff path (old.qail:new.qail)
        fn parseSchemaDiffPath(path: []const u8) struct { old: ?[]const u8, new: ?[]const u8 } {
            if (std.mem.indexOf(u8, path, ":")) |idx| {
                return .{
                    .old = path[0..idx],
                    .new = path[idx + 1 ..],
                };
            }
            return .{ .old = null, .new = null };
        }

        test "collect up migrations keeps legacy subdir history and rejects sql" {
            const allocator = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const old_cwd = try std.posix.getcwd(&cwd_buf);
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            const root = try tmp.dir.realPath(std.testing.io, ".", &root_buf);
            try std.posix.chdir(root);
            defer std.posix.chdir(old_cwd) catch {};

            const io_iface = io_compat.runtimeIo();
            try std.Io.Dir.cwd().createDirPath(io_iface, "migrations/001_legacy_core");
            try std.Io.Dir.cwd().createDirPath(io_iface, "migrations/ignored_notes");
            try std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = "migrations/001_legacy_core/up.qail",
                .data = "get::users\n",
            });
            try std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = "migrations/002_flat_core.up.qail",
                .data = "get::orders\n",
            });

            var found = try collectUpMigrationFiles(allocator);
            defer deinitMigrationFileEntries(allocator, &found);

            try std.testing.expectEqual(@as(usize, 2), found.items.len);
            try std.testing.expectEqualStrings("001_legacy_core", found.items[0].version);
            try std.testing.expectEqualStrings("migrations/001_legacy_core/up.qail", found.items[0].path);
            try std.testing.expectEqualStrings("002_flat_core", found.items[1].version);
            try std.testing.expectEqualStrings("migrations/002_flat_core.up.qail", found.items[1].path);

            try std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = "migrations/001_legacy_core/up.sql",
                .data = "SELECT 1;\n",
            });
            try std.testing.expectError(error.UnsupportedSqlMigrationFile, collectUpMigrationFiles(allocator));
        }

        test "migration down path prefers flat file and falls back to legacy subdir" {
            const allocator = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const old_cwd = try std.posix.getcwd(&cwd_buf);
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            const root = try tmp.dir.realPath(std.testing.io, ".", &root_buf);
            try std.posix.chdir(root);
            defer std.posix.chdir(old_cwd) catch {};

            const io_iface = io_compat.runtimeIo();
            try std.Io.Dir.cwd().createDirPath(io_iface, "migrations/001_legacy_core");
            try std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = "migrations/001_legacy_core/down.qail",
                .data = "del::users\n",
            });
            const legacy = try migrationDownPath(allocator, "001_legacy_core");
            defer allocator.free(legacy);
            try std.testing.expectEqualStrings("migrations/001_legacy_core/down.qail", legacy);

            try std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = "migrations/001_legacy_core.down.qail",
                .data = "del::users\n",
            });
            const flat = try migrationDownPath(allocator, "001_legacy_core");
            defer allocator.free(flat);
            try std.testing.expectEqualStrings("migrations/001_legacy_core.down.qail", flat);
        }
    };
}

test "migration phase fallback matches exact filename tokens" {
    try std.testing.expect(pathContainsMigrationPhaseToken(
        "migrations/20260101010101_contract_cleanup.up.qail",
        "contract",
    ));
    try std.testing.expect(pathContainsMigrationPhaseToken(
        "migrations/20260101010101-contract-cleanup.up.qail",
        "contract",
    ));
    try std.testing.expect(pathContainsMigrationPhaseToken(
        "migrations/20260101010101.backfill.products.up.qail",
        "backfill",
    ));

    try std.testing.expect(!pathContainsMigrationPhaseToken(
        "migrations/20260101010101_add_tenant_contracts.up.qail",
        "contract",
    ));
    try std.testing.expect(!pathContainsMigrationPhaseToken(
        "migrations/20260101010101_backfilled_status.up.qail",
        "backfill",
    ));
}

test "migration up filenames reject malformed logical names" {
    const valid = try parseMigrationUpFileName("20260101010101_create_users.up.qail");
    try std.testing.expectEqualStrings("20260101010101_create_users", valid.stem);
    try std.testing.expectEqualStrings("create_users", valid.name);

    const dotted = try parseMigrationUpFileName("20260101010101.contract.users.up.qail");
    try std.testing.expectEqualStrings("20260101010101.contract.users", dotted.name);

    try std.testing.expectError(error.NotUpMigrationFile, parseMigrationUpFileName("notes.txt"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName(".up.qail"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName("..up.qail"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName("-001_init.up.qail"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName("_init.up.qail"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName("001_.up.qail"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName("001_.hidden.up.qail"));
    try std.testing.expectError(error.InvalidMigrationFileName, parseMigrationUpFileName("001 add users.up.qail"));
}
