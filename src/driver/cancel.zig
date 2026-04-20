//! Query cancellation for PostgreSQL connections.
//!
//! Send a CancelRequest to interrupt a running query.
//! Port of qail.rs/qail-pg/src/driver/cancel.rs

const std = @import("std");
const net = @import("../compat/net.zig");

/// PostgreSQL CancelRequest code: 80877102
const CANCEL_REQUEST_CODE: i32 = 80877102;
pub const MIN_CANCEL_KEY_BYTES: usize = 4;
pub const MAX_CANCEL_KEY_BYTES: usize = 256;

/// Cancel key pair returned from handshake
pub const CancelKey = struct {
    process_id: i32,
    secret_key: i32,
};

/// Send a CancelRequest message to PostgreSQL server.
///
/// This opens a new TCP connection and sends the cancel message.
/// The original connection continues but the query is interrupted.
///
/// Example (AST-native):
/// ```zig
/// const key = conn.getCancelKey();
/// // From another thread/context:
/// try cancelQuery(allocator, "localhost", 5432, key.process_id, key.secret_key);
/// ```
pub fn cancelQueryBytes(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    process_id: i32,
    secret_key_bytes: []const u8,
) !void {
    if (secret_key_bytes.len < MIN_CANCEL_KEY_BYTES or secret_key_bytes.len > MAX_CANCEL_KEY_BYTES) {
        return error.InvalidCancelKeyLength;
    }

    // Connect using Stream
    var stream = net.tcpConnectToHost(allocator, host, port) catch |err| {
        return err;
    };
    defer stream.close();

    // Build CancelRequest message:
    // Length (12 + key_len) + CancelRequest code + process_id + secret_key bytes
    var buf: [12 + MAX_CANCEL_KEY_BYTES]u8 = undefined;
    const total_len: i32 = @intCast(12 + secret_key_bytes.len);
    std.mem.writeInt(i32, buf[0..4], total_len, .big);
    std.mem.writeInt(i32, buf[4..8], CANCEL_REQUEST_CODE, .big);
    std.mem.writeInt(i32, buf[8..12], process_id, .big);
    @memcpy(buf[12 .. 12 + secret_key_bytes.len], secret_key_bytes);

    try stream.writeAll(buf[0..@intCast(total_len)]);
    // Server closes connection after receiving cancel request
}

pub fn cancelQuery(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    process_id: i32,
    secret_key: i32,
) !void {
    var key_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &key_bytes, secret_key, .big);
    try cancelQueryBytes(allocator, host, port, process_id, &key_bytes);
}

// ==================== Tests ====================

test "CancelKey struct" {
    const key = CancelKey{ .process_id = 12345, .secret_key = 67890 };
    try std.testing.expectEqual(@as(i32, 12345), key.process_id);
    try std.testing.expectEqual(@as(i32, 67890), key.secret_key);
}

test "cancel query bytes rejects invalid key lengths" {
    try std.testing.expectError(
        error.InvalidCancelKeyLength,
        cancelQueryBytes(std.testing.allocator, "127.0.0.1", 5432, 1, &.{ 1, 2, 3 }),
    );

    var too_long: [MAX_CANCEL_KEY_BYTES + 1]u8 = [_]u8{0} ** (MAX_CANCEL_KEY_BYTES + 1);
    try std.testing.expectError(
        error.InvalidCancelKeyLength,
        cancelQueryBytes(std.testing.allocator, "127.0.0.1", 5432, 1, &too_long),
    );
}
