// Async PostgreSQL Connection
//
// Non-blocking TCP connection with poll-based I/O and timeouts.
// Uses std.posix.poll for cross-platform async operations.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const net = @import("../compat/net.zig");
const protocol = @import("../protocol/mod.zig");
const message_limits = @import("message_limits.zig");

const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const auth = protocol.auth;
const auth_options_mod = @import("auth_options.zig");
pub const AuthOptions = auth_options_mod.AuthOptions;

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
        var stream = try net.tcpConnectToHostWithTimeout(allocator, host, port, timeout_ms);
        errdefer stream.close();
        try net.setStreamBlocking(stream, false);

        return .{
            .fd = stream.handle,
            .allocator = allocator,
            .default_timeout_ms = timeout_ms,
        };
    }

    pub fn close(self: *AsyncConnection) void {
        _ = posix.system.close(self.fd);
    }

    /// Send bytes with timeout
    pub fn sendWithTimeout(self: *AsyncConnection, bytes: []const u8, timeout_ms: i32) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            // Wait for socket to be writable
            if (!try pollWrite(self.fd, timeout_ms)) {
                return error.WriteTimeout;
            }

            const n = fdWrite(self.fd, bytes[sent..]) catch |err| {
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

        const n = fdRead(self.fd, buf) catch |err| {
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
        const payload_len = try message_limits.validateLengthField(length, self.read_buffer.len - 1);
        try self.ensureReadWithTimeout(5 + payload_len, timeout_ms);

        const payload = self.read_buffer[self.read_pos + 5 .. self.read_pos + 5 + payload_len];
        self.read_pos += 5 + payload_len;

        return .{ .msg_type = msg_type, .payload = payload };
    }

    fn ensureReadWithTimeout(self: *AsyncConnection, needed: usize, timeout_ms: i32) !void {
        if (needed > self.read_buffer.len) return error.MessageTooLarge;
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
            const n = fdRead(self.fd, self.read_buffer[self.read_len..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_len += n;
        }
    }

    fn fdWrite(fd: posix.fd_t, bytes: []const u8) !usize {
        while (true) {
            const rc = posix.system.write(fd, bytes.ptr, bytes.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    fn fdRead(fd: posix.fd_t, buf: []u8) !usize {
        while (true) {
            const rc = posix.system.read(fd, buf.ptr, buf.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    /// Perform startup handshake with timeout
    pub fn startup(self: *AsyncConnection, user: []const u8, database: []const u8, password: ?[]const u8) !void {
        return self.startupWithAuthOptions(user, database, password, .{});
    }

    /// Perform startup handshake with auth options.
    pub fn startupWithAuthOptions(
        self: *AsyncConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
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
        const AuthFlow = enum { none, cleartext, md5, sasl, gss };
        var auth_flow: AuthFlow = .none;
        var auth_ok = false;
        var sasl_complete = false;

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
                .notice => {},
                else => return error.UnexpectedStartupMessageType,
            }
        }
    }
};

// ==================== Poll Helpers ====================

/// Wait for fd to be readable. Returns true if ready, false if timeout.
fn pollRead(fd: posix.fd_t, timeout_ms: i32) !bool {
    var fds = [1]posix.pollfd{
        .{ .fd = if (builtin.os.tag == .windows) @ptrCast(fd) else fd, .events = posix.POLL.IN, .revents = 0 },
    };

    const result = try posix.poll(&fds, timeout_ms);
    return result > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

/// Wait for fd to be writable. Returns true if ready, false if timeout.
fn pollWrite(fd: posix.fd_t, timeout_ms: i32) !bool {
    var fds = [1]posix.pollfd{
        .{ .fd = if (builtin.os.tag == .windows) @ptrCast(fd) else fd, .events = posix.POLL.OUT, .revents = 0 },
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
