//! Async PostgreSQL Connection
//!
//! Non-blocking TCP connection with poll-based I/O and timeouts.
//! Uses std.posix.poll for cross-platform async operations.

const std = @import("std");
const posix = std.posix;
const protocol = @import("../protocol/mod.zig");

const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;

/// Async PostgreSQL connection with timeout support
pub const AsyncConnection = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,
    read_buffer: [8192]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,
    default_timeout_ms: i32 = 30_000, // 30s default

    // Connection state
    process_id: u32 = 0,
    secret_key: u32 = 0,
    ready: bool = false,
    in_transaction: bool = false,

    /// Connect with timeout (milliseconds). Returns error if connection takes too long.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, timeout_ms: i32) !AsyncConnection {
        const address = try std.net.Address.parseIp4(host, port);

        // Create non-blocking socket
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        // Attempt connect (will return EINPROGRESS for non-blocking)
        const result = posix.connect(fd, &address.any, address.getOsSockLen());
        if (result) |_| {
            // Connected immediately
        } else |err| {
            if (err == error.WouldBlock) {
                // Wait for connection with timeout
                if (!try pollWrite(fd, timeout_ms)) {
                    return error.ConnectionTimeout;
                }
                // If poll says writable, connection succeeded (or failed with error on next write)
            } else {
                return err;
            }
        }

        return .{
            .fd = fd,
            .allocator = allocator,
            .default_timeout_ms = timeout_ms,
        };
    }

    pub fn close(self: *AsyncConnection) void {
        posix.close(self.fd);
    }

    /// Send bytes with timeout
    pub fn sendWithTimeout(self: *AsyncConnection, bytes: []const u8, timeout_ms: i32) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            // Wait for socket to be writable
            if (!try pollWrite(self.fd, timeout_ms)) {
                return error.WriteTimeout;
            }

            const n = posix.write(self.fd, bytes[sent..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            sent += n;
        }
    }

    /// Send bytes using default timeout
    pub fn send(self: *AsyncConnection, bytes: []const u8) !void {
        return self.sendWithTimeout(bytes, self.default_timeout_ms);
    }

    /// Receive bytes with timeout. Returns number of bytes read.
    pub fn recvWithTimeout(self: *AsyncConnection, buf: []u8, timeout_ms: i32) !usize {
        // Wait for socket to be readable
        if (!try pollRead(self.fd, timeout_ms)) {
            return error.ReadTimeout;
        }

        const n = posix.read(self.fd, buf) catch |err| {
            if (err == error.WouldBlock) return 0;
            return err;
        };

        if (n == 0) return error.ConnectionClosed;
        return n;
    }

    /// Read a complete PostgreSQL message with timeout
    pub fn readMessage(self: *AsyncConnection) !MessageResult {
        return self.readMessageWithTimeout(self.default_timeout_ms);
    }

    pub const MessageResult = struct { msg_type: BackendMessage, payload: []const u8 };

    pub fn readMessageWithTimeout(self: *AsyncConnection, timeout_ms: i32) !MessageResult {
        // Ensure we have at least 5 bytes (type + length)
        try self.ensureReadWithTimeout(5, timeout_ms);

        const msg_type: BackendMessage = @enumFromInt(self.read_buffer[self.read_pos]);
        const length = std.mem.readInt(u32, self.read_buffer[self.read_pos + 1 ..][0..4], .big);

        // Read full payload
        const payload_len = length - 4;
        try self.ensureReadWithTimeout(5 + payload_len, timeout_ms);

        const payload = self.read_buffer[self.read_pos + 5 .. self.read_pos + 5 + payload_len];
        self.read_pos += 5 + payload_len;

        return .{ .msg_type = msg_type, .payload = payload };
    }

    fn ensureReadWithTimeout(self: *AsyncConnection, needed: usize, timeout_ms: i32) !void {
        while (self.read_len - self.read_pos < needed) {
            // Compact buffer if needed
            if (self.read_pos > 0) {
                const remaining = self.read_len - self.read_pos;
                std.mem.copyForwards(u8, self.read_buffer[0..remaining], self.read_buffer[self.read_pos..self.read_len]);
                self.read_len = remaining;
                self.read_pos = 0;
            }

            // Wait for data with timeout
            if (!try pollRead(self.fd, timeout_ms)) {
                return error.ReadTimeout;
            }

            // Read more data
            const n = posix.read(self.fd, self.read_buffer[self.read_len..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_len += n;
        }
    }

    /// Perform startup handshake with timeout
    pub fn startup(self: *AsyncConnection, user: []const u8, database: []const u8, password: ?[]const u8) !void {
        var encoder = Encoder.init(self.allocator);
        defer encoder.deinit();

        // Send StartupMessage
        try encoder.encodeStartup(user, database);
        try self.send(encoder.getWritten());

        // Handle authentication
        while (!self.ready) {
            const msg = try self.readMessage();

            switch (msg.msg_type) {
                .authentication => {
                    var decoder = Decoder.init(msg.payload);
                    const auth_type = try decoder.parseAuthentication();

                    switch (auth_type) {
                        .ok => {},
                        .cleartext_password => {
                            if (password) |pw| {
                                try encoder.encodePassword(pw);
                                try self.send(encoder.getWritten());
                            } else {
                                return error.PasswordRequired;
                            }
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                .parameter_status => {},
                .backend_key_data => {
                    var decoder = Decoder.init(msg.payload);
                    const key_data = try decoder.parseBackendKeyData();
                    self.process_id = key_data.process_id;
                    self.secret_key = key_data.secret_key;
                },
                .ready_for_query => {
                    var decoder = Decoder.init(msg.payload);
                    const status = try decoder.parseReadyForQuery();
                    self.in_transaction = status == .in_transaction;
                    self.ready = true;
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err_info = try decoder.parseErrorResponse();
                    std.debug.print("Server error: {s}\n", .{err_info.message orelse "unknown"});
                    return error.ServerError;
                },
                else => {},
            }
        }
    }
};

// ==================== Poll Helpers ====================

/// Wait for fd to be readable. Returns true if ready, false if timeout.
fn pollRead(fd: posix.fd_t, timeout_ms: i32) !bool {
    var fds = [1]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };

    const result = try posix.poll(&fds, timeout_ms);
    return result > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

/// Wait for fd to be writable. Returns true if ready, false if timeout.
fn pollWrite(fd: posix.fd_t, timeout_ms: i32) !bool {
    var fds = [1]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 },
    };

    const result = try posix.poll(&fds, timeout_ms);
    return result > 0 and (fds[0].revents & posix.POLL.OUT) != 0;
}

// ==================== Tests ====================

test "AsyncConnection struct" {
    _ = AsyncConnection;
}

test "poll helpers compile" {
    _ = pollRead;
    _ = pollWrite;
}
