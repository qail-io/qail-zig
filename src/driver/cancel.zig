//! Query cancellation for PostgreSQL connections.
//!
//! Send a CancelRequest to interrupt a running query.
//! Port of qail.rs/qail-pg/src/driver/cancel.rs

const std = @import("std");

/// PostgreSQL CancelRequest code: 80877102
const CANCEL_REQUEST_CODE: i32 = 80877102;

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
pub fn cancelQuery(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    process_id: i32,
    secret_key: i32,
) !void {
    // Create address string
    const addr_str = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
    defer allocator.free(addr_str);

    // Connect using Stream
    var stream = std.net.tcpConnectToHost(allocator, host, port) catch |err| {
        return err;
    };
    defer stream.close();

    // Build CancelRequest message:
    // Length (16) + CancelRequest code + process_id + secret_key
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i32, buf[0..4], 16, .big);
    std.mem.writeInt(i32, buf[4..8], CANCEL_REQUEST_CODE, .big);
    std.mem.writeInt(i32, buf[8..12], process_id, .big);
    std.mem.writeInt(i32, buf[12..16], secret_key, .big);

    _ = try stream.write(&buf);
    // Server closes connection after receiving cancel request
}

// ==================== Tests ====================

test "CancelKey struct" {
    const key = CancelKey{ .process_id = 12345, .secret_key = 67890 };
    try std.testing.expectEqual(@as(i32, 12345), key.process_id);
    try std.testing.expectEqual(@as(i32, 67890), key.secret_key);
}
