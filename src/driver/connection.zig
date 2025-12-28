// PostgreSQL Connection (Zig 0.16 API)
//
// TCP socket connection to PostgreSQL server using new std.Io interface.
// Uses direct posix syscalls for efficient wire protocol I/O.

const std = @import("std");
const protocol = @import("../protocol/mod.zig");

const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const wire = protocol.wire;

/// PostgreSQL connection over TCP using Zig 0.16 Io interface
pub const Connection = struct {
    socket: net.Socket,
    io: Io,
    allocator: std.mem.Allocator,
    read_buffer: [8192]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    // Connection state
    process_id: u32 = 0,
    secret_key: u32 = 0,
    ready: bool = false,
    in_transaction: bool = false,

    pub fn connect(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16) !Connection {
        // Parse IP address
        const address = try net.IpAddress.parseIp4(host, port);

        // Connect using new Io interface
        const stream = try net.IpAddress.connect(address, io, .{ .mode = .stream });

        return .{
            .socket = stream.socket,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Connection) void {
        self.socket.close(self.io);
    }

    /// Send bytes to server using direct posix write
    pub fn send(self: *Connection, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = posix.write(self.socket.handle, bytes[sent..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return error.WriteFailed;
            };
            if (n == 0) return error.ConnectionClosed;
            sent += n;
        }
    }

    /// Read a complete message from server
    /// Returns: (message_type, payload)
    pub fn readMessage(self: *Connection) !struct { msg_type: BackendMessage, payload: []const u8 } {
        // Ensure we have at least 5 bytes (type + length)
        try self.ensureRead(5);

        const msg_type: BackendMessage = @enumFromInt(self.read_buffer[self.read_pos]);
        const length = std.mem.readInt(u32, self.read_buffer[self.read_pos + 1 ..][0..4], .big);

        // Read full payload
        const payload_len = length - 4;
        try self.ensureRead(5 + payload_len);

        const payload = self.read_buffer[self.read_pos + 5 .. self.read_pos + 5 + payload_len];
        self.read_pos += 5 + payload_len;

        return .{ .msg_type = msg_type, .payload = payload };
    }

    fn ensureRead(self: *Connection, needed: usize) !void {
        while (self.read_len - self.read_pos < needed) {
            // Compact buffer if needed
            if (self.read_pos > 0) {
                const remaining = self.read_len - self.read_pos;
                std.mem.copyForwards(u8, self.read_buffer[0..remaining], self.read_buffer[self.read_pos..self.read_len]);
                self.read_len = remaining;
                self.read_pos = 0;
            }

            // Read more data using direct posix read
            const n = posix.read(self.socket.handle, self.read_buffer[self.read_len..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return error.ReadFailed;
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_len += n;
        }
    }

    /// Perform startup handshake
    pub fn startup(self: *Connection, user: []const u8, database: []const u8, password: ?[]const u8) !void {
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
                        .ok => {}, // Auth successful
                        .cleartext_password => {
                            if (password) |pw| {
                                try encoder.encodePassword(pw);
                                try self.send(encoder.getWritten());
                            } else {
                                return error.PasswordRequired;
                            }
                        },
                        .md5_password => {
                            // TODO: Implement MD5 auth
                            return error.UnsupportedAuth;
                        },
                        .sasl => {
                            // TODO: Implement SCRAM auth
                            return error.UnsupportedAuth;
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                .parameter_status => {
                    // Ignore parameter status messages
                },
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
