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
const net = @import("../compat/net.zig");
const protocol = @import("../protocol/mod.zig");
const tls_mod = @import("tls/mod.zig");

const Encoder = protocol.Encoder;
const StartupParam = Encoder.StartupParam;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const auth = protocol.auth;
const auth_options_mod = @import("auth_options.zig");
pub const AuthOptions = auth_options_mod.AuthOptions;

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
    tcp_stream: net.Stream,

    // TLS components
    tls_buffers: TlsBuffers,
    tls_client: ?tls.Client = null,
    stream_reader: ?net.StreamReader = null,
    stream_writer: ?net.StreamWriter = null,
    tls_server_end_point_binding: ?[]u8 = null,

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
        return connectFromStream(allocator, host, config, try net.tcpConnectToAddress(try net.parseIp4(host, port)));
    }

    /// Connect with TCP connect timeout (milliseconds) + TLS negotiation.
    ///
    /// Timeout applies to the initial TCP connect phase.
    pub fn connectWithTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        config: TlsConfig,
        timeout_ms: i32,
    ) !TlsConnection {
        return connectFromStream(allocator, host, config, try net.tcpConnectToIp4WithTimeout(host, port, timeout_ms));
    }

    fn connectFromStream(
        allocator: std.mem.Allocator,
        host: []const u8,
        config: TlsConfig,
        tcp_stream: net.Stream,
    ) !TlsConnection {
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
        try net.writeAllStream(self.tcp_stream, &buf);

        var response: [1]u8 = undefined;
        const read_n = try net.readStream(self.tcp_stream, &response);
        if (read_n != 1) return error.EndOfStream;

        return response[0] == 'S';
    }

    /// Initialize TLS handshake using std.crypto.tls.Client
    fn initTls(self: *TlsConnection, config: TlsConfig, host: []const u8) !void {
        self.stream_reader = net.streamReader(self.tcp_stream, self.tls_buffers.readBuffer());
        self.stream_writer = net.streamWriter(self.tcp_stream, self.tls_buffers.writeBuffer());

        // Build TLS options
        const tls_options = tls_mod.config.buildClientOptions(
            .{
                .server_name = config.server_name orelse host,
                .verify = config.verify,
            },
            self.tls_buffers.readBuffer(),
            self.tls_buffers.writeBuffer(),
        );

        // Initialize TLS client (performs handshake)
        self.tls_client = try net.initTlsClient(&self.stream_reader.?, &self.stream_writer.?, tls_options);
        self.ssl_enabled = true;

        if (config.tls_server_end_point_cert_der) |cert_der| {
            self.tls_server_end_point_binding = try tls_mod.config.deriveTlsServerEndPointBindingFromCertDer(
                self.allocator,
                cert_der,
            );
        }
    }

    pub fn close(self: *TlsConnection) void {
        if (self.tls_server_end_point_binding) |binding| {
            self.allocator.free(binding);
            self.tls_server_end_point_binding = null;
        }
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

    /// Derived SCRAM `tls-server-end-point` bytes, when configured.
    pub fn tlsServerEndPointBinding(self: *const TlsConnection) ?[]const u8 {
        return self.tls_server_end_point_binding;
    }

    /// Send bytes (encrypted if TLS enabled)
    pub fn send(self: *TlsConnection, bytes: []const u8) !void {
        if (self.tls_client) |*client| {
            try client.writer.writeAll(bytes);
            try client.writer.flush();
        } else {
            try net.writeAllStream(self.tcp_stream, bytes);
        }
    }

    /// Read bytes (decrypted if TLS enabled)
    fn readBytes(self: *TlsConnection, buf: []u8) !usize {
        if (self.tls_client) |*client| {
            return client.reader.readSliceShort(buf);
        } else {
            return net.readStream(self.tcp_stream, buf);
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
        return self.startupWithParamsAndAuth(user, database, password, &.{}, .{});
    }

    /// Perform PostgreSQL startup handshake with additional startup parameters.
    pub fn startupWithParams(
        self: *TlsConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        extra_params: []const StartupParam,
    ) !void {
        return self.startupWithParamsAndAuth(user, database, password, extra_params, .{});
    }

    /// Perform PostgreSQL startup handshake with auth options.
    pub fn startupWithAuthOptions(
        self: *TlsConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        auth_options: AuthOptions,
    ) !void {
        return self.startupWithParamsAndAuth(user, database, password, &.{}, auth_options);
    }

    /// Perform PostgreSQL startup handshake with startup params and auth options.
    pub fn startupWithParamsAndAuth(
        self: *TlsConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        extra_params: []const StartupParam,
        auth_options: AuthOptions,
    ) !void {
        var effective_auth_options = auth_options;
        if (effective_auth_options.scram_tls_server_end_point_binding == null) {
            effective_auth_options.scram_tls_server_end_point_binding = self.tls_server_end_point_binding;
        }

        var encoder = Encoder.init(self.allocator);
        defer encoder.deinit();
        var scram_client: ?auth.ScramClient = null;
        defer {
            if (scram_client) |*client| {
                client.deinit();
            }
        }
        var waiting_for_scram_final = false;
        var gss_mechanism: ?auth_options_mod.GssMechanism = null;
        var gss_roundtrips: u32 = 0;
        const AuthFlow = enum { none, cleartext, md5, sasl, gss };
        var auth_flow: AuthFlow = .none;
        var auth_ok = false;
        var sasl_complete = false;

        try encoder.encodeStartupWithParams(user, database, extra_params);
        try self.send(encoder.getWritten());

        while (!self.ready) {
            const msg = try self.readMessage();

            switch (msg.msg_type) {
                .authentication => {
                    var decoder = Decoder.init(msg.payload);
                    const auth_type = try decoder.parseAuthentication();
                    if (auth_ok) return error.AuthenticationAfterOk;

                    switch (auth_type) {
                        .ok => {
                            if (auth_flow == .sasl and !sasl_complete) return error.AuthenticationOkBeforeSaslFinal;
                            if (waiting_for_scram_final) return error.InvalidScramState;
                            gss_mechanism = null;
                            gss_roundtrips = 0;
                            auth_flow = .none;
                            auth_ok = true;
                        },
                        .cleartext_password => {
                            if (auth_flow != .none and auth_flow != .cleartext) return error.AuthenticationMethodSwitch;
                            auth_flow = .cleartext;
                            if (!auth_options_mod.authTypeAllowed(effective_auth_options, .cleartext_password)) return error.AuthMechanismDisabled;
                            if (password) |pw| {
                                try encoder.encodePassword(pw);
                                try self.send(encoder.getWritten());
                            } else {
                                return error.PasswordRequired;
                            }
                        },
                        .md5_password => {
                            if (auth_flow != .none and auth_flow != .md5) return error.AuthenticationMethodSwitch;
                            auth_flow = .md5;
                            if (!auth_options_mod.authTypeAllowed(effective_auth_options, .md5_password)) return error.AuthMechanismDisabled;
                            const salt = try decoder.parseAuthenticationMd5Salt();
                            if (password) |pw| {
                                const md5_password = auth.md5Password(pw, user, salt);
                                try encoder.encodePassword(md5_password[0..]);
                                try self.send(encoder.getWritten());
                            } else {
                                return error.PasswordRequired;
                            }
                        },
                        .kerberos_v5, .gss, .sspi => {
                            if (auth_flow != .none and auth_flow != .gss) return error.AuthenticationMethodSwitch;
                            auth_flow = .gss;
                            if (!auth_options_mod.authTypeAllowed(effective_auth_options, auth_type)) return error.AuthMechanismDisabled;
                            const mechanism = auth_options_mod.mechanismFromAuthType(auth_type).?;
                            const token = try auth_options_mod.requestGssToken(effective_auth_options, mechanism, null, self.allocator);
                            if (token.len != 0) {
                                try encoder.encodeSaslResponse(token);
                                try self.send(encoder.getWritten());
                            }
                            gss_mechanism = mechanism;
                            gss_roundtrips = 0;
                        },
                        .gss_continue => {
                            if (auth_flow != .gss) return error.InvalidGssState;
                            const mechanism = gss_mechanism orelse return error.InvalidGssState;
                            gss_roundtrips += 1;
                            if (gss_roundtrips > effective_auth_options.max_gss_roundtrips) return error.GssRoundtripLimitExceeded;

                            const server_token = try decoder.parseAuthenticationSaslData();
                            const token = try auth_options_mod.requestGssToken(effective_auth_options, mechanism, server_token, self.allocator);
                            if (token.len != 0) {
                                try encoder.encodeSaslResponse(token);
                                try self.send(encoder.getWritten());
                            }
                        },
                        .sasl => {
                            if (auth_flow != .none and auth_flow != .sasl) return error.AuthenticationMethodSwitch;
                            auth_flow = .sasl;
                            sasl_complete = false;
                            if (!auth_options_mod.authTypeAllowed(effective_auth_options, .sasl)) return error.AuthMechanismDisabled;
                            const mechanisms = try decoder.parseAuthenticationSaslMechanisms(self.allocator);
                            defer self.allocator.free(mechanisms);

                            if (password == null) return error.PasswordRequired;
                            const selection = try auth_options_mod.selectScramMechanism(
                                mechanisms,
                                effective_auth_options.scram_tls_server_end_point_binding,
                                effective_auth_options.scram_channel_binding,
                            );

                            if (scram_client) |*client| {
                                client.deinit();
                            }
                            var client = if (selection.channel_binding_data) |binding|
                                try auth.ScramClient.initWithTlsServerEndPoint(self.allocator, user, password.?, binding)
                            else
                                auth.ScramClient.init(self.allocator, user, password.?);
                            const first = try client.clientFirstMessage();
                            defer self.allocator.free(first);

                            try encoder.encodeSaslInitialResponse(selection.mechanism, first);
                            try self.send(encoder.getWritten());

                            scram_client = client;
                            waiting_for_scram_final = false;
                            gss_mechanism = null;
                            gss_roundtrips = 0;
                        },
                        .sasl_continue => {
                            if (auth_flow != .sasl) return error.InvalidScramState;
                            sasl_complete = false;
                            const server_first = try decoder.parseAuthenticationSaslData();
                            if (scram_client == null) return error.InvalidScramState;
                            const client = &scram_client.?;

                            const final = try client.processServerFirst(server_first);
                            defer self.allocator.free(final);

                            try encoder.encodeSaslResponse(final);
                            try self.send(encoder.getWritten());
                            waiting_for_scram_final = true;
                        },
                        .sasl_final => {
                            if (auth_flow != .sasl) return error.InvalidScramState;
                            const server_final = try decoder.parseAuthenticationSaslData();
                            if (scram_client == null) return error.InvalidScramState;
                            const client = &scram_client.?;
                            try client.verifyServerFinal(server_final);
                            waiting_for_scram_final = false;
                            sasl_complete = true;
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                .parameter_status => {
                    if (!auth_ok) return error.ParameterStatusBeforeAuthOk;
                },
                .backend_key_data => {
                    if (!auth_ok) return error.BackendKeyBeforeAuthOk;
                    var decoder = Decoder.init(msg.payload);
                    const key_data = try decoder.parseBackendKeyData();
                    self.process_id = key_data.process_id;
                    self.secret_key = key_data.secret_key;
                },
                .ready_for_query => {
                    if (!auth_ok) return error.StartupCompletedWithoutAuthOk;
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
