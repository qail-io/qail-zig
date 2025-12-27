//! QAIL Zig Pool Benchmark - Fair Comparison with Rust
//!
//! Uses PgPool with multiple threads for parallel query execution.
//!
//! Run: zig build pool -Doptimize=ReleaseFast

const std = @import("std");
const driver = @import("driver/mod.zig");
const protocol = @import("protocol/mod.zig");
const ast = @import("ast/mod.zig");

const PgPool = driver.pool.PgPool;
const PoolConfig = driver.pool.PoolConfig;
const Pipeline = driver.Pipeline;
const Encoder = protocol.Encoder;

const TOTAL_QUERIES: usize = 150_000_000;
const NUM_WORKERS: usize = 10;
const POOL_SIZE: usize = 10;
const QUERIES_PER_BATCH: usize = 100;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print(
        \\╔═══════════════════════════════════════════════════════════╗
        \\║  QAIL Zig Pool Benchmark - Matches Rust Config            ║
        \\╠═══════════════════════════════════════════════════════════╣
        \\║  Total:    150,000,000 queries                            ║
        \\║  Workers:  10 threads                                     ║
        \\║  Pool:     10 connections                                 ║
        \\║  Batch:    100 queries per pipeline                       ║
        \\╚═══════════════════════════════════════════════════════════╝
        \\
        \\
    , .{});

    std.debug.print("🔌 Initializing connection pool...\n", .{});

    // Create pool
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

    const start = std.time.milliTimestamp();

    // Spawn worker threads
    var threads: [NUM_WORKERS]std.Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{ &pool, &counter, batches_per_worker, allocator });
    }

    // Progress reporter thread
    const progress_thread = try std.Thread.spawn(.{}, progressFn, .{ &counter, start });

    // Wait for all workers
    for (&threads) |*thread| {
        thread.join();
    }

    const end = std.time.milliTimestamp();
    const elapsed_ms = end - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const total = counter.load(.acquire);
    const qps = @as(f64, @floatFromInt(total)) / elapsed_s;

    // Signal progress thread to stop
    counter.store(TOTAL_QUERIES + 1, .release);
    progress_thread.join();

    std.debug.print(
        \\
        \\📈 FINAL RESULTS:
        \\┌─────────────────────────────────────────────────┐
        \\│ QAIL ZIG POOL BENCHMARK                         │
        \\├─────────────────────────────────────────────────┤
        \\│ Total Time:                       {d:.1}s │
        \\│ Queries/Second:                 {d:.0} │
        \\│ Workers:                              {} │
        \\│ Pool Size:                            {} │
        \\│ Queries Completed:             {} │
        \\└─────────────────────────────────────────────────┘
        \\
    , .{ elapsed_s, qps, NUM_WORKERS, POOL_SIZE, total });
}

fn workerFn(pool: *PgPool, counter: *std.atomic.Value(usize), batches: usize, allocator: std.mem.Allocator) void {
    // Acquire connection from pool
    var pooled_conn = pool.acquire() catch {
        std.debug.print("Failed to acquire connection\n", .{});
        return;
    };
    defer pooled_conn.release();

    var conn = pooled_conn.get();

    // Create encoder for pipelining
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    // Prepare statement - MUST send Sync after Parse
    const stmt_name = "s_pool_bench";
    encoder.encodeParse(stmt_name, "SELECT id, name FROM harbors LIMIT $1", &[_]u32{23}) catch return;
    conn.stream.writeAll(encoder.getWritten()) catch return;

    encoder.encodeSync() catch return;
    conn.stream.writeAll(encoder.getWritten()) catch return;

    // Read parse complete + ready
    var read_buf: [16384]u8 = undefined;
    _ = conn.stream.read(&read_buf) catch return;

    // Run batches
    for (0..batches) |_| {
        encoder.reset();

        // Encode batch of 100 queries
        for (0..QUERIES_PER_BATCH) |i| {
            const limit_val: i32 = @intCast((i % 10) + 1);
            var limit_buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &limit_buf, limit_val, .big);

            encoder.appendBind("", stmt_name, &[_]?[]const u8{&limit_buf}) catch continue;
            encoder.appendExecute("", 0) catch continue;
        }
        encoder.appendSync() catch continue;

        conn.send(encoder.getWritten()) catch continue;

        // Read all responses
        var total_read: usize = 0;
        while (total_read < 5000) { // Approximate response size
            const n = conn.stream.read(&read_buf) catch break;
            if (n == 0) break;
            total_read += n;
            // Check for ReadyForQuery
            if (std.mem.indexOf(u8, read_buf[0..n], "Z")) |_| break;
        }

        _ = counter.fetchAdd(QUERIES_PER_BATCH, .monotonic);
    }
}

fn progressFn(counter: *std.atomic.Value(usize), start: i64) void {
    while (true) {
        std.Thread.sleep(2 * std.time.ns_per_s);

        const count = counter.load(.acquire);
        if (count >= TOTAL_QUERIES) break;

        const now = std.time.milliTimestamp();
        const elapsed_ms = now - start;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const qps = @as(f64, @floatFromInt(count)) / elapsed_s;
        const remaining = TOTAL_QUERIES - count;
        const eta = if (qps > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(remaining)) / qps)) else 0;

        std.debug.print("   {} queries |  {d:.0} q/s | ETA: {}s\n", .{ count, qps, eta });
    }
}
