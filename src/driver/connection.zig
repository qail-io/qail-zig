// PostgreSQL Connection
//
// TCP socket connection to PostgreSQL server.

const std = @import("std");
const net = @import("../runtime/net.zig");
const protocol = @import("../protocol/mod.zig");
const io_backend_mod = @import("io_backend.zig");

const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const auth = protocol.auth;
const StartupParam = Encoder.StartupParam;
const auth_options_mod = @import("auth_options.zig");
pub const AuthOptions = auth_options_mod.AuthOptions;
const read_buffer_size = 524_288;

/// PostgreSQL connection over TCP
pub const Connection = struct {
    stream: io_backend_mod.Stream,
    allocator: std.mem.Allocator,
    io_backend: io_backend_mod.Backend = .sync,
    read_buffer: [read_buffer_size]u8 = undefined,
    read_pos: usize = 0,
    read_len: usize = 0,

    // Connection state
    process_id: u32 = 0,
    secret_key: u32 = 0,
    cancel_key_len: u16 = 0,
    cancel_key: [256]u8 = [_]u8{0} ** 256,
    ready: bool = false,
    in_transaction: bool = false,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection {
        const selected_backend = io_backend_mod.detectWithEnv(allocator);
        const connected = try io_backend_mod.connectToHost(selected_backend, allocator, host, port);

        return .{
            .stream = connected.stream,
            .allocator = allocator,
            .io_backend = connected.backend,
        };
    }

    /// Connect with timeout (milliseconds). Uses non-blocking socket + poll.
    pub fn connectWithTimeout(allocator: std.mem.Allocator, host: []const u8, port: u16, timeout_ms: i32) !Connection {
        const selected_backend = io_backend_mod.detectWithEnv(allocator);
        const connected = try io_backend_mod.connectToHostWithTimeout(selected_backend, allocator, host, port, timeout_ms);

        return .{
            .stream = connected.stream,
            .allocator = allocator,
            .io_backend = connected.backend,
        };
    }

    /// Active backend selected for plain TCP transport.
    pub fn ioBackend(self: *const Connection) io_backend_mod.Backend {
        return self.io_backend;
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }

    /// Send bytes to server
    pub fn send(self: *Connection, bytes: []const u8) !void {
        try self.stream.writeAll(bytes);
    }

    /// Read a complete message from server
    /// Returns: (message_type, payload)
    pub fn readMessage(self: *Connection) !struct { msg_type: BackendMessage, payload: []const u8 } {
        const raw = try self.readMessageRawFast();
        const msg_type: BackendMessage = @enumFromInt(raw.msg_type);
        return .{
            .msg_type = msg_type,
            .payload = raw.payload,
        };
    }

    pub const CompletionDrain = struct {
        completed: usize,
        saw_error: bool,
    };

    /// Consume backend frames until `ReadyForQuery`, counting `CommandComplete`
    /// and `NoData` completions in a tight in-buffer loop.
    pub fn countCompletionsUntilReadyFast(self: *Connection, expected: usize) !CompletionDrain {
        var completed: usize = 0;
        var saw_error = false;

        while (true) {
            while (self.read_len - self.read_pos >= 5) {
                const pos = self.read_pos;
                const length = std.mem.readInt(u32, self.read_buffer[pos + 1 ..][0..4], .big);
                const len_field: usize = @intCast(length);

                if (len_field < 4) return error.InvalidMessageLength;
                if (len_field > self.read_buffer.len - 1) return error.MessageTooLarge;

                const total_len = len_field + 1;
                if (self.read_len - pos < total_len) break;

                const msg_type = self.read_buffer[pos];
                const payload = self.read_buffer[pos + 5 .. pos + total_len];
                self.read_pos = pos + total_len;
                try Decoder.validateBackendMessagePayloadByte(msg_type, payload);

                switch (msg_type) {
                    'C', 'n' => {
                        completed += 1;
                        if (completed > expected) return error.UnexpectedCompletionCount;
                    },
                    'E' => saw_error = true,
                    'Z' => return .{ .completed = completed, .saw_error = saw_error },
                    else => {},
                }
            }

            try self.readMore();
        }
    }

    /// Read and skip a complete message, returning only message type.
    ///
    /// Useful for throughput-oriented loops that only need completion counting.
    pub fn readMessageTypeFast(self: *Connection) !u8 {
        while (true) {
            const available = self.read_len - self.read_pos;
            if (available >= 5) {
                const pos = self.read_pos;
                const msg_type = self.read_buffer[pos];
                const length = std.mem.readInt(u32, self.read_buffer[pos + 1 ..][0..4], .big);
                const len_field: usize = @intCast(length);

                if (len_field < 4) return error.InvalidMessageLength;
                if (len_field > self.read_buffer.len - 1) return error.MessageTooLarge;

                const total_len = len_field + 1;
                if (available >= total_len) {
                    const payload = self.read_buffer[pos + 5 .. pos + total_len];
                    self.read_pos = pos + total_len;
                    try Decoder.validateBackendMessagePayloadByte(msg_type, payload);
                    return msg_type;
                }
            }

            try self.readMore();
        }
    }

    /// Read a complete message and return raw wire message type byte.
    ///
    /// This avoids enum conversion in high-throughput loops.
    pub fn readMessageRawFast(self: *Connection) !struct { msg_type: u8, payload: []const u8 } {
        while (true) {
            const available = self.read_len - self.read_pos;
            if (available >= 5) {
                const pos = self.read_pos;
                const msg_type = self.read_buffer[pos];
                const length = std.mem.readInt(u32, self.read_buffer[pos + 1 ..][0..4], .big);
                const len_field: usize = @intCast(length);

                if (len_field < 4) return error.InvalidMessageLength;
                if (len_field > self.read_buffer.len - 1) return error.MessageTooLarge;

                const total_len = len_field + 1;
                if (available >= total_len) {
                    const payload = self.read_buffer[pos + 5 .. pos + total_len];
                    self.read_pos = pos + total_len;
                    try Decoder.validateBackendMessagePayloadByte(msg_type, payload);
                    return .{ .msg_type = msg_type, .payload = payload };
                }
            }

            try self.readMore();
        }
    }

    fn readMore(self: *Connection) !void {
        if (self.read_len == self.read_buffer.len and self.read_pos > 0) {
            const remaining = self.read_len - self.read_pos;
            std.mem.copyForwards(u8, self.read_buffer[0..remaining], self.read_buffer[self.read_pos..self.read_len]);
            self.read_len = remaining;
            self.read_pos = 0;
        }

        const n = try self.stream.read(self.read_buffer[self.read_len..]);
        if (n == 0) return error.ConnectionClosed;
        self.read_len += n;
    }

    /// Perform startup handshake
    pub fn startup(self: *Connection, user: []const u8, database: []const u8, password: ?[]const u8) !void {
        return self.startupWithParamsAndAuth(user, database, password, &.{}, .{});
    }

    /// Perform startup handshake with additional startup parameters.
    pub fn startupWithParams(
        self: *Connection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        extra_params: []const StartupParam,
    ) !void {
        return self.startupWithParamsAndAuth(user, database, password, extra_params, .{});
    }

    /// Perform startup handshake with startup parameters and auth options.
    pub fn startupWithParamsAndAuth(
        self: *Connection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        extra_params: []const StartupParam,
        auth_options: AuthOptions,
    ) !void {
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
        var gss_session_id: ?u64 = null;
        var gss_roundtrips: u32 = 0;
        const requested_protocol_minor: u16 = @intCast(protocol.wire.PROTOCOL_VERSION & 0xFFFF);
        const AuthFlow = enum { none, cleartext, md5, sasl, gss };
        var auth_flow: AuthFlow = .none;
        var auth_ok = false;
        var sasl_complete = false;

        // Send StartupMessage
        try encoder.encodeStartupWithParams(user, database, extra_params);
        try self.send(encoder.getWritten());

        // Handle authentication
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
                            gss_session_id = null;
                            gss_roundtrips = 0;
                            auth_flow = .none;
                            auth_ok = true;
                        },
                        .cleartext_password => {
                            if (auth_flow != .none and auth_flow != .cleartext) return error.AuthenticationMethodSwitch;
                            auth_flow = .cleartext;
                            if (!auth_options_mod.authTypeAllowed(auth_options, .cleartext_password)) return error.AuthMechanismDisabled;
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
                            if (!auth_options_mod.authTypeAllowed(auth_options, .md5_password)) return error.AuthMechanismDisabled;
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
                            if (!auth_options_mod.authTypeAllowed(auth_options, auth_type)) return error.AuthMechanismDisabled;
                            const mechanism = auth_options_mod.mechanismFromAuthType(auth_type).?;
                            const session_id = auth_options_mod.nextGssSessionId();
                            const token = try auth_options_mod.requestGssToken(auth_options, session_id, mechanism, null, self.allocator);
                            if (token.len != 0) {
                                try encoder.encodeSaslResponse(token);
                                try self.send(encoder.getWritten());
                            }
                            gss_mechanism = mechanism;
                            gss_session_id = session_id;
                            gss_roundtrips = 0;
                        },
                        .gss_continue => {
                            if (auth_flow != .gss) return error.InvalidGssState;
                            const mechanism = gss_mechanism orelse return error.InvalidGssState;
                            const session_id = gss_session_id orelse return error.InvalidGssState;
                            gss_roundtrips += 1;
                            if (gss_roundtrips > auth_options.max_gss_roundtrips) return error.GssRoundtripLimitExceeded;

                            const server_token = try decoder.parseAuthenticationSaslData();
                            const token = try auth_options_mod.requestGssToken(auth_options, session_id, mechanism, server_token, self.allocator);
                            if (token.len != 0) {
                                try encoder.encodeSaslResponse(token);
                                try self.send(encoder.getWritten());
                            }
                        },
                        .sasl => {
                            if (auth_flow != .none and auth_flow != .sasl) return error.AuthenticationMethodSwitch;
                            auth_flow = .sasl;
                            sasl_complete = false;
                            if (!auth_options_mod.authTypeAllowed(auth_options, .sasl)) return error.AuthMechanismDisabled;
                            const mechanisms = try decoder.parseAuthenticationSaslMechanisms(self.allocator);
                            defer self.allocator.free(mechanisms);

                            if (password == null) return error.PasswordRequired;
                            const selection = try auth_options_mod.selectScramMechanism(
                                mechanisms,
                                auth_options.scram_tls_server_end_point_binding,
                                auth_options.scram_channel_binding,
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
                            gss_session_id = null;
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
                .negotiate_protocol_version => {
                    if (auth_ok) return error.NegotiateProtocolVersionAfterAuthOk;
                    var decoder = Decoder.init(msg.payload);
                    const negotiate = try decoder.parseNegotiateProtocolVersion(self.allocator);
                    defer self.allocator.free(negotiate.unrecognized_options);
                    const negotiated_minor = try Decoder.parseProtocolMinorFromNegotiate(negotiate.newest_minor_supported);
                    if (negotiated_minor > requested_protocol_minor) return error.ProtocolMinorAboveRequested;
                },
                .parameter_status => {
                    // Ignore parameter status messages
                    if (!auth_ok) return error.ParameterStatusBeforeAuthOk;
                },
                .backend_key_data => {
                    if (!auth_ok) return error.BackendKeyBeforeAuthOk;
                    var decoder = Decoder.init(msg.payload);
                    const key_data = try decoder.parseBackendKeyData();
                    self.process_id = key_data.process_id;
                    self.secret_key = key_data.secret_key;
                    self.cancel_key_len = @intCast(key_data.secret_key_bytes.len);
                    @memcpy(
                        self.cancel_key[0..key_data.secret_key_bytes.len],
                        key_data.secret_key_bytes,
                    );
                },
                .ready_for_query => {
                    if (!auth_ok) return error.StartupCompletedWithoutAuthOk;
                    var decoder = Decoder.init(msg.payload);
                    const status = try decoder.parseReadyForQuery();
                    if (status != .idle) return error.StartupCompletedWithNonIdleStatus;
                    self.in_transaction = status == .in_transaction;
                    self.ready = true;
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err_info = try decoder.parseErrorResponse();
                    std.debug.print("Server error: {s}\n", .{err_info.message orelse "unknown"});
                    return error.ServerError;
                },
                .notice => {},
                else => return error.UnexpectedStartupMessageType,
            }
        }
    }
};

// Tests
test "connection struct init" {
    // Just test the struct can be created
    const conn = Connection{
        .stream = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(!conn.ready);
    try std.testing.expectEqual(@as(io_backend_mod.Backend, .sync), conn.ioBackend());
}
