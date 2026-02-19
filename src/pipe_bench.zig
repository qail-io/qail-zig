// QAIL Zig Pipeline + Pool Benchmark
//
// Measures 3 modes against live PostgreSQL:
//   M1: Single query (sequential fetchOne)
//   M2: Pipeline (pipelineAstFast — AST batch, 1 conn)
//   M3: Pool + Pipeline (parallel AST batches across N connections)
//
// Uses pipelineAstFast which transpiles AST → SQL per query —
// matches Rust's pipeline_ast_cached for fair comparison.
//
// Run: zig build -Doptimize=ReleaseFast && ./zig-out/bin/pipe_bench

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const Connection = qail.driver.Connection;
const Pipeline = qail.driver.Pipeline;
const PgPool = qail.driver.PgPool;
const PgDriver = qail.driver.PgDriver;

const TOTAL_QUERIES: usize = 100_000;
const BATCH_SIZE: usize = 500;
const POOL_SIZE: usize = 10;
const WARMUP: usize = 200;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  qail-zig — Pipeline + Pool Benchmark                ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Queries:    {d:>10}                              ║\n", .{TOTAL_QUERIES});
    std.debug.print("║  Batch size: {d:>10}                              ║\n", .{BATCH_SIZE});
    std.debug.print("║  Pool size:  {d:>10}                              ║\n", .{POOL_SIZE});
    std.debug.print("║  Host:       127.0.0.1:5432                          ║\n", .{});
    std.debug.print("║  Database:   qail_e2e_test                           ║\n", .{});
    std.debug.print("║  Mode:       Full I/O (TCP round-trip, blocking)     ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // ── Setup: seed tables ───────────────────────────────────
    std.debug.print("  Setting up benchmark tables...\n", .{});

    var setup_drv = try PgDriver.connect(allocator, "127.0.0.1", 5432, "postgres", "qail_e2e_test");
    defer setup_drv.deinit();

    _ = setup_drv.executeRaw("DROP TABLE IF EXISTS pipe_orders") catch {};
    _ = setup_drv.executeRaw("DROP TABLE IF EXISTS pipe_users") catch {};
    _ = try setup_drv.executeRaw(
        "CREATE TABLE pipe_users (" ++
            "id SERIAL PRIMARY KEY, " ++
            "name TEXT NOT NULL, " ++
            "email TEXT NOT NULL, " ++
            "active BOOLEAN DEFAULT true)",
    );
    _ = try setup_drv.executeRaw(
        "CREATE TABLE pipe_orders (" ++
            "id SERIAL PRIMARY KEY, " ++
            "user_id INTEGER REFERENCES pipe_users(id), " ++
            "product TEXT NOT NULL, " ++
            "amount NUMERIC(10,2) NOT NULL, " ++
            "status TEXT DEFAULT 'pending')",
    );

    // Seed 100 users
    for (1..101) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO pipe_users (name, email, active) VALUES ('User {d}', 'u{d}@t.com', {s})", .{ i, i, if (i % 3 != 0) "true" else "false" });
        _ = setup_drv.executeRaw(sql) catch {};
    }

    // Seed 500 orders
    const statuses = [_][]const u8{ "pending", "completed", "shipped", "cancelled", "refunded" };
    for (1..101) |uid| {
        for (0..5) |j| {
            var buf: [256]u8 = undefined;
            const sql = try std.fmt.bufPrint(&buf, "INSERT INTO pipe_orders (user_id, product, amount, status) VALUES ({d}, 'P{d}-{d}', {d}.99, '{s}')", .{ uid, uid, j, (j + 1) * 10, statuses[j % 5] });
            _ = setup_drv.executeRaw(sql) catch {};
        }
    }

    _ = setup_drv.executeRaw("CREATE INDEX IF NOT EXISTS idx_pu_active ON pipe_users (active)") catch {};
    _ = setup_drv.executeRaw("CREATE INDEX IF NOT EXISTS idx_po_status ON pipe_orders (status)") catch {};
    _ = setup_drv.executeRaw("CREATE INDEX IF NOT EXISTS idx_po_user ON pipe_orders (user_id)") catch {};

    std.debug.print("  Seeded: 100 users, 500 orders (indexed)\n\n", .{});
    std.debug.print("  ── Mode Comparison ──\n\n", .{});

    // ═══════════════════════════════════════════════════════════
    // M1: Single query — sequential fetchOne
    // ═══════════════════════════════════════════════════════════
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var drv = try PgDriver.connect(a, "127.0.0.1", 5432, "postgres", "qail_e2e_test");

        const cmd = QailCmd.get("pipe_users")
            .select(&.{ Expr.col("id"), Expr.col("name"), Expr.col("email") })
            .where(&.{
                .{ .condition = .{ .column = "active", .op = .eq, .value = .{ .bool = true } } },
            })
            .limit(10);

        // Warmup
        for (0..WARMUP) |_| {
            const maybe_row = drv.fetchOne(&cmd) catch continue;
            if (maybe_row) |row| {
                var r = row;
                r.deinit();
            }
        }

        const start = std.time.Instant.now() catch unreachable;
        for (0..TOTAL_QUERIES) |_| {
            const maybe_row = drv.fetchOne(&cmd) catch continue;
            if (maybe_row) |row| {
                var r = row;
                std.mem.doNotOptimizeAway(&r);
                r.deinit();
            }
        }
        const end = std.time.Instant.now() catch unreachable;
        const elapsed_ns = end.since(start);
        const us_per = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(TOTAL_QUERIES))) / 1000.0;
        const qps = @as(f64, @floatFromInt(TOTAL_QUERIES)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
        std.debug.print("  {s:<32} {d:>7.1} μs/q  {d:>10.0} qps\n", .{ "M1 — Single (fetchOne)", us_per, qps });
    }

    // ═══════════════════════════════════════════════════════════
    // M2: Pipeline — pipelineAstFast (AST batch, 1 conn)
    //     Transpiles AST→SQL per query — matches Rust pipeline_ast_cached
    // ═══════════════════════════════════════════════════════════
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var conn = try Connection.connect(a, "127.0.0.1", 5432);
        try conn.startup("postgres", "qail_e2e_test", null);

        var pipe = Pipeline.init(&conn, a);
        defer pipe.deinit();

        // Build batch of AST commands
        var cmds = try a.alloc(*const QailCmd, BATCH_SIZE);
        for (0..BATCH_SIZE) |i| {
            const cmd_ptr = try a.create(QailCmd);
            cmd_ptr.* = QailCmd.get("pipe_users")
                .select(&.{ Expr.col("id"), Expr.col("name"), Expr.col("email") })
                .where(&.{
                    .{ .condition = .{ .column = "active", .op = .eq, .value = .{ .bool = i % 2 == 0 } } },
                })
                .limit(10);
            cmds[i] = cmd_ptr;
        }

        const batches = TOTAL_QUERIES / BATCH_SIZE;

        // Warmup
        _ = pipe.pipelineAstFast(cmds) catch |e| {
            std.debug.print("  M2 warmup error: {}\n", .{e});
        };

        const start = std.time.Instant.now() catch unreachable;
        var total: usize = 0;
        for (0..batches) |_| {
            const n = pipe.pipelineAstFast(cmds) catch continue;
            total += n;
        }
        const end = std.time.Instant.now() catch unreachable;
        const elapsed_ns = end.since(start);
        if (total > 0) {
            const us_per = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total))) / 1000.0;
            const qps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
            std.debug.print("  {s:<32} {d:>7.1} μs/q  {d:>10.0} qps\n", .{ "M2 — Pipeline (AST, 1 conn)", us_per, qps });
        } else {
            std.debug.print("  M2 — Pipeline: 0 completions (error)\n", .{});
        }
    }

    // ═══════════════════════════════════════════════════════════
    // M3: Pool + Pipeline — parallel AST batches across N connections
    // ═══════════════════════════════════════════════════════════
    {
        var pool = try PgPool.init(allocator, .{
            .host = "127.0.0.1",
            .port = 5432,
            .user = "postgres",
            .database = "qail_e2e_test",
            .max_connections = POOL_SIZE,
            .min_connections = POOL_SIZE,
        });
        defer pool.deinit();

        const batches_per_worker = TOTAL_QUERIES / BATCH_SIZE / POOL_SIZE;

        var threads: [POOL_SIZE]std.Thread = undefined;
        var counter = std.atomic.Value(usize).init(0);

        const start = std.time.Instant.now() catch unreachable;

        for (0..POOL_SIZE) |t| {
            threads[t] = try std.Thread.spawn(.{}, workerFn, .{
                &pool,
                &counter,
                batches_per_worker,
            });
        }

        for (0..POOL_SIZE) |t| {
            threads[t].join();
        }

        const end = std.time.Instant.now() catch unreachable;
        const total_done = counter.load(.acquire);
        const elapsed_ns = end.since(start);
        if (total_done > 0) {
            const us_per = (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_done))) / 1000.0;
            const qps = @as(f64, @floatFromInt(total_done)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "M3 — Pool+Pipe ({d} conn)", .{POOL_SIZE}) catch "M3 — Pool+Pipe";
            std.debug.print("  {s:<32} {d:>7.1} μs/q  {d:>10.0} qps\n", .{ label, us_per, qps });
        } else {
            std.debug.print("  M3: 0 completions (pool/pipeline error)\n", .{});
        }
    }

    // ── Cleanup ──────────────────────────────────────────────
    std.debug.print("\n  Cleaning up...", .{});
    _ = setup_drv.executeRaw("DROP TABLE IF EXISTS pipe_orders") catch {};
    _ = setup_drv.executeRaw("DROP TABLE IF EXISTS pipe_users") catch {};
    std.debug.print(" done\n\n", .{});
}

fn workerFn(pool: *PgPool, counter: *std.atomic.Value(usize), batches: usize) void {
    const a = std.heap.page_allocator;

    var pooled_conn = pool.acquire() catch return;
    defer pooled_conn.release();
    const conn = pooled_conn.get();

    var pipe = Pipeline.init(conn, a);
    defer pipe.deinit();

    // Build batch of AST commands (same as M2)
    var cmds: [BATCH_SIZE]*const QailCmd = undefined;
    for (0..BATCH_SIZE) |i| {
        const cmd_ptr = a.create(QailCmd) catch return;
        cmd_ptr.* = QailCmd.get("pipe_users")
            .select(&.{ Expr.col("id"), Expr.col("name"), Expr.col("email") })
            .where(&.{
                .{ .condition = .{ .column = "active", .op = .eq, .value = .{ .bool = i % 2 == 0 } } },
            })
            .limit(10);
        cmds[i] = cmd_ptr;
    }

    for (0..batches) |_| {
        const n = pipe.pipelineAstFast(&cmds) catch continue;
        _ = counter.fetchAdd(n, .monotonic);
    }
}
