// QAIL Zig Fair Benchmark - Matches Rust-style public API shape
//
// Uses AST prepared statements through the public Pipeline API.

const std = @import("std");
const qail = @import("qail");
const time = qail.runtime.time;

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const WhereClause = qail.ast.cmd.WhereClause;
const Connection = qail.driver.connection.Connection;
const Pipeline = qail.driver.pipeline.Pipeline;
const PreparedStatement = qail.driver.pipeline.PreparedStatement;

const TOTAL_QUERIES: u64 = 50_000_000;
const BATCH_SIZE: usize = 10_000;
const BATCHES: u64 = TOTAL_QUERIES / @as(u64, BATCH_SIZE);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig Fair Benchmark - AST Pipeline                    ║\n", .{});
    std.debug.print("╠════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Query:   SELECT id, name FROM harbors WHERE id <= $1      ║\n", .{});
    std.debug.print("║  Batch:   10,000 queries per pipeline                      ║\n", .{});
    std.debug.print("║  Total:   50,000,000 queries                               ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("🔌 Connecting to PostgreSQL...\n", .{});

    var conn = try Connection.connect(allocator, "127.0.0.1", 5432);
    defer conn.close();
    try conn.startup("orion", "postgres", null);

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

    std.debug.print("📋 Preparing AST statement...\n", .{});
    var stmt = try pipeline.prepare(&cmd);
    defer stmt.deinit();
    std.debug.print("✅ Statement prepared!\n\n", .{});

    var param_values: [BATCH_SIZE][1]?[]const u8 = undefined;
    var param_rows: [BATCH_SIZE][]const ?[]const u8 = undefined;
    const text_params = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    for (0..BATCH_SIZE) |i| {
        param_values[i][0] = text_params[i % text_params.len];
        param_rows[i] = param_values[i][0..];
    }

    std.debug.print("🔥 Warming up (1 batch = 10K queries)...\n", .{});
    _ = try runBatch(&pipeline, &stmt, param_rows[0..]);

    std.debug.print("\n📊 Running 50 MILLION queries...\n\n", .{});

    const start = time.now() catch unreachable;
    var completed: u64 = 0;

    for (0..BATCHES) |batch| {
        completed += try runBatch(&pipeline, &stmt, param_rows[0..]);

        if (completed % 1_000_000 == 0) {
            const now = time.now() catch unreachable;
            const elapsed_ns = time.since(now, start);
            const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const qps = @as(f64, @floatFromInt(completed)) / elapsed_s;
            const remaining = TOTAL_QUERIES - completed;
            const eta = @as(f64, @floatFromInt(remaining)) / qps;

            std.debug.print("  {d:>3}M queries | {d:>8.0} q/s | ETA: {d:.0}s | Batch {d}/{d}\n", .{
                completed / 1_000_000,
                qps,
                eta,
                batch + 1,
                BATCHES,
            });
        }
    }

    const end = time.now() catch unreachable;
    const total_ns = time.since(end, start);
    const total_s = @as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0;
    const final_qps = @as(f64, @floatFromInt(TOTAL_QUERIES)) / total_s;
    const per_query_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(TOTAL_QUERIES));

    std.debug.print("\n", .{});
    std.debug.print("📈 FINAL RESULTS:\n", .{});
    std.debug.print("┌──────────────────────────────────────────┐\n", .{});
    std.debug.print("│ 50 MILLION QUERY STRESS TEST             │\n", .{});
    std.debug.print("├──────────────────────────────────────────┤\n", .{});
    std.debug.print("│ Total Time:           {d:>15.1}s │\n", .{total_s});
    std.debug.print("│ Queries/Second:       {d:>15.0} │\n", .{final_qps});
    std.debug.print("│ Per Query:            {d:>12.0}ns │\n", .{per_query_ns});
    std.debug.print("│ Successful:           {d:>15} │\n", .{completed});
    std.debug.print("└──────────────────────────────────────────┘\n", .{});
    std.debug.print("\n⚡ Pure Zig - Zero FFI - Zero GC\n", .{});
}

fn runBatch(pipeline: *Pipeline, stmt: *const PreparedStatement, params_batch: []const []const ?[]const u8) !u64 {
    return @intCast(try pipeline.pipelinePreparedFast(stmt, params_batch));
}
