// QAIL Zig Pipelined Stress Test
//
// Uses the public AST-native Pipeline API with prepared statements.

const std = @import("std");
const qail = @import("qail");
const time = qail.runtime.time;

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const Connection = qail.driver.connection.Connection;
const Pipeline = qail.driver.pipeline.Pipeline;
const PreparedStatement = qail.driver.pipeline.PreparedStatement;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig - Pipelined 50M Stress Test                      ║\n", .{});
    std.debug.print("║  Using AST prepared statements + pipelining                ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("🔌 Connecting to PostgreSQL...\n", .{});

    var conn = try Connection.connect(allocator, "127.0.0.1", 5432);
    defer conn.close();
    try conn.startup("orion", "postgres", null);

    var pipeline = Pipeline.init(&conn, allocator);
    defer pipeline.deinit();

    const one_cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{Expr.int(1)})
        .limit(1);

    std.debug.print("📋 Preparing AST statement...\n", .{});
    var stmt = try pipeline.prepare(&one_cmd);
    defer stmt.deinit();
    std.debug.print("✅ Statement prepared!\n\n", .{});

    std.debug.print("🔥 Warming up (10K pipelined)...\n", .{});
    _ = try runPipelinedBenchmark(allocator, &pipeline, &stmt, 10_000, 100);

    std.debug.print("\n📊 Running pipelined stress test...\n\n", .{});

    const runs = [_]u64{ 100_000, 1_000_000, 10_000_000, 50_000_000 };
    const batch_size: u64 = 1000;

    for (runs) |count| {
        const result = try runPipelinedBenchmark(allocator, &pipeline, &stmt, count, batch_size);
        printResult(count, result);
    }

    std.debug.print("\n✅ Pipelined stress test complete!\n", .{});
}

fn runPipelinedBenchmark(
    allocator: std.mem.Allocator,
    pipeline: *Pipeline,
    stmt: *const PreparedStatement,
    iterations: u64,
    batch_size: u64,
) !u64 {
    const start = time.now() catch unreachable;

    var completed: u64 = 0;
    while (completed < iterations) {
        const remaining = iterations - completed;
        const batch: usize = @intCast(@min(batch_size, remaining));

        const params = try allocator.alloc([]const ?[]const u8, batch);
        errdefer allocator.free(params);
        for (params) |*param_set| param_set.* = &.{};

        const done = try pipeline.pipelinePreparedFast(stmt, params);
        allocator.free(params);
        completed += done;

        if (completed % 1_000_000 == 0) {
            std.debug.print("   Progress: {d}M/{d}M\r", .{ completed / 1_000_000, iterations / 1_000_000 });
        }
    }

    const end = time.now() catch unreachable;
    return time.since(end, start);
}

fn printResult(iterations: u64, nanos: u64) void {
    const ms = @as(f64, @floatFromInt(nanos)) / 1_000_000.0;
    const seconds = ms / 1000.0;
    const per_op_us = @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / seconds;

    if (iterations >= 1_000_000) {
        std.debug.print("  {d:>3}M queries: {d:>8.2}s  ({d:>6.2} us/query, {d:>10.0} qps)\n", .{
            iterations / 1_000_000,
            seconds,
            per_op_us,
            ops_per_sec,
        });
    } else {
        std.debug.print("  {d:>3}K queries: {d:>8.2}s  ({d:>6.2} us/query, {d:>10.0} qps)\n", .{
            iterations / 1_000,
            seconds,
            per_op_us,
            ops_per_sec,
        });
    }
}
