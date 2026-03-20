// Pipeline API Benchmark
//
// Tests the new Pipeline pipelining API for performance.

const std = @import("std");
const qail = @import("qail");
const time = qail.compat.time;

const Pipeline = qail.driver.Pipeline;
const Connection = qail.driver.Connection;
const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig - Pipeline API Benchmark                         ║\n", .{});
    std.debug.print("║  Testing new Pipeline struct pipelining                    ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Connect
    std.debug.print("🔌 Connecting to PostgreSQL...\n", .{});
    var conn = try Connection.connect(allocator, "127.0.0.1", 5432);
    defer conn.close();

    try conn.startup("orion", "postgres", null);
    std.debug.print("✅ Connected!\n\n", .{});

    // Create pipeline context
    var pipeline = Pipeline.init(&conn, allocator);
    defer pipeline.deinit();

    // Prepare statement
    std.debug.print("📋 Preparing statement...\n", .{});
    var stmt = try pipeline.prepare("SELECT 1");
    defer stmt.deinit();
    std.debug.print("✅ Statement prepared: {s}\n\n", .{stmt.name});

    // Warmup with 1K queries
    std.debug.print("🔥 Warmup (1K)...\n", .{});
    const warmup_batch = try allocator.alloc([]const ?[]const u8, 1000);
    defer allocator.free(warmup_batch);
    @memset(warmup_batch, &.{});
    _ = try pipeline.pipelinePreparedFast(&stmt, warmup_batch);

    std.debug.print("📊 Running benchmarks...\n\n", .{});

    // Benchmark different sizes
    const sizes = [_]usize{ 1_000, 10_000, 100_000 };

    for (sizes) |count| {
        const params_batch = try allocator.alloc([]const ?[]const u8, count);
        defer allocator.free(params_batch);
        @memset(params_batch, &.{});

        const start = time.now() catch unreachable;

        const completed = try pipeline.pipelinePreparedFast(&stmt, params_batch);

        const end = time.now() catch unreachable;
        const nanos = end.since(start);
        const ms = @as(f64, @floatFromInt(nanos)) / 1_000_000.0;
        const qps = @as(f64, @floatFromInt(completed)) / (ms / 1000.0);

        std.debug.print("  {d}K queries: {d:.2}ms ({d:.0} qps)\n", .{
            count / 1000,
            ms,
            qps,
        });
    }

    std.debug.print("\n✅ Pipeline API benchmark complete!\n", .{});
}
