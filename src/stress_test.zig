//! QAIL Zig Pipelined Stress Test
//!
//! Uses pipelining with prepared statements for maximum throughput

const std = @import("std");
const qail = @import("qail");

const Encoder = qail.protocol.Encoder;
const Decoder = qail.protocol.Decoder;
const BackendMessage = qail.protocol.BackendMessage;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig - Pipelined 50M Stress Test                      ║\n", .{});
    std.debug.print("║  Using prepared statements + pipelining                    ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Connect to PostgreSQL using raw TCP
    std.debug.print("🔌 Connecting to PostgreSQL...\n", .{});

    const address = try std.net.Address.parseIp4("127.0.0.1", 5432);
    var stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    // Startup
    try encoder.encodeStartup("orion", "postgres");
    try stream.writeAll(encoder.getWritten());

    // Read until ReadyForQuery
    var read_buf: [8192]u8 = undefined;
    try readUntilReady(&stream, &read_buf);

    std.debug.print("✅ Connected!\n\n", .{});

    // Prepare statement once
    std.debug.print("📋 Preparing statement...\n", .{});
    try encoder.encodeParse("s1", "SELECT 1", &.{});
    try stream.writeAll(encoder.getWritten());

    try encoder.encodeSync();
    try stream.writeAll(encoder.getWritten());

    try readUntilReady(&stream, &read_buf);
    std.debug.print("✅ Statement prepared!\n\n", .{});

    // Warmup
    std.debug.print("🔥 Warming up (10K pipelined)...\n", .{});
    _ = try runPipelinedBenchmark(&stream, &encoder, &read_buf, 10_000, 100);

    std.debug.print("\n📊 Running pipelined stress test...\n\n", .{});

    // Progressive benchmark with pipelining
    const runs = [_]u64{ 100_000, 1_000_000, 10_000_000, 50_000_000 };
    const batch_size: u64 = 1000; // Pipeline 1000 queries at a time

    for (runs) |count| {
        const result = try runPipelinedBenchmark(&stream, &encoder, &read_buf, count, batch_size);
        printResult(count, result);
    }

    // Terminate
    try encoder.encodeTerminate();
    try stream.writeAll(encoder.getWritten());

    std.debug.print("\n✅ Pipelined stress test complete!\n", .{});
}

fn runPipelinedBenchmark(stream: *std.net.Stream, encoder: *Encoder, read_buf: *[8192]u8, iterations: u64, batch_size: u64) !u64 {
    const start = std.time.Instant.now() catch unreachable;

    var completed: u64 = 0;
    while (completed < iterations) {
        // Calculate batch for this round
        const remaining = iterations - completed;
        const batch = @min(batch_size, remaining);

        // Pipeline: Send batch of Bind+Execute without waiting
        for (0..batch) |_| {
            // Bind (use prepared statement "s1")
            try encoder.encodeBind("", "s1", &.{});
            try stream.writeAll(encoder.getWritten());

            // Execute
            try encoder.encodeExecute("", 0);
            try stream.writeAll(encoder.getWritten());
        }

        // Sync at end of batch
        try encoder.encodeSync();
        try stream.writeAll(encoder.getWritten());

        // Now read all responses
        try readBatchResponses(stream, read_buf, batch);

        completed += batch;

        // Progress
        if (completed % 1_000_000 == 0) {
            std.debug.print("   Progress: {d}M/{d}M\r", .{ completed / 1_000_000, iterations / 1_000_000 });
        }
    }

    const end = std.time.Instant.now() catch unreachable;
    return end.since(start);
}

fn readBatchResponses(stream: *std.net.Stream, buf: *[8192]u8, expected: u64) !void {
    var read_pos: usize = 0;
    var read_len: usize = 0;
    var responses: u64 = 0;

    while (responses <= expected) {
        // Ensure we have at least 5 bytes
        while (read_len - read_pos < 5) {
            if (read_pos > 0) {
                const remaining = read_len - read_pos;
                std.mem.copyForwards(u8, buf[0..remaining], buf[read_pos..read_len]);
                read_len = remaining;
                read_pos = 0;
            }
            const n = try stream.read(buf[read_len..]);
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        // Read message header
        const msg_type: BackendMessage = @enumFromInt(buf[read_pos]);
        const length = std.mem.readInt(u32, buf[read_pos + 1 ..][0..4], .big);
        const payload_len = length - 4;
        const msg_len = 5 + payload_len;

        // Ensure full message
        while (read_len - read_pos < msg_len) {
            if (read_pos > 0) {
                const remaining = read_len - read_pos;
                std.mem.copyForwards(u8, buf[0..remaining], buf[read_pos..read_len]);
                read_len = remaining;
                read_pos = 0;
            }
            const n = try stream.read(buf[read_len..]);
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

fn readUntilReady(stream: *std.net.Stream, buf: *[8192]u8) !void {
    var read_pos: usize = 0;
    var read_len: usize = 0;

    while (true) {
        while (read_len - read_pos < 5) {
            const n = try stream.read(buf[read_len..]);
            if (n == 0) return error.ConnectionClosed;
            read_len += n;
        }

        const msg_type: BackendMessage = @enumFromInt(buf[read_pos]);
        const length = std.mem.readInt(u32, buf[read_pos + 1 ..][0..4], .big);
        const payload_len = length - 4;
        read_pos += 5 + payload_len;

        if (read_pos > read_len) {
            const n = try stream.read(buf[read_len..]);
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
