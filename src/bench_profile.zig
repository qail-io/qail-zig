// Zig Driver Profiling Benchmark (Zig 0.16 API)
// Isolates each component to find bottleneck

const std = @import("std");
const qail = @import("qail");

const Io = std.Io;
const Threaded = Io.Threaded;
const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const PgDriver = qail.PgDriver;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const num_iterations: usize = 10_000;

    std.debug.print("============================================================\n", .{});
    std.debug.print("Zig Driver Profiling - Find the Bottleneck (Zig 0.16)\n", .{});
    std.debug.print("============================================================\n\n", .{});

    // Create Io instance (Zig 0.16 pattern)
    var threaded = Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Connect using new Io interface
    var driver = PgDriver.connect(allocator, io, "127.0.0.1", 5432, "orion", "swb_staging_local") catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return;
    };
    defer driver.deinit();

    // Build cmd once
    const cols = [_]Expr{ Expr.col("id"), Expr.col("name"), Expr.col("slug"), Expr.col("is_active") };
    const cmd = QailCmd.get("destinations").select(&cols).limit(10);

    // Test 1: Just AST to SQL encoding (no network)
    {
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < num_iterations) : (i += 1) {
            try driver.encoder.encodeQuery(&cmd);
        }
        const elapsed_ns = timer.read();
        const us_per_op: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0 / @as(f64, @floatFromInt(num_iterations));
        const ops: f64 = @as(f64, @floatFromInt(num_iterations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
        std.debug.print("1. Encode only:      {d:.0} ops/s  ({d:.2} µs/op)\n", .{ ops, us_per_op });
    }

    // Test 2: Encode + Send (no read)
    {
        std.debug.print("2. (skipped - would break protocol)\n", .{});
    }

    // Test 3: Full query with row parsing
    {
        // Warmup
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const rows = try driver.fetchAll(&cmd);
            for (rows) |*row| row.deinit();
            allocator.free(rows);
        }

        var timer = try std.time.Timer.start();
        i = 0;
        while (i < num_iterations) : (i += 1) {
            const rows = try driver.fetchAll(&cmd);
            for (rows) |*row| row.deinit();
            allocator.free(rows);
        }
        const elapsed_ns = timer.read();
        const us_per_op: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0 / @as(f64, @floatFromInt(num_iterations));
        const ops: f64 = @as(f64, @floatFromInt(num_iterations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
        std.debug.print("3. Full query:       {d:.0} ops/s  ({d:.2} µs/op)\n", .{ ops, us_per_op });
    }

    // Test 4: How long is row cleanup taking?
    {
        const rows = try driver.fetchAll(&cmd);

        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < num_iterations) : (i += 1) {
            for (rows) |row| {
                _ = row.getString(0);
                _ = row.getString(1);
            }
        }
        const elapsed_ns = timer.read();
        const us_per_op: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1000.0 / @as(f64, @floatFromInt(num_iterations));
        const ops: f64 = @as(f64, @floatFromInt(num_iterations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
        std.debug.print("4. Row access:       {d:.0} ops/s  ({d:.2} µs/op)\n", .{ ops, us_per_op });

        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }

    std.debug.print("\n", .{});
    std.debug.print("ANALYSIS:\n", .{});
    std.debug.print("If #1 (encode) is slow -> AST-to-SQL is bottleneck\n", .{});
    std.debug.print("If #3-#1 is large -> Network/parsing is bottleneck\n", .{});
    std.debug.print("Compare with Rust 19,500 q/s (~51 µs/query)\n", .{});
}
