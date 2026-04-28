// QAIL Zig Multi-Connection Benchmark
//
// Uses direct connections with the public AST-native Pipeline API.
// Run: zig build multi

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const WhereClause = qail.ast.cmd.WhereClause;
const Connection = qail.driver.connection.Connection;
const Pipeline = qail.driver.pipeline.Pipeline;

const TOTAL_QUERIES: usize = 10_000_000;
const NUM_WORKERS: usize = 10;
const QUERIES_PER_BATCH: usize = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print(
        \\╔═══════════════════════════════════════════════════════════╗
        \\║  QAIL Zig Multi-Connection Benchmark (AST Pipeline)      ║
        \\╠═══════════════════════════════════════════════════════════╣
        \\║  Total:    10,000,000 queries                             ║
        \\║  Workers:  10 threads (10 connections)                    ║
        \\║  Batch:    100 queries per pipeline                       ║
        \\╚═══════════════════════════════════════════════════════════╝
        \\
        \\
    , .{});

    std.debug.print("🔌 Spawning {} worker threads...\n", .{NUM_WORKERS});

    const batches_per_worker = TOTAL_QUERIES / NUM_WORKERS / QUERIES_PER_BATCH;
    var counter = std.atomic.Value(usize).init(0);

    const start = nowMillis();

    var threads: [NUM_WORKERS]std.Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        std.debug.print("  Starting thread {}...\n", .{i});
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{ i, &counter, batches_per_worker, allocator });
    }

    std.debug.print("✅ All threads started\n\n", .{});

    const progress_thread = try std.Thread.spawn(.{}, progressFn, .{ &counter, start });

    for (0..NUM_WORKERS) |i| {
        threads[i].join();
        std.debug.print("  Thread {} finished\n", .{i});
    }

    const end = nowMillis();
    const elapsed_ms = end - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const total = counter.load(.acquire);
    const qps = @as(f64, @floatFromInt(total)) / elapsed_s;

    counter.store(TOTAL_QUERIES + 1, .release);
    progress_thread.join();

    std.debug.print(
        \\
        \\📈 FINAL RESULTS:
        \\┌─────────────────────────────────────────────────┐
        \\│ Queries/Second:               {d:.0} │
        \\│ Total Time:                     {d:.1}s │
        \\│ Queries Completed:           {} │
        \\└─────────────────────────────────────────────────┘
        \\
    , .{ qps, elapsed_s, total });
}

fn workerFn(id: usize, counter: *std.atomic.Value(usize), batches: usize, allocator: std.mem.Allocator) void {
    std.debug.print("    [{}] Worker starting, connecting...\n", .{id});

    var conn = Connection.connect(allocator, "127.0.0.1", 5432) catch |e| {
        std.debug.print("    [{}] Failed to connect: {}\n", .{ id, e });
        return;
    };
    defer conn.close();

    conn.startup("orion", "postgres", null) catch |e| {
        std.debug.print("    [{}] Failed to authenticate: {}\n", .{ id, e });
        return;
    };

    var pipeline = Pipeline.init(&conn, allocator);
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

    var stmt = pipeline.prepare(&cmd) catch |e| {
        std.debug.print("    [{}] prepare failed: {}\n", .{ id, e });
        return;
    };
    defer stmt.deinit();

    std.debug.print("    [{}] Statement prepared, running {} batches...\n", .{ id, batches });

    const text_params = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    var completed_batches: usize = 0;
    for (0..batches) |_| {
        var param_values: [QUERIES_PER_BATCH][1]?[]const u8 = undefined;
        var param_rows: [QUERIES_PER_BATCH][]const ?[]const u8 = undefined;
        for (0..QUERIES_PER_BATCH) |i| {
            param_values[i][0] = text_params[i % text_params.len];
            param_rows[i] = param_values[i][0..];
        }

        const completed = pipeline.pipelinePreparedFast(&stmt, param_rows[0..]) catch continue;
        _ = counter.fetchAdd(completed, .monotonic);
        completed_batches += 1;

        if (completed_batches % 100 == 0) {
            std.debug.print("    [{}] Completed {} batches\n", .{ id, completed_batches });
        }
    }

    std.debug.print("    [{}] Worker finished, {} batches completed\n", .{ id, completed_batches });
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
        const elapsed_s = @as(f64, @floatFromInt(now - start)) / 1000.0;
        const qps = @as(f64, @floatFromInt(count)) / elapsed_s;

        std.debug.print("   {} queries |  {d:.0} q/s\n", .{ count, qps });
    }
}

fn nowMillis() i64 {
    return std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}
