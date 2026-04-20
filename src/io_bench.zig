// ─────────────────────────────────────────────────────────────
// qail-zig Real Database Query Benchmark
//
// Measures ACTUAL query throughput against a live PostgreSQL.
// This is the real deal — TCP round-trips, Parse/Bind/Execute,
// DataRow decoding, the full driver stack.
//
// Uses ArenaAllocator to avoid per-query mmap/munmap overhead.
//
// Requires: PostgreSQL on 127.0.0.1:5432, trust auth
// ─────────────────────────────────────────────────────────────

const std = @import("std");
const qail = @import("qail");
const time = qail.compat.time;

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const Assignment = qail.ast.Assignment;
const PgDriver = qail.driver.PgDriver;

const READ_ITERS: u64 = 1_000_000;
const WRITE_ITERS: u64 = 100_000;
const WARMUP: u64 = 1_000;

pub fn main() !void {
    // Use ArenaAllocator backed by page_allocator.
    // Arena amortizes allocation cost — no mmap per alloc.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  qail-zig — Real Database Query Benchmark            ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Read iters: {d:>10}                              ║\n", .{READ_ITERS});
    std.debug.print("║  Write iters:{d:>10}                              ║\n", .{WRITE_ITERS});
    std.debug.print("║  Host:       127.0.0.1:5432                          ║\n", .{});
    std.debug.print("║  Database:   qail_e2e_test                           ║\n", .{});
    std.debug.print("║  Mode:       Full I/O (TCP round-trip)               ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // ── Connect ──────────────────────────────────────────────
    var driver = PgDriver.connect(allocator, "127.0.0.1", 5432, "postgres", "qail_e2e_test") catch |err| {
        std.debug.print("  FATAL: Cannot connect: {}\n\n", .{err});
        return;
    };
    defer driver.deinit();
    std.debug.print("  Connected (PID: {d})\n\n", .{driver.backendProcessId()});

    // ── Setup: seed tables ───────────────────────────────────
    std.debug.print("  Setting up benchmark tables...\n", .{});

    {
        const drop_orders = QailCmd.drop("bench_orders");
        const drop_users = QailCmd.drop("bench_users");
        _ = driver.execute(&drop_orders) catch {};
        _ = driver.execute(&drop_users) catch {};
    }
    {
        const user_cols = [_]Expr{
            Expr.defWithConstraints("id", "SERIAL", &.{.primary_key}),
            Expr.defWithConstraints("name", "TEXT", &.{.not_null}),
            Expr.defWithConstraints("email", "TEXT", &.{.not_null}),
            Expr.defWithConstraints("active", "BOOLEAN", &.{.{ .default = "true" }}),
        };
        const create_users = QailCmd.make("bench_users").select(&user_cols);
        _ = try driver.execute(&create_users);
    }
    {
        const order_cols = [_]Expr{
            Expr.defWithConstraints("id", "SERIAL", &.{.primary_key}),
            Expr.defWithConstraints("user_id", "INTEGER", &.{.{ .references = "bench_users(id)" }}),
            Expr.defWithConstraints("product", "TEXT", &.{.not_null}),
            Expr.defWithConstraints("amount", "NUMERIC(10,2)", &.{.not_null}),
            Expr.defWithConstraints("status", "TEXT", &.{.{ .default = "'pending'" }}),
        };
        const create_orders = QailCmd.make("bench_orders").select(&order_cols);
        _ = try driver.execute(&create_orders);
    }

    // Seed 100 users
    for (1..101) |i| {
        var buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "User {d}", .{i}) catch continue;

        var email_buf: [64]u8 = undefined;
        const email = std.fmt.bufPrint(&email_buf, "user{d}@test.com", .{i}) catch continue;
        const assigns = [_]Assignment{
            .{ .column = "name", .value = .{ .string = name } },
            .{ .column = "email", .value = .{ .string = email } },
            .{ .column = "active", .value = .{ .bool = i % 3 != 0 } },
        };
        const cmd = QailCmd.add("bench_users").values(&assigns);
        _ = driver.execute(&cmd) catch {};
    }

    // Seed 500 orders
    for (1..101) |uid| {
        for (0..5) |j| {
            const statuses = [_][]const u8{ "pending", "completed", "shipped", "cancelled", "refunded" };
            var buf: [256]u8 = undefined;
            const product = std.fmt.bufPrint(&buf, "Product {d}-{d}", .{ uid, j }) catch continue;
            const amount = @as(f64, @floatFromInt((j + 1) * 10)) + 0.99;
            const assigns = [_]Assignment{
                .{ .column = "user_id", .value = .{ .int = @as(i64, @intCast(uid)) } },
                .{ .column = "product", .value = .{ .string = product } },
                .{ .column = "amount", .value = .{ .float = amount } },
                .{ .column = "status", .value = .{ .string = statuses[j % 5] } },
            };
            const cmd = QailCmd.add("bench_orders").values(&assigns);
            _ = driver.execute(&cmd) catch {};
        }
    }

    // Add indexes for realistic performance
    {
        const idx_users_active = QailCmd.createIndex("bench_users").withIndex(.{
            .name = "idx_users_active",
            .table = "bench_users",
            .columns = &.{"active"},
            .unique = false,
        });
        const idx_orders_status = QailCmd.createIndex("bench_orders").withIndex(.{
            .name = "idx_orders_status",
            .table = "bench_orders",
            .columns = &.{"status"},
            .unique = false,
        });
        const idx_orders_user = QailCmd.createIndex("bench_orders").withIndex(.{
            .name = "idx_orders_user",
            .table = "bench_orders",
            .columns = &.{"user_id"},
            .unique = false,
        });
        _ = driver.execute(&idx_users_active) catch {};
        _ = driver.execute(&idx_orders_status) catch {};
        _ = driver.execute(&idx_orders_user) catch {};
    }

    std.debug.print("  Seeded: 100 users, 500 orders (indexed)\n\n", .{});

    var total_ops: u64 = 0;
    std.debug.print("  ── Real I/O Query Benchmarks ──\n\n", .{});

    // ── T1: SELECT LIMIT 1 (simplest) ────────────────────────
    {
        const cmd = QailCmd.get("bench_users")
            .select(&.{ Expr.col("id"), Expr.col("name") })
            .limit(1);
        total_ops += benchFetchOne(&driver, "T1 — SELECT LIMIT 1", &cmd);
    }

    // ── T2: SELECT WHERE (filtered read) ─────────────────────
    {
        const cmd = QailCmd.get("bench_users")
            .select(&.{ Expr.col("id"), Expr.col("name"), Expr.col("email") })
            .where(&.{
                .{ .condition = .{ .column = "active", .op = .eq, .value = .{ .bool = true } } },
            })
            .limit(10);
        total_ops += benchFetchOne(&driver, "T2 — SELECT WHERE", &cmd);
    }

    // ── T3: ORDER BY + LIMIT ─────────────────────────────────
    {
        const cmd = QailCmd.get("bench_users")
            .select(&.{ Expr.col("id"), Expr.col("name") })
            .orderBy(&.{.{ .column = "name", .order = .asc }})
            .limit(5);
        total_ops += benchFetchOne(&driver, "T3 — ORDER BY LIMIT", &cmd);
    }

    // ── T4: INSERT + DELETE write cycle ──────────────────────
    {
        total_ops += benchWriteCycle(&driver, "T4 — INSERT+DELETE");
    }

    // ── T5: UPDATE WHERE ─────────────────────────────────────
    {
        total_ops += benchUpdate(&driver, "T5 — UPDATE WHERE");
    }

    // ── T6: Complex JOIN ─────────────────────────────────────
    {
        const cmd = QailCmd.get("bench_orders")
            .select(&.{
                Expr.col("bench_users.name"),
                Expr.col("bench_orders.product"),
                Expr.col("bench_orders.amount"),
            })
            .join(&.{.{
                .table = "bench_users",
                .on_left = "bench_orders.user_id",
                .on_right = "bench_users.id",
                .kind = .inner,
            }})
            .where(&.{
                .{ .condition = .{ .column = "bench_orders.status", .op = .eq, .value = .{ .string = "completed" } } },
            })
            .orderBy(&.{.{ .column = "bench_orders.amount", .order = .desc }})
            .limit(10);
        total_ops += benchFetchOne(&driver, "T6 — JOIN+WHERE+ORDER", &cmd);
    }

    // ── Cleanup ──────────────────────────────────────────────
    std.debug.print("\n  Cleaning up...", .{});
    {
        const drop_orders = QailCmd.drop("bench_orders");
        const drop_users = QailCmd.drop("bench_users");
        _ = driver.execute(&drop_orders) catch {};
        _ = driver.execute(&drop_users) catch {};
    }
    std.debug.print(" done\n", .{});

    std.debug.print("\n────────────────────────────────────────────────────────\n", .{});
    std.debug.print("  Total operations: {d}\n", .{total_ops});
    std.debug.print("────────────────────────────────────────────────────────\n\n", .{});
}

