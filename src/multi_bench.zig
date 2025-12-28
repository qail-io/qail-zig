// QAIL Zig Multi-Connection Benchmark (Debug Version)
//
// Uses direct connections (no pool) with page_allocator for thread safety.
// Run: zig build multi

const std = @import("std");
const driver = @import("driver/mod.zig");
const protocol = @import("protocol/mod.zig");

const Connection = driver.Connection;
const Encoder = protocol.Encoder;

const TOTAL_QUERIES: usize = 10_000_000;
const NUM_WORKERS: usize = 10;
const QUERIES_PER_BATCH: usize = 100;

pub fn main() !void {
    // Use page_allocator - it's thread-safe
    const allocator = std.heap.page_allocator;

    std.debug.print(
        \\╔═══════════════════════════════════════════════════════════╗
        \\║  QAIL Zig Multi-Connection Benchmark (Direct)             ║
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

    const start = std.time.milliTimestamp();

    // Spawn worker threads
    var threads: [NUM_WORKERS]std.Thread = undefined;
    for (0..NUM_WORKERS) |i| {
        std.debug.print("  Starting thread {}...\n", .{i});
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{ i, &counter, batches_per_worker, allocator });
    }

    std.debug.print("✅ All threads started\n\n", .{});

    // Progress reporter
    const progress_thread = try std.Thread.spawn(.{}, progressFn, .{ &counter, start });

    // Wait for workers
    for (0..NUM_WORKERS) |i| {
        threads[i].join();
        std.debug.print("  Thread {} finished\n", .{i});
    }

    const end = std.time.milliTimestamp();
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

    // Create direct connection
    var conn = Connection.connect(allocator, "127.0.0.1", 5432) catch |e| {
        std.debug.print("    [{}] Failed to connect: {}\n", .{ id, e });
        return;
    };
    defer conn.close();

    std.debug.print("    [{}] Connected, authenticating...\n", .{id});

    conn.startup("orion", "postgres", null) catch |e| {
        std.debug.print("    [{}] Failed to authenticate: {}\n", .{ id, e });
        return;
    };

    std.debug.print("    [{}] Authenticated, preparing statement...\n", .{id});

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    // Prepare statement - need to send Parse + Sync to get response
    const stmt_name = "s_test";
    encoder.encodeParse(stmt_name, "SELECT id, name FROM harbors LIMIT $1", &[_]u32{23}) catch |e| {
        std.debug.print("    [{}] encodeParse failed: {}\n", .{ id, e });
        return;
    };
    conn.stream.writeAll(encoder.getWritten()) catch |e| {
        std.debug.print("    [{}] writeAll Parse failed: {}\n", .{ id, e });
        return;
    };

    // Must send Sync to get ParseComplete response
    encoder.encodeSync() catch |e| {
        std.debug.print("    [{}] encodeSync failed: {}\n", .{ id, e });
        return;
    };
    conn.stream.writeAll(encoder.getWritten()) catch |e| {
        std.debug.print("    [{}] writeAll Sync failed: {}\n", .{ id, e });
        return;
    };

    // Read parse complete + ready
    var read_buf: [16384]u8 = undefined;
    _ = conn.stream.read(&read_buf) catch |e| {
        std.debug.print("    [{}] read failed: {}\n", .{ id, e });
        return;
    };

    std.debug.print("    [{}] Statement prepared, running {} batches...\n", .{ id, batches });

    // Run batches
    var completed_batches: usize = 0;
    for (0..batches) |_| {
        for (0..QUERIES_PER_BATCH) |i| {
            const limit_val: i32 = @intCast((i % 10) + 1);
            var limit_buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &limit_buf, limit_val, .big);

            encoder.encodeBind("", stmt_name, &[_]?[]const u8{&limit_buf}) catch continue;
            conn.stream.writeAll(encoder.getWritten()) catch continue;

            encoder.encodeExecute("", 0) catch continue;
            conn.stream.writeAll(encoder.getWritten()) catch continue;
        }

        encoder.encodeSync() catch continue;
        conn.stream.writeAll(encoder.getWritten()) catch continue;

        // Read all responses until ReadyForQuery
        var read_len: usize = 0;
        while (true) {
            const n = conn.stream.read(&read_buf) catch break;
            if (n == 0) break;
            read_len += n;
            if (std.mem.lastIndexOf(u8, read_buf[0..read_len], "Z")) |_| break;
        }

        _ = counter.fetchAdd(QUERIES_PER_BATCH, .monotonic);
        completed_batches += 1;

        // Report progress every 100 batches
        if (completed_batches % 100 == 0) {
            std.debug.print("    [{}] Completed {} batches\n", .{ id, completed_batches });
        }
    }

    std.debug.print("    [{}] Worker finished, {} batches completed\n", .{ id, completed_batches });
}

fn progressFn(counter: *std.atomic.Value(usize), start: i64) void {
    while (true) {
        std.Thread.sleep(2 * std.time.ns_per_s);

        const count = counter.load(.acquire);
        if (count >= TOTAL_QUERIES) break;

        const now = std.time.milliTimestamp();
        const elapsed_s = @as(f64, @floatFromInt(now - start)) / 1000.0;
        const qps = @as(f64, @floatFromInt(count)) / elapsed_s;

        std.debug.print("   {} queries |  {d:.0} q/s\n", .{ count, qps });
    }
}
