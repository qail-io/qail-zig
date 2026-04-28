// QAIL Zig Pool Benchmark - Fair Comparison with Rust
//
// Uses PgPool with multiple threads and the public AST-native Pipeline API.
// Run: zig build pool

const std = @import("std");
const qail = @import("qail");
const driver = qail.driver;

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const WhereClause = qail.ast.cmd.WhereClause;
const PgPool = driver.pool.PgPool;
const Pipeline = driver.pipeline.Pipeline;

const TOTAL_QUERIES: usize = 150_000_000;
const NUM_WORKERS: usize = 10;
const POOL_SIZE: usize = 10;
const QUERIES_PER_BATCH: usize = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print(
        \\╔═══════════════════════════════════════════════════════════╗
        \\║  QAIL Zig Pool Benchmark - Fair Comparison with Rust      ║
        \\╠═══════════════════════════════════════════════════════════╣
        \\║  Query: SELECT id, name FROM harbors WHERE id <= $1       ║
        \\║  Total:    150,000,000 queries                            ║
        \\║  Workers:  10 threads                                     ║
        \\║  Pool:     10 connections                                 ║
        \\║  Batch:    100 queries per pipeline                       ║
        \\╚═══════════════════════════════════════════════════════════╝
        \\
        \\
    , .{});

    std.debug.print("🔌 Initializing connection pool...\n", .{});

    var pool = try PgPool.init(allocator, .{
        .host = "127.0.0.1",
        .port = 5432,
        .user = "orion",
        .database = "postgres",
        .max_connections = POOL_SIZE,
        .min_connections = POOL_SIZE,
    });
    defer pool.deinit();

    std.debug.print("✅ Pool initialized with {} connections\n\n", .{POOL_SIZE});

    const batches_per_worker = TOTAL_QUERIES / NUM_WORKERS / QUERIES_PER_BATCH;
    var counter = std.atomic.Value(usize).init(0);
    var parsed_counter = std.atomic.Value(usize).init(0);

    const start = nowMillis();

    var threads: [NUM_WORKERS]std.Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{ &pool, &counter, &parsed_counter, batches_per_worker, allocator });
    }

    const progress_thread = try std.Thread.spawn(.{}, progressFn, .{ &counter, start });

    for (&threads) |*thread| {
        thread.join();
    }

    const end = nowMillis();
    const elapsed_ms = end - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const total = counter.load(.acquire);
    const parsed = parsed_counter.load(.acquire);
    const qps = @as(f64, @floatFromInt(total)) / elapsed_s;

    counter.store(TOTAL_QUERIES + 1, .release);
    progress_thread.join();

    std.debug.print(
        \\
        \\📈 FINAL RESULTS:
        \\┌─────────────────────────────────────────────────┐
        \\│ QAIL ZIG POOL BENCHMARK (AST Pipeline)          │
        \\├─────────────────────────────────────────────────┤
        \\│ Total Time:                       {d:.1}s │
        \\│ Queries/Second:                 {d:.0} │
        \\│ Responses Parsed:              {} │
        \\│ Workers:                              {} │
        \\│ Pool Size:                            {} │
        \\│ Queries Completed:             {} │
        \\└─────────────────────────────────────────────────┘
        \\
    , .{ elapsed_s, qps, parsed, NUM_WORKERS, POOL_SIZE, total });
}

fn workerFn(pool: *PgPool, counter: *std.atomic.Value(usize), parsed_counter: *std.atomic.Value(usize), batches: usize, allocator: std.mem.Allocator) void {
    var pooled_conn = pool.acquire() catch {
        std.debug.print("Failed to acquire connection\n", .{});
        return;
    };
    defer pooled_conn.release();

    var pipeline = Pipeline.init(pooled_conn.get(), allocator);
    defer pipeline.deinit();

    const where = [_]WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .lte,
            .value = .{ .param = 1 },
        },
    }};
    const cmd = QailCmd.get("harbors")
        .select(&.{ Expr.col("id"), Expr.col("name") })
        .where(&where);

    var stmt = pipeline.prepare(&cmd) catch return;
    defer stmt.deinit();

    const text_params = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

    for (0..batches) |_| {
        var param_values: [QUERIES_PER_BATCH][1]?[]const u8 = undefined;
        var param_rows: [QUERIES_PER_BATCH][]const ?[]const u8 = undefined;
        for (0..QUERIES_PER_BATCH) |i| {
            param_values[i][0] = text_params[i % text_params.len];
            param_rows[i] = param_values[i][0..];
        }

        const completed = pipeline.pipelinePreparedFast(&stmt, param_rows[0..]) catch continue;
        _ = counter.fetchAdd(completed, .monotonic);
        _ = parsed_counter.fetchAdd(completed, .monotonic);
    }
}

fn progressFn(counter: *std.atomic.Value(usize), start: i64) void {
    while (true) {
        std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            std.Io.Duration.fromSeconds(2),
            .awake,
        ) catch {};

        const count = counter.load(.acquire);
        if (count >= TOTAL_QUERIES) break;

        const now = nowMillis();
        const elapsed_ms = now - start;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const qps = @as(f64, @floatFromInt(count)) / elapsed_s;
        const remaining = TOTAL_QUERIES - count;
        const eta = if (qps > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(remaining)) / qps)) else 0;

        std.debug.print("   {} queries |  {d:.0} q/s | ETA: {}s\n", .{ count, qps, eta });
    }
}

fn nowMillis() i64 {
    return std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}
