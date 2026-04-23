const std = @import("std");

pub fn make(comptime Cli: type) type {
    const Allocator = std.mem.Allocator;
    const QailCmd = @import("../ast/cmd.zig").QailCmd;
    const Expr = @import("../ast/expr.zig").Expr;
    const io_compat = @import("../runtime/io.zig");
    const process_compat = @import("../runtime/process.zig");
    const PgDriver = @import("../driver/driver.zig").PgDriver;
    const print = std.debug.print;

    return struct {
        pub const MIGRATION_LOCK_CLASS_ID: i32 = 20_801;
        pub const MIGRATION_LOCK_OBJECT_SEED: i32 = 19_783;
        pub const MIGRATION_LOCK_WAIT_POLL_MS: u64 = 500;

        fn envDatabaseUrl() ?[]const u8 {
            return process_compat.getEnvVarOwned(std.heap.page_allocator, "QAIL_DATABASE_URL") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => process_compat.getEnvVarOwned(std.heap.page_allocator, "DATABASE_URL") catch |err2| switch (err2) {
                    error.EnvironmentVariableNotFound => null,
                    else => null,
                },
                else => null,
            };
        }

        pub fn resolveDatabaseUrl(url: []const u8) ![]const u8 {
            const trimmed = std.mem.trim(u8, url, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
            if (envDatabaseUrl()) |env_url| return env_url;
            print("Error: database URL required. Pass --url or set QAIL_DATABASE_URL/DATABASE_URL.\n", .{});
            return error.MissingArgument;
        }

        pub fn scopedMigrationLockObjectId(scope: ?[]const u8) i32 {
            const raw_scope = scope orelse return MIGRATION_LOCK_OBJECT_SEED;
            const normalized = std.mem.trim(u8, raw_scope, " \t\r\n");
            if (normalized.len == 0) return MIGRATION_LOCK_OBJECT_SEED;

            // Stable FNV-1a hash with a fixed seed xor, mirroring qail.rs semantics.
            var hash: u32 = 0x811c9dc5;
            for (normalized) |byte| {
                hash ^= @as(u32, std.ascii.toLower(byte));
                hash *%= 0x01000193;
            }

            const mixed = hash ^ @as(u32, @intCast(MIGRATION_LOCK_OBJECT_SEED));
            return @as(i32, @intCast(mixed & 0x7fff_ffff));
        }

        pub fn migrationLockObjectIdForUrl(allocator: Allocator, url: []const u8) i32 {
            const driver_mod = @import("../driver/mod.zig");

            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            const parsed = driver_mod.connect_url.parseConnectionUrl(arena_state.allocator(), url) catch return MIGRATION_LOCK_OBJECT_SEED;
            return scopedMigrationLockObjectId(parsed.database);
        }

        fn tryAcquireMigrationLock(
            allocator: Allocator,
            pg: *PgDriver,
            lock_object_id: i32,
        ) !bool {
            const lock_source = try std.fmt.allocPrint(
                allocator,
                "pg_try_advisory_lock({d}, {d})",
                .{ MIGRATION_LOCK_CLASS_ID, lock_object_id },
            );
            defer allocator.free(lock_source);

            const lock_cmd = QailCmd.get(lock_source)
                .select(&.{
                    Expr.col("pg_try_advisory_lock"),
                }).limit(1);

            const rows = try pg.fetchAll(&lock_cmd);
            defer Cli.deinitFetchedRows(allocator, rows);
            if (rows.len == 0) return false;
            return rows[0].getBool(0) orelse false;
        }

        pub fn acquireMigrationLock(
            allocator: Allocator,
            pg: *PgDriver,
            operation: []const u8,
            url: []const u8,
            wait_for_lock: bool,
            lock_timeout_secs: ?u64,
        ) !void {
            const should_wait = wait_for_lock or lock_timeout_secs != null;
            const lock_object_id = migrationLockObjectIdForUrl(allocator, url);

            const deadline_ms: ?u64 = if (lock_timeout_secs) |timeout_secs| blk: {
                const timeout_ms = std.math.mul(u64, timeout_secs, 1000) catch std.math.maxInt(u64);
                const now_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds()));
                break :blk std.math.add(u64, now_ms, timeout_ms) catch std.math.maxInt(u64);
            } else null;

            if (should_wait) {
                print("  ⏳ Waiting for migration lock...\n", .{});
                while (true) {
                    if (try tryAcquireMigrationLock(allocator, pg, lock_object_id)) {
                        print("  ✓ Acquired migration lock\n", .{});
                        return;
                    }

                    if (deadline_ms) |limit_ms| {
                        const now_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds()));
                        if (now_ms >= limit_ms) {
                            print(
                                "Error: timed out waiting for migration lock for '{s}' after {d} second(s).\n",
                                .{ operation, lock_timeout_secs orelse 0 },
                            );
                            return error.MigrationLockTimeout;
                        }
                    }

                    std.Io.sleep(
                        io_compat.runtimeIo(),
                        std.Io.Duration.fromMilliseconds(MIGRATION_LOCK_WAIT_POLL_MS),
                        .awake,
                    ) catch {};
                }
            }

            if (try tryAcquireMigrationLock(allocator, pg, lock_object_id)) {
                print("  ✓ Acquired migration lock\n", .{});
                return;
            }

            print(
                "Error: another migration operation is already running for '{s}'. Re-run with --wait-for-lock or --lock-timeout-secs.\n",
                .{operation},
            );
            return error.MigrationLockBusy;
        }
    };
}
