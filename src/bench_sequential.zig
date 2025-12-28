// QAIL Zig Sequential Query Benchmark (Zig 0.16 API)
// Tests Extended Query vs Simple Query Protocol

const std = @import("std");
const qail = @import("qail");

const Io = std.Io;
const Threaded = Io.Threaded;
const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const PgDriver = qail.PgDriver;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("============================================================\n", .{});
    std.debug.print("Native Zig Sequential Query Benchmark (Zig 0.16)\n", .{});
    std.debug.print("Extended Query vs Simple Query Protocol\n", .{});
    std.debug.print("============================================================\n\n", .{});

    // Create Io instance (Zig 0.16 pattern)
    var threaded = Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Connect using new Io interface
    var driver = PgDriver.connect(
        allocator,
        io,
        "127.0.0.1",
        5432,
        "orion",
        "swb_staging_local",
    ) catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return;
    };
    defer driver.deinit();

    std.debug.print("Connected to PostgreSQL\n\n", .{});

    // Build cmd
    const cols = [_]Expr{ Expr.col("id"), Expr.col("name"), Expr.col("slug"), Expr.col("is_active") };
    const cmd = QailCmd.get("destinations").select(&cols).limit(10);

    const num_queries: usize = 10_000;

    // Warmup Extended Query
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const rows = try driver.fetchAll(&cmd);
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }

    // Benchmark Extended Query Protocol
    var timer = try std.time.Timer.start();
    i = 0;
    while (i < num_queries) : (i += 1) {
        const rows = try driver.fetchAll(&cmd);
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }
    const elapsed_ext_ns = timer.read();
    const ext_us: f64 = @as(f64, @floatFromInt(elapsed_ext_ns)) / 1000.0 / @as(f64, @floatFromInt(num_queries));
    const ext_qps: f64 = @as(f64, @floatFromInt(num_queries)) / (@as(f64, @floatFromInt(elapsed_ext_ns)) / 1_000_000_000.0);

    std.debug.print("Extended Query:  {d:.0} q/s  ({d:.2} µs/query)\n", .{ ext_qps, ext_us });

    // Warmup Simple Query
    i = 0;
    while (i < 100) : (i += 1) {
        const rows = try driver.fetchAllSimple(&cmd);
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }

    // Benchmark Simple Query Protocol
    timer.reset();
    i = 0;
    while (i < num_queries) : (i += 1) {
        const rows = try driver.fetchAllSimple(&cmd);
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }
    const elapsed_simple_ns = timer.read();
    const simple_us: f64 = @as(f64, @floatFromInt(elapsed_simple_ns)) / 1000.0 / @as(f64, @floatFromInt(num_queries));
    const simple_qps: f64 = @as(f64, @floatFromInt(num_queries)) / (@as(f64, @floatFromInt(elapsed_simple_ns)) / 1_000_000_000.0);

    std.debug.print("Simple Query:    {d:.0} q/s  ({d:.2} µs/query)\n", .{ simple_qps, simple_us });

    // Speedup
    const speedup: f64 = simple_qps / ext_qps;
    std.debug.print("\nSpeedup: {d:.2}x\n", .{speedup});
    std.debug.print("\nFor comparison:\n", .{});
    std.debug.print("  Native Rust:   ~19,500 q/s  (~51 µs/query)\n", .{});
    std.debug.print("  asyncpg:       ~15,500 q/s  (~64 µs/query)\n", .{});
}
