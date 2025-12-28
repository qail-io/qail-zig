// QAIL Zig Pipelined Stress Test (Zig 0.16 API)
//
// Uses pipelining with prepared statements for maximum throughput

const std = @import("std");
const qail = @import("qail");

const Io = std.Io;
const Threaded = Io.Threaded;
const net = Io.net;
const posix = std.posix;
const Encoder = qail.protocol.Encoder;
const Decoder = qail.protocol.Decoder;
const BackendMessage = qail.protocol.BackendMessage;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig - Pipelined 50M Stress Test (Zig 0.16)           ║\n", .{});
    std.debug.print("║  Using prepared statements + pipelining                    ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create Io instance (Zig 0.16 pattern)
    var threaded = Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Connect to PostgreSQL using Zig 0.16 net API
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

    // Read until ReadyForQuery
    var read_buf: [8192]u8 = undefined;
    try readUntilReady(handle, &read_buf);

    std.debug.print("✅ Connected!\n\n", .{});

    // Prepare statement once
    std.debug.print("📋 Preparing statement...\n", .{});
    try encoder.encodeParse("s1", "SELECT 1", &.{});
    try writeAll(handle, encoder.getWritten());

    try encoder.encodeSync();
    try writeAll(handle, encoder.getWritten());

    try readUntilReady(handle, &read_buf);
    std.debug.print("✅ Statement prepared!\n\n", .{});

    // Warmup
    std.debug.print("🔥 Warming up (10K pipelined)...\n", .{});
    _ = try runPipelinedBenchmark(handle, &encoder, &read_buf, 10_000, 100);

    std.debug.print("\n📊 Running pipelined stress test...\n\n", .{});

    // Progressive benchmark with pipelining
    const runs = [_]u64{ 100_000, 1_000_000, 10_000_000, 50_000_000 };
    const batch_size: u64 = 1000;

    for (runs) |count| {
        const result = try runPipelinedBenchmark(handle, &encoder, &read_buf, count, batch_size);
        printResult(count, result);
    }

    // Terminate
    try encoder.encodeTerminate();
    try writeAll(handle, encoder.getWritten());

    std.debug.print("\n✅ Pipelined stress test complete!\n", .{});
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

fn runPipelinedBenchmark(handle: posix.fd_t, encoder: *Encoder, read_buf: *[8192]u8, iterations: u64, batch_size: u64) !u64 {
    const start = std.time.Instant.now() catch unreachable;

    var completed: u64 = 0;
    while (completed < iterations) {
        const remaining = iterations - completed;
        const batch = @min(batch_size, remaining);

        // Pipeline: Send batch of Bind+Execute without waiting
        for (0..batch) |_| {
            try encoder.encodeBind("", "s1", &.{});
            try writeAll(handle, encoder.getWritten());

            try encoder.encodeExecute("", 0);
            try writeAll(handle, encoder.getWritten());
        }

        // Sync at end of batch
        try encoder.encodeSync();
        try writeAll(handle, encoder.getWritten());

        // Now read all responses
        try readBatchResponses(handle, read_buf, batch);

        completed += batch;

        if (completed % 1_000_000 == 0) {
            std.debug.print("   Progress: {d}M/{d}M\r", .{ completed / 1_000_000, iterations / 1_000_000 });
        }
    }

    const end = std.time.Instant.now() catch unreachable;
    return end.since(start);
}

fn readBatchResponses(handle: posix.fd_t, buf: *[8192]u8, expected: u64) !void {
    var read_pos: usize = 0;
    var read_len: usize = 0;
    var responses: u64 = 0;

    while (responses <= expected) {
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
        const payload_len = length - 4;
        const msg_len = 5 + payload_len;

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
            .bind_complete => {},
            .data_row => {},
            .command_complete => responses += 1,
            .ready_for_query => return,
            .error_response => return error.QueryError,
            else => {},
        }
    }
}

fn readUntilReady(handle: posix.fd_t, buf: *[8192]u8) !void {
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
        const payload_len = length - 4;
        read_pos += 5 + payload_len;

        if (read_pos > read_len) {
            const n = posix.read(handle, buf[read_len..]) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        if (msg_type == .ready_for_query) return;
        if (msg_type == .error_response) {
            std.debug.print("Server error during startup\n", .{});
            return error.ServerError;
        }
    }
}

fn printResult(iterations: u64, nanos: u64) void {
    const ms = @as(f64, @floatFromInt(nanos)) / 1_000_000.0;
    const seconds = ms / 1000.0;
    const per_op_us = @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(iterations)) / 1000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / seconds;

    if (iterations >= 1_000_000) {
        std.debug.print("  {d:>3}M queries: {d:>8.2}s  ({d:>6.2} µs/query, {d:>10.0} qps)\n", .{
            iterations / 1_000_000,
            seconds,
            per_op_us,
            ops_per_sec,
        });
    } else {
        std.debug.print("  {d:>3}K queries: {d:>8.2}s  ({d:>6.2} µs/query, {d:>10.0} qps)\n", .{
            iterations / 1_000,
            seconds,
            per_op_us,
            ops_per_sec,
        });
    }
}
