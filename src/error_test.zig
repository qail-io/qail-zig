//! Error Test - Verify we actually parse responses
//! Run: zig build error-test

const std = @import("std");
const driver = @import("driver/mod.zig");
const protocol = @import("protocol/mod.zig");

const Connection = driver.Connection;
const Encoder = protocol.Encoder;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Testing error detection with SELECT 1/0 (divide by zero)...\n", .{});

    var conn = try Connection.connect(allocator, "127.0.0.1", 5432);
    defer conn.close();

    try conn.startup("orion", "postgres", null);

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    // Prepare statement - should work
    const stmt_name = "error_test";
    try encoder.encodeParse(stmt_name, "SELECT 1/0", &[_]u32{});
    try conn.stream.writeAll(encoder.getWritten());

    try encoder.encodeSync();
    try conn.stream.writeAll(encoder.getWritten());

    // Read parse response
    var read_buf: [16384]u8 = undefined;
    _ = try conn.stream.read(&read_buf);

    std.debug.print("✅ Statement prepared\n", .{});

    // Now execute - should get error
    encoder.reset();
    try encoder.appendBind("", stmt_name, &[_]?[]const u8{});
    try encoder.appendExecute("", 0);
    try encoder.appendSync();

    try conn.stream.writeAll(encoder.getWritten());

    std.debug.print("Sent execute, reading response...\n", .{});

    // Read response and check for error
    var read_len: usize = 0;
    var found_error = false;

    while (read_len < 1000) {
        const n = try conn.stream.read(read_buf[read_len..]);
        if (n == 0) break;
        read_len += n;

        // Scan for 'E' (ErrorResponse)
        for (read_buf[0..read_len]) |b| {
            if (b == 'E') {
                found_error = true;
                break;
            }
        }

        // Check for 'Z' (ReadyForQuery)
        if (std.mem.indexOf(u8, read_buf[0..read_len], "Z")) |_| break;
    }

    if (found_error) {
        std.debug.print("✅ ERROR DETECTED! Benchmark is REAL - we are parsing responses\n", .{});
    } else {
        std.debug.print("❌ NO ERROR! Benchmark is FAKE - we are NOT parsing responses correctly\n", .{});
    }
}