/// Benchmark a fetchOne query — lightest allocation path.
/// fetchOne returns !?PgRow (error union of optional).
fn benchFetchOne(driver: *PgDriver, label: []const u8, cmd: *const QailCmd) u64 {
    // Warmup
    const iters = READ_ITERS;
    for (0..WARMUP) |_| {
        const maybe_row = driver.fetchOne(cmd) catch continue;
        if (maybe_row) |row| {
            var r = row;
            r.deinit();
        }
    }

    const start = time.now() catch unreachable;

    var row_count: u64 = 0;
    for (0..iters) |_| {
        const maybe_row = driver.fetchOne(cmd) catch continue;
        if (maybe_row) |row| {
            var r = row;
            std.mem.doNotOptimizeAway(&r);
            row_count += 1;
            r.deinit();
        }
    }

    const end = time.now() catch unreachable;
    const elapsed_ns = time.since(end, start);
    const us_per = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iters))) / 1000.0;
    const qps = @as(f64, @floatFromInt(iters)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("  {s:<24} {d:>7.1} μs/q  {d:>10.0} qps\n", .{ label, us_per, qps });
    return iters;
}

/// Benchmark INSERT + DELETE cycle (write throughput)
fn benchWriteCycle(driver: *PgDriver, label: []const u8) u64 {
    const insert_assigns = [_]Assignment{
        .{ .column = "name", .value = .{ .string = "_tmp" } },
        .{ .column = "email", .value = .{ .string = "_tmp@t.com" } },
    };
    const insert_cmd = QailCmd.add("bench_users").values(&insert_assigns);
    const delete_cmd = QailCmd.del("bench_users").where(&.{
        .{ .condition = .{ .column = "name", .op = .eq, .value = .{ .string = "_tmp" } } },
    });

    // Warmup
    for (0..100) |_| {
        _ = driver.execute(&insert_cmd) catch {};
        _ = driver.execute(&delete_cmd) catch {};
    }

    const start = time.now() catch unreachable;

    for (0..WRITE_ITERS) |_| {
        _ = driver.execute(&insert_cmd) catch {};
        _ = driver.execute(&delete_cmd) catch {};
    }

    const end = time.now() catch unreachable;
    const elapsed_ns = time.since(end, start);
    const total_ops = WRITE_ITERS * 2;
    const us_per = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(WRITE_ITERS))) / 1000.0;
    const qps = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("  {s:<24} {d:>7.1} μs/cyc {d:>10.0} ops  (INS+DEL)\n", .{ label, us_per, qps });
    return total_ops;
}

