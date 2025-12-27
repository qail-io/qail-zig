//! Verification Benchmark - Audits byte counts and message types
//! Run: zig build verify

const std = @import("std");
const driver = @import("driver/mod.zig");
const protocol = @import("protocol/mod.zig");

const Connection = driver.Connection;
const Encoder = protocol.Encoder;

// Expected: ~50 bytes per query response (T + D + C)
// 100 queries = ~5000 bytes
const QUERIES_PER_BATCH: usize = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("🔍 Verifying response sizes and message counts...\n", .{});

    var conn = try Connection.connect(allocator, "127.0.0.1", 5432);
    defer conn.close();

    try conn.startup("orion", "postgres", null);

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    // Prepare statement
    const stmt_name = "verify_test";
    try encoder.encodeParse(stmt_name, "SELECT id, name FROM harbors LIMIT $1", &[_]u32{23});
    try conn.stream.writeAll(encoder.getWritten());
    try encoder.encodeSync();
    try conn.stream.writeAll(encoder.getWritten());

    var read_buf: [65536]u8 = undefined;
    const n_prep = try conn.stream.read(&read_buf); // Parse response
    std.debug.print("Prepare Response ({} bytes): {any}\n", .{ n_prep, read_buf[0..n_prep] });

    std.debug.print("✅ Statement prepared\n\n", .{});

    // Run 10 batches and audit bytes
    var total_bytes_read: usize = 0;
    var total_commands: usize = 0;
    var total_rows: usize = 0;

    for (0..10) |batch| {
        encoder.reset();
        for (0..QUERIES_PER_BATCH) |i| {
            const limit_val: i32 = @intCast((i % 10) + 1);
            var limit_buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &limit_buf, limit_val, .big);
            try encoder.appendBind("", stmt_name, &[_]?[]const u8{&limit_buf});
            try encoder.appendExecute("", 0);
        }
        try encoder.appendSync();
        try conn.stream.writeAll(encoder.getWritten());

        // Read and Count
        var batch_bytes: usize = 0;
        var batch_commands: usize = 0;
        var read_pos: usize = 0;
        var read_len: usize = 0;

        while (true) {
            // Read until we frame a message
            while (read_len - read_pos < 5) {
                if (read_pos > 0) {
                    const remaining = read_len - read_pos;
                    std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[read_pos..read_len]);
                    read_len = remaining;
                    read_pos = 0;
                }
                const n = try conn.stream.read(read_buf[read_len..]);
                if (n == 0) return error.ConnectionClosed;
                read_len += n;
                batch_bytes += n;
            }

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
                const n = try conn.stream.read(read_buf[read_len..]);
                if (n == 0) return error.ConnectionClosed;
                read_len += n;
                batch_bytes += n;
            }

            // Process message
            switch (msg_type) {
                'D' => total_rows += 1,
                'C' => {
                    batch_commands += 1;
                    total_commands += 1;
                    read_pos += msg_len;
                },
                'Z' => {
                    read_pos += msg_len;
                    break; // ReadyForQuery
                },
                'E' => {
                    std.debug.print("❌ ERROR RESPONSE! Raw bytes: {any}\n", .{read_buf[read_pos .. read_pos + msg_len]});

                    // Parse error fields
                    var err_pos = read_pos + 5;
                    const err_end = read_pos + msg_len;

                    while (err_pos < err_end) {
                        const field_type = read_buf[err_pos];
                        if (field_type == 0) break; // Null terminator for fields
                        err_pos += 1;

                        const str_start = err_pos;
                        // Find null terminator for string
                        while (err_pos < err_end and read_buf[err_pos] != 0) : (err_pos += 1) {}

                        if (err_pos < err_end) {
                            const val = read_buf[str_start..err_pos];
                            std.debug.print("  {c}: {s}\n", .{ field_type, val });
                            err_pos += 1; // Skip null terminator
                        }
                    }
                    return error.PostgresError;
                },
                else => {
                    read_pos += msg_len;
                },
            }
        }

        std.debug.print("Batch {}: {} bytes read, {} commands\n", .{ batch, batch_bytes, batch_commands });
        total_bytes_read += batch_bytes;
    }

    std.debug.print("\n📊 Verification Results (10 batches):\n", .{});
    std.debug.print("  Total Bytes Read: {}\n", .{total_bytes_read});
    std.debug.print("  Total Commands:   {} (Expected: 1000)\n", .{total_commands});
    std.debug.print("  Avg Bytes/Query:  {d:.1}\n", .{@as(f64, @floatFromInt(total_bytes_read)) / 1000.0});

    if (total_commands != 1000) {
        std.debug.print("❌ FAILED: Did not receive all query responses!\n", .{});
    } else if (total_bytes_read < 40000) {
        std.debug.print("❌ FAILED: Bytes read too low (~40 bytes/query minimum expected)\n", .{});
    } else {
        std.debug.print("✅ PASSED: Received full response data\n", .{});
    }
}
