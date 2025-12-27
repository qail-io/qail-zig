//! PostgreSQL TLS/SSL Connection
//!
//! Full TLS 1.3 implementation using std.crypto.tls.Client.
//!
//! PostgreSQL SSL Handshake Flow:
//! 1. TCP connect
//! 2. Send SSLRequest message (8 bytes)
//! 3. Server responds 'S' (SSL accepted) or 'N' (not supported)
//! 4. If 'S', TLS handshake via std.crypto.tls.Client
//! 5. Continue with StartupMessage over TLS

const std = @import("std");
const tls = std.crypto.tls;
const protocol = @import("../protocol/mod.zig");
const tls_mod = @import("tls/mod.zig");

const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;

const StreamReader = tls_mod.StreamReader;
const StreamWriter = tls_mod.StreamWriter;
const TlsBuffers = tls_mod.TlsBuffers;
pub const TlsConfig = tls_mod.TlsConfig;
pub const VerifyMode = tls_mod.VerifyMode;

/// SSL Request code (80877103 = version 1234.5679)
pub const SSL_REQUEST_CODE: u32 = 80877103;

/// TLS-secured PostgreSQL connection
///
/// Provides encrypted communication using std.crypto.tls.Client (TLS 1.3).
/// Falls back to plain connection if server doesn't support SSL.
pub const TlsConnection = struct {
    allocator: std.mem.Allocator,
    tcp_stream: std.net.Stream,

    // TLS components
    tls_buffers: TlsBuffers,
    tls_client: ?tls.Client = null,
    stream_reader: ?StreamReader = null,
    stream_writer: ?StreamWriter = null,

    // Connection state
    ssl_enabled: bool = false,
    ssl_accepted: bool = false,
    process_id: u32 = 0,
    secret_key: u32 = 0,
    ready: bool = false,

    // PostgreSQL message buffer
    pg_read_buffer: [16384]u8 = undefined,
    pg_read_pos: usize = 0,
    pg_read_len: usize = 0,

    /// Connect with TLS negotiation.
    ///
    /// If server accepts SSL, performs TLS 1.3 handshake.
    /// Falls back to plain connection if server doesn't support SSL.
    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        config: TlsConfig,
    ) !TlsConnection {
        const address = try std.net.Address.parseIp4(host, port);
        const tcp_stream = try std.net.tcpConnectToAddress(address);
        errdefer tcp_stream.close();

        var conn = TlsConnection{
            .allocator = allocator,
            .tcp_stream = tcp_stream,
            .tls_buffers = TlsBuffers.initSecure(),
        };

        // Request SSL upgrade
        conn.ssl_accepted = try conn.requestSsl();

        if (conn.ssl_accepted) {
            // Initialize TLS
            try conn.initTls(config, host);
        }

        return conn;
    }

    /// Send SSLRequest to server
    fn requestSsl(self: *TlsConnection) !bool {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 8, .big);
        std.mem.writeInt(u32, buf[4..8], SSL_REQUEST_CODE, .big);
        try self.tcp_stream.writeAll(&buf);

        var response: [1]u8 = undefined;
        _ = try self.tcp_stream.read(&response);

        return response[0] == 'S';
    }

    /// Initialize TLS handshake using std.crypto.tls.Client
    fn initTls(self: *TlsConnection, config: TlsConfig, host: []const u8) !void {
        // Create stream wrappers
        self.stream_reader = StreamReader.init(self.tcp_stream, self.tls_buffers.readBuffer());
        self.stream_writer = StreamWriter.init(self.tcp_stream, self.tls_buffers.writeBuffer());

        // Build TLS options
        const tls_options = tls_mod.config.buildClientOptions(
            .{
                .server_name = config.server_name orelse host,
                .verify = config.verify,
            },
            self.tls_buffers.readBuffer(),
            self.tls_buffers.writeBuffer(),
            self.tls_buffers.entropyPtr(),
        );

        // Initialize TLS client (performs handshake)
        self.tls_client = try tls.Client.init(&self.stream_reader.?, &self.stream_writer.?, tls_options);
        self.ssl_enabled = true;
    }

    pub fn close(self: *TlsConnection) void {
        self.tcp_stream.close();
    }

    /// Check if connection is using TLS encryption
    pub fn isTls(self: *const TlsConnection) bool {
        return self.ssl_enabled;
    }

    /// Check if server accepted SSL (even if TLS not fully enabled)
    pub fn sslAccepted(self: *const TlsConnection) bool {
        return self.ssl_accepted;
    }

    /// Send bytes (encrypted if TLS enabled)
    pub fn send(self: *TlsConnection, bytes: []const u8) !void {
        if (self.tls_client) |*client| {
            try client.writer.writeAll(bytes);
            try client.writer.flush();
        } else {
            try self.tcp_stream.writeAll(bytes);
        }
    }

    /// Read bytes (decrypted if TLS enabled)
    fn readBytes(self: *TlsConnection, buf: []u8) !usize {
        if (self.tls_client) |*client| {
            return client.reader.read(buf);
        } else {
            return self.tcp_stream.read(buf);
        }
    }

    /// Read a complete PostgreSQL message
    pub fn readMessage(self: *TlsConnection) !struct { msg_type: BackendMessage, payload: []const u8 } {
        try self.ensurePgRead(5);

        const msg_type: BackendMessage = @enumFromInt(self.pg_read_buffer[self.pg_read_pos]);
        const length = std.mem.readInt(u32, self.pg_read_buffer[self.pg_read_pos + 1 ..][0..4], .big);
        const payload_len = length - 4;

        try self.ensurePgRead(5 + payload_len);

        const payload = self.pg_read_buffer[self.pg_read_pos + 5 .. self.pg_read_pos + 5 + payload_len];
        self.pg_read_pos += 5 + payload_len;

        return .{ .msg_type = msg_type, .payload = payload };
    }

    fn ensurePgRead(self: *TlsConnection, needed: usize) !void {
        while (self.pg_read_len - self.pg_read_pos < needed) {
            if (self.pg_read_pos > 0) {
                const remaining = self.pg_read_len - self.pg_read_pos;
                std.mem.copyForwards(u8, self.pg_read_buffer[0..remaining], self.pg_read_buffer[self.pg_read_pos..self.pg_read_len]);
                self.pg_read_len = remaining;
                self.pg_read_pos = 0;
            }

            const n = try self.readBytes(self.pg_read_buffer[self.pg_read_len..]);
            if (n == 0) return error.ConnectionClosed;
            self.pg_read_len += n;
        }
    }

    /// Perform PostgreSQL startup handshake
    pub fn startup(self: *TlsConnection, user: []const u8, database: []const u8, password: ?[]const u8) !void {
        var encoder = Encoder.init(self.allocator);
        defer encoder.deinit();

        try encoder.encodeStartup(user, database);
        try self.send(encoder.getWritten());

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
                    self.ready = true;
                },
                .error_response => {
                    return error.ServerError;
                },
                else => {},
            }
        }
    }
};

// ==================== Tests ====================

test "TlsConnection struct" {
    _ = TlsConnection;
    _ = TlsConfig;
    _ = VerifyMode;
}

test "SSL request code" {
    try std.testing.expectEqual(@as(u32, 80877103), SSL_REQUEST_CODE);
}
