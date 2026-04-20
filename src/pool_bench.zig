// QAIL Zig Pool Benchmark - Fair Comparison with Rust
//
// Uses PgPool with multiple threads for parallel query execution.
// PARSES RESPONSES like Rust's pipeline_prepared_ultra for fair comparison.
//
// Query: SELECT id, name FROM harbors LIMIT $1
// Run: zig build pool

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

// Query being benchmarked
const QUERY = "SELECT id, name FROM harbors LIMIT $1";

pub fn main() !void {
    // Use page_allocator - it's thread-safe
    const allocator = std.heap.page_allocator;

    std.debug.print(
        \\╔═══════════════════════════════════════════════════════════╗
        \\║  QAIL Zig Pool Benchmark - Fair Comparison with Rust      ║
        \\╠═══════════════════════════════════════════════════════════╣
        \\║  Query:   SELECT id, name FROM harbors LIMIT $1           ║
        \\║  Total:    150,000,000 queries                            ║
        \\║  Workers:  10 threads                                     ║
        \\║  Pool:     10 connections                                 ║
        \\║  Batch:    100 queries per pipeline                       ║
        \\║  Parsing:  Yes (fair comparison)                          ║
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
    var rows_counter = std.atomic.Value(usize).init(0);

    const start = nowMillis();

    // Spawn worker threads
    var threads: [NUM_WORKERS]std.Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{ &pool, &counter, &rows_counter, batches_per_worker, allocator });
    }

    // Progress reporter thread
    const progress_thread = try std.Thread.spawn(.{}, progressFn, .{ &counter, start });

    // Wait for all workers
    for (&threads) |*thread| {
        thread.join();
    }

    const end = nowMillis();
    const elapsed_ms = end - start;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    const total = counter.load(.acquire);
    const rows = rows_counter.load(.acquire);
    const qps = @as(f64, @floatFromInt(total)) / elapsed_s;

    // Signal progress thread to stop
    counter.store(TOTAL_QUERIES + 1, .release);
    progress_thread.join();

    std.debug.print(
        \\
        \\📈 FINAL RESULTS:
        \\┌─────────────────────────────────────────────────┐
        \\│ QAIL ZIG POOL BENCHMARK (FAIR)                  │
        \\├─────────────────────────────────────────────────┤
        \\│ Query: SELECT id, name FROM harbors LIMIT $1    │
        \\│ Total Time:                       {d:.1}s │
        \\│ Queries/Second:                 {d:.0} │
        \\│ Rows Parsed:                   {} │
        \\│ Workers:                              {} │
        \\│ Pool Size:                            {} │
        \\│ Queries Completed:             {} │
        \\└─────────────────────────────────────────────────┘
        \\
    , .{ elapsed_s, qps, rows, NUM_WORKERS, POOL_SIZE, total });
}

fn workerFn(pool: *PgPool, counter: *std.atomic.Value(usize), rows_counter: *std.atomic.Value(usize), batches: usize, allocator: std.mem.Allocator) void {
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
    encoder.encodeParse(stmt_name, QUERY, &[_]u32{23}) catch return;
    conn.stream.writeAll(encoder.getWritten()) catch return;

    encoder.encodeSync() catch return;
    conn.stream.writeAll(encoder.getWritten()) catch return;

    // Read parse complete + ready
    var read_buf: [65536]u8 = undefined;
    _ = conn.stream.read(&read_buf) catch return;

    // Run batches
    for (0..batches) |_| {
        encoder.reset();

        // Encode batch of 100 queries - use TEXT parameters
        const text_params = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
        for (0..QUERIES_PER_BATCH) |i| {
            const param_idx = i % 10;
            encoder.appendBind("", stmt_name, &[_]?[]const u8{text_params[param_idx]}) catch continue;
            encoder.appendExecute("", 0) catch continue;
        }
        encoder.appendSync() catch continue;

        conn.stream.writeAll(encoder.getWritten()) catch continue;

        // FAIR: Parse responses like Rust's pipeline_prepared_ultra
        var rows_in_batch: usize = 0;
        var commands: usize = 0;
        var read_pos: usize = 0;
        var read_len: usize = 0;

        while (commands < QUERIES_PER_BATCH) {
            // Ensure we have header (1 byte type + 4 byte length)
            while (read_len - read_pos < 5) {
                if (read_pos > 0) {
                    const remaining = read_len - read_pos;
                    std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[read_pos..read_len]);
                    read_len = remaining;
                    read_pos = 0;
                }
                const n = conn.stream.read(read_buf[read_len..]) catch break;
                if (n == 0) break;
                read_len += n;
            }

            if (read_len - read_pos < 5) break;

            const msg_type = read_buf[read_pos];
            const length = std.mem.readInt(u32, read_buf[read_pos + 1 ..][0..4], .big);
            const msg_len = 1 + length;

            // Ensure full message
            while (read_len - read_pos < msg_len) {
                if (read_pos > 0) {
                    const remaining = read_len - read_pos;
                    std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[read_pos..read_len]);
                    read_len = remaining;
                    read_pos = 0;
                }
                const n = conn.stream.read(read_buf[read_len..]) catch break;
                if (n == 0) break;
                read_len += n;
            }

            // Process message
            switch (msg_type) {
                'D' => {
                    // DataRow - parse column count and values (like Rust)
                    const data_start = read_pos + 5;
                    if (data_start + 2 <= read_len) {
                        const col_count = std.mem.readInt(u16, read_buf[data_start..][0..2], .big);
                        _ = col_count;
                        rows_in_batch += 1;
                    }
                },
                'C' => commands += 1, // CommandComplete
                'n' => commands += 1, // NoData
                'Z' => break, // ReadyForQuery
                else => {},
            }

            read_pos += msg_len;
        }

        _ = counter.fetchAdd(QUERIES_PER_BATCH, .monotonic);
        _ = rows_counter.fetchAdd(rows_in_batch, .monotonic);
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
