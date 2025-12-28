// QAIL Zig Fair Benchmark - Matches Rust Configuration (Zig 0.16 API)
//
// Same query, batch size, and parameters as Rust fifty_million_benchmark

const std = @import("std");
const qail = @import("qail");

const Io = std.Io;
const Threaded = Io.Threaded;
const net = Io.net;
const posix = std.posix;
const Encoder = qail.protocol.Encoder;
const Decoder = qail.protocol.Decoder;
const BackendMessage = qail.protocol.BackendMessage;

const TOTAL_QUERIES: u64 = 50_000_000;
const BATCH_SIZE: u64 = 10_000; // Same as Rust
const BATCHES: u64 = TOTAL_QUERIES / BATCH_SIZE;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig Fair Benchmark - Matches Rust Config (Zig 0.16)  ║\n", .{});
    std.debug.print("╠════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Query:   SELECT id, name FROM harbors LIMIT $1            ║\n", .{});
    std.debug.print("║  Batch:   10,000 queries per pipeline                      ║\n", .{});
    std.debug.print("║  Total:   50,000,000 queries                               ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create Io instance (Zig 0.16 pattern)
    var threaded = Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Connect to PostgreSQL
    std.debug.print("🔌 Connecting to PostgreSQL...\n", .{});

    const address = try net.IpAddress.parseIp4("127.0.0.1", 5432);
    const stream = try net.IpAddress.connect(address, io, .{ .mode = .stream });
    defer stream.socket.close(io);
    const handle = stream.socket.handle;

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    // Startup
    try encoder.encodeStartup("orion", "postgres");
    try writeAll(handle, encoder.getWritten());

    var read_buf: [16384]u8 = undefined;
    try readUntilReady(handle, &read_buf);

    std.debug.print("✅ Connected!\n\n", .{});

    // Prepare statement - SAME as Rust
    std.debug.print("📋 Preparing: SELECT id, name FROM harbors LIMIT $1\n", .{});
    const param_types = [_]u32{23}; // int4 OID
    try encoder.encodeParse("s1", "SELECT id, name FROM harbors LIMIT $1", &param_types);
    try writeAll(handle, encoder.getWritten());

    try encoder.encodeSync();
    try writeAll(handle, encoder.getWritten());

    try readUntilReady(handle, &read_buf);
    std.debug.print("✅ Statement prepared!\n\n", .{});

    // Pre-build parameter batches - SAME as Rust (limit varies 1-10)
    var params_batch: [BATCH_SIZE][1]?[]const u8 = undefined;
    var param_strings: [10][2]u8 = undefined;
    for (0..10) |i| {
        const val: u8 = @intCast(i + 1);
        param_strings[i][0] = '0' + val;
        if (val >= 10) {
            param_strings[i][0] = '1';
            param_strings[i][1] = '0';
        } else {
            param_strings[i][1] = 0;
        }
    }
    for (0..BATCH_SIZE) |i| {
        const limit_idx = i % 10;
        const len: usize = if (limit_idx == 9) 2 else 1;
        params_batch[i][0] = param_strings[limit_idx][0..len];
    }

    // Warmup
    std.debug.print("🔥 Warming up (1 batch = 10K queries)...\n", .{});
    _ = try runBatch(handle, &encoder, &read_buf, &params_batch);

    std.debug.print("\n📊 Running 50 MILLION queries...\n\n", .{});

    const start = std.time.Instant.now() catch unreachable;
    var completed: u64 = 0;

    for (0..BATCHES) |batch| {
        _ = try runBatch(handle, &encoder, &read_buf, &params_batch);
        completed += BATCH_SIZE;

        if (completed % 1_000_000 == 0) {
            const now = std.time.Instant.now() catch unreachable;
            const elapsed_ns = now.since(start);
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

    const end = std.time.Instant.now() catch unreachable;
    const total_ns = end.since(start);
    const total_s = @as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0;
    const final_qps = @as(f64, @floatFromInt(TOTAL_QUERIES)) / total_s;
    const per_query_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(TOTAL_QUERIES));

    // Terminate
    try encoder.encodeTerminate();
    try writeAll(handle, encoder.getWritten());

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

fn writeAll(handle: posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = posix.write(handle, bytes[sent..]) catch |err| {
            if (err == error.WouldBlock) continue;
            return error.WriteFailed;
        };
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}

fn runBatch(handle: posix.fd_t, encoder: *Encoder, buf: *[16384]u8, params_batch: *const [BATCH_SIZE][1]?[]const u8) !u64 {
    // Pipeline: Send all Bind+Execute at once
    for (params_batch) |params| {
        try encoder.encodeBind("", "s1", &params);
        try writeAll(handle, encoder.getWritten());

        try encoder.encodeExecute("", 0);
        try writeAll(handle, encoder.getWritten());
    }

    try encoder.encodeSync();
    try writeAll(handle, encoder.getWritten());

    return try readBatchResponses(handle, buf, BATCH_SIZE);
}

fn readBatchResponses(handle: posix.fd_t, buf: *[16384]u8, _: u64) !u64 {
    var read_pos: usize = 0;
    var read_len: usize = 0;
    var commands: u64 = 0;

    while (true) {
        while (read_len - read_pos < 5) {
            if (read_pos > 0) {
                const remaining = read_len - read_pos;
                std.mem.copyForwards(u8, buf[0..remaining], buf[read_pos..read_len]);
                read_len = remaining;
                read_pos = 0;
            }
            const n = posix.read(handle, buf[read_len..]) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        const msg_type: BackendMessage = @enumFromInt(buf[read_pos]);
        const length = std.mem.readInt(u32, buf[read_pos + 1 ..][0..4], .big);
        const msg_len = 5 + (length - 4);

        while (read_len - read_pos < msg_len) {
            if (read_pos > 0) {
                const remaining = read_len - read_pos;
                std.mem.copyForwards(u8, buf[0..remaining], buf[read_pos..read_len]);
                read_len = remaining;
                read_pos = 0;
            }
            const n = posix.read(handle, buf[read_len..]) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        read_pos += msg_len;

        switch (msg_type) {
            .command_complete => commands += 1,
            .ready_for_query => return commands,
            .error_response => return error.QueryError,
            else => {},
        }
    }
}

fn readUntilReady(handle: posix.fd_t, buf: *[16384]u8) !void {
    var read_pos: usize = 0;
    var read_len: usize = 0;

    while (true) {
        while (read_len - read_pos < 5) {
            const n = posix.read(handle, buf[read_len..]) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        const msg_type: BackendMessage = @enumFromInt(buf[read_pos]);
        const length = std.mem.readInt(u32, buf[read_pos + 1 ..][0..4], .big);
        read_pos += 5 + (length - 4);

        if (read_pos > read_len) {
            const n = posix.read(handle, buf[read_len..]) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        if (msg_type == .ready_for_query) return;
        if (msg_type == .error_response) return error.ServerError;
    }
}
