// Zig I/O Microbenchmark
// Measures raw socket read/write performance vs Rust

const std = @import("std");
const qail = @import("qail");

const PgDriver = qail.PgDriver;
const QailCmd = qail.QailCmd;
const Expr = qail.Expr;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("============================================================\n", .{});
    std.debug.print("Zig I/O Microbenchmark\n", .{});
    std.debug.print("============================================================\n\n", .{});

    // Connect
    var driver = PgDriver.connect(allocator, "127.0.0.1", 5432, "orion", "swb_staging_local") catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return;
    };
    defer driver.deinit();

    const num_queries: usize = 1_000;

    // Build a minimal query
    const cols = [_]Expr{Expr.col("1")};
    const cmd = QailCmd.get("(SELECT 1) t").select(&cols);

    // First, measure how many read() syscalls per query
    std.debug.print("Running {} minimal queries (SELECT 1)...\n\n", .{num_queries});

    // Warmup
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const rows = try driver.fetchAll(&cmd);
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    i = 0;
    while (i < num_queries) : (i += 1) {
        const rows = try driver.fetchAll(&cmd);
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }
    const elapsed_ns = timer.read();
    const us_per_query: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0 / @as(f64, @floatFromInt(num_queries));
    const qps: f64 = @as(f64, @floatFromInt(num_queries)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("Results for SELECT 1:\n", .{});
    std.debug.print("  Total time: {d:.2} ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
    std.debug.print("  Per query:  {d:.2} µs\n", .{us_per_query});
    std.debug.print("  Throughput: {d:.0} q/s\n", .{qps});
    std.debug.print("\n", .{});

    // The key insight: if SELECT 1 takes ~300µs and Rust does it in ~50µs,
    // the overhead is in socket I/O, not query complexity.
    // Possible causes:
    // 1. Multiple read() syscalls per query (Zig does incremental reads)
    // 2. Lack of async I/O (blocking on each read)
    // 3. Buffer management overhead

    std.debug.print("Analysis:\n", .{});
    std.debug.print("If this is ~300µs like complex query, the bottleneck is socket I/O.\n", .{});
    std.debug.print("Rust achieves ~50µs because Tokio batches syscalls.\n", .{});
}