/// Benchmark UPDATE throughput
fn benchUpdate(driver: *PgDriver, label: []const u8) u64 {
    const set_true = [_]Assignment{
        .{ .column = "active", .value = .{ .bool = true } },
    };
    const set_false = [_]Assignment{
        .{ .column = "active", .value = .{ .bool = false } },
    };
    const where_id = [_]qail.ast.WhereClause{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = 1 } } },
    };
    const update_true = QailCmd.set("bench_users").values(&set_true).where(&where_id);
    const update_false = QailCmd.set("bench_users").values(&set_false).where(&where_id);

    // Warmup
    for (0..100) |_| {
        _ = driver.execute(&update_true) catch {};
    }

    const start = time.now() catch unreachable;

    // Alternate between two static SQL strings to avoid branch prediction bias
    for (0..WRITE_ITERS) |i| {
        if (i % 2 == 0) {
            _ = driver.execute(&update_true) catch {};
        } else {
            _ = driver.execute(&update_false) catch {};
        }
    }

    const end = time.now() catch unreachable;
    const elapsed_ns = time.since(end, start);
    const us_per = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(WRITE_ITERS))) / 1000.0;
    const qps = @as(f64, @floatFromInt(WRITE_ITERS)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("  {s:<24} {d:>7.1} μs/q  {d:>10.0} qps\n", .{ label, us_per, qps });
    return WRITE_ITERS;
}
