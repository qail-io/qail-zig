const std = @import("std");
const builtin = @import("builtin");
const net = @import("../runtime/net.zig");
const protocol = @import("../protocol/mod.zig");
const auth_options_mod = @import("auth_options.zig");
const io_backend_mod = @import("io_backend.zig");
const kerberos_provider_mod = @import("kerberos_provider.zig");
const message_limits = @import("message_limits.zig");

const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const StartupParam = Encoder.StartupParam;
const auth = protocol.auth;
const AuthOptions = auth_options_mod.AuthOptions;

const PQ_GSS_MAX_PACKET: usize = 16_384;
const PQ_GSS_AUTH_BUFFER: usize = 65_536;
const MAX_GSSENC_ROUNDTRIPS: u32 = 10;

const MessageResult = struct {
    msg_type: BackendMessage,
    payload: []const u8,
};

pub const GssEncConnection = if (builtin.os.tag == .linux) struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    api: *kerberos_provider_mod.LinuxKrb5Provider.Api,
    session: kerberos_provider_mod.LinuxKrb5Provider.LinuxKrb5Session,
    read_plain: std.ArrayList(u8),
    read_pos: usize = 0,

    process_id: u32 = 0,
    secret_key: u32 = 0,
    cancel_key_len: u16 = 0,
    cancel_key: [256]u8 = [_]u8{0} ** 256,
    ready: bool = false,
    in_transaction: bool = false,

    const Self = @This();
    const LinuxProvider = kerberos_provider_mod.LinuxKrb5Provider;

    pub fn connectFromAcceptedStream(
        allocator: std.mem.Allocator,
        host: []const u8,
        stream: net.Stream,
    ) !Self {
        var owned_stream = stream;
        errdefer owned_stream.close();

        const api = try allocator.create(LinuxProvider.Api);
        errdefer allocator.destroy(api);
        api.* = try LinuxProvider.Api.load();
        errdefer api.deinit();

        const target = try std.fmt.allocPrint(allocator, "postgres@{s}", .{host});
        defer allocator.free(target);

        var session = try LinuxProvider.LinuxKrb5Session.init(api, target, .gss);
        errdefer session.deinit();

        var input_token: ?[]u8 = null;
        errdefer if (input_token) |token| allocator.free(token);

        var roundtrips: u32 = 0;
        while (true) {
            roundtrips += 1;
            if (roundtrips > MAX_GSSENC_ROUNDTRIPS) return error.GssEncRoundtripLimitExceeded;

            const step = try session.stepWithFlags(
                allocator,
                input_token,
                LinuxProvider.GSS_C_MUTUAL_FLAG | LinuxProvider.GSS_C_SEQUENCE_FLAG | LinuxProvider.GSS_C_CONF_FLAG,
            );
            defer allocator.free(step.token);
            if (input_token) |token| {
                allocator.free(token);
                input_token = null;
            }

            if (step.token.len != 0) {
                try writeFrame(owned_stream, step.token);
            }

            if (step.complete) {
                if ((step.ret_flags & LinuxProvider.GSS_C_CONF_FLAG) == 0) {
                    return error.GssEncConfidentialityRequired;
                }
                return .{
                    .allocator = allocator,
                    .stream = owned_stream,
                    .api = api,
                    .session = session,
                    .read_plain = .empty,
                };
            }

            input_token = try readHandshakeFrame(allocator, owned_stream);
        }
    }

    pub fn close(self: *Self) void {
        self.read_plain.deinit(self.allocator);
        self.session.deinit();
        self.api.deinit();
        self.allocator.destroy(self.api);
        self.stream.close();
    }

    pub fn ioBackend(_: *const Self) io_backend_mod.Backend {
        return .sync;
    }

    pub fn send(self: *Self, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const chunk_len = @min(PQ_GSS_MAX_PACKET, remaining.len);
            const wrapped = try self.session.wrap(self.allocator, remaining[0..chunk_len]);
            defer self.allocator.free(wrapped);
            try writeFrame(self.stream, wrapped);
            remaining = remaining[chunk_len..];
        }
    }

    pub fn readMessage(self: *Self) !MessageResult {
        try self.ensureRead(5);

        const msg_type: BackendMessage = @enumFromInt(self.read_plain.items[self.read_pos]);
        const length = std.mem.readInt(u32, self.read_plain.items[self.read_pos + 1 ..][0..4], .big);
        const payload_len = try message_limits.validateLengthField(length, message_limits.max_backend_message_len_field);
        try self.ensureRead(5 + payload_len);

        const payload = self.read_plain.items[self.read_pos + 5 .. self.read_pos + 5 + payload_len];
        self.read_pos += 5 + payload_len;
        try Decoder.validateBackendMessagePayload(msg_type, payload);
        return .{ .msg_type = msg_type, .payload = payload };
    }

    pub fn startupWithParamsAndAuth(
        self: *Self,
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
            if (scram_client) |*client| client.deinit();
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

                            if (scram_client) |*client| client.deinit();
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

    fn ensureRead(self: *Self, needed: usize) !void {
        while (self.read_plain.items.len - self.read_pos < needed) {
            if (self.read_pos > 0) {
                const remaining = self.read_plain.items.len - self.read_pos;
                std.mem.copyForwards(u8, self.read_plain.items[0..remaining], self.read_plain.items[self.read_pos..]);
                self.read_plain.items.len = remaining;
                self.read_pos = 0;
            }

            const plaintext = try readPacket(self);
            defer self.allocator.free(plaintext);
            try self.read_plain.appendSlice(self.allocator, plaintext);
        }
    }

    fn readPacket(self: *Self) ![]u8 {
        var len_buf: [4]u8 = undefined;
        try readExactRaw(self.stream, &len_buf);
        const wrapped_len = std.mem.readInt(u32, &len_buf, .big);
        if (wrapped_len == 0 or wrapped_len > PQ_GSS_MAX_PACKET * 4) {
            return error.InvalidGssEncFrameLength;
        }

        const wrapped = try self.allocator.alloc(u8, wrapped_len);
        defer self.allocator.free(wrapped);
        try readExactRaw(self.stream, wrapped);
        return try self.session.unwrap(self.allocator, wrapped);
    }
} else struct {
    process_id: u32 = 0,
    secret_key: u32 = 0,
    cancel_key_len: u16 = 0,
    cancel_key: [256]u8 = [_]u8{0} ** 256,
    ready: bool = false,
    in_transaction: bool = false,

    pub fn connectFromAcceptedStream(
        _: std.mem.Allocator,
        _: []const u8,
        stream: net.Stream,
    ) !@This() {
        var owned_stream = stream;
        owned_stream.close();
        return error.UnsupportedGssEncTransportPlatform;
    }

    pub fn close(_: *@This()) void {}

    pub fn ioBackend(_: *const @This()) io_backend_mod.Backend {
        return .sync;
    }

    pub fn send(_: *@This(), _: []const u8) !void {
        return error.UnsupportedGssEncTransportPlatform;
    }

    pub fn readMessage(_: *@This()) !MessageResult {
        return error.UnsupportedGssEncTransportPlatform;
    }

    pub fn startupWithParamsAndAuth(
        _: *@This(),
        _: []const u8,
        _: []const u8,
        _: ?[]const u8,
        _: []const StartupParam,
        _: AuthOptions,
    ) !void {
        return error.UnsupportedGssEncTransportPlatform;
    }
};

fn writeFrame(stream: net.Stream, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.MessageTooLarge;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(bytes.len), .big);
    try net.writeAllStream(stream, &len_buf);
    try net.writeAllStream(stream, bytes);
}

fn readHandshakeFrame(allocator: std.mem.Allocator, stream: net.Stream) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readExactRaw(stream, &len_buf);
    const length = std.mem.readInt(u32, &len_buf, .big);
    if (length == 0 or length > PQ_GSS_AUTH_BUFFER) return error.InvalidGssEncHandshakeTokenLength;

    const token = try allocator.alloc(u8, length);
    errdefer allocator.free(token);
    try readExactRaw(stream, token);
    return token;
}

fn readExactRaw(stream: net.Stream, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = try net.readStream(stream, buffer[filled..]);
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

const FrameCaptureCtx = struct {
    server: *net.Server,
    payload: [64]u8 = undefined,
    payload_len: usize = 0,
    frame_len: u32 = 0,
    ok: bool = false,
};

fn captureFrameThread(ctx: *FrameCaptureCtx) void {
    defer ctx.server.deinit();

    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var len_buf: [4]u8 = undefined;
    readExactRaw(conn.stream, &len_buf) catch return;
    ctx.frame_len = std.mem.readInt(u32, &len_buf, .big);
    if (ctx.frame_len > ctx.payload.len) return;
    ctx.payload_len = ctx.frame_len;
    readExactRaw(conn.stream, ctx.payload[0..ctx.payload_len]) catch return;
    ctx.ok = true;
}

const HandshakeServerCtx = struct {
    server: *net.Server,
    length: u32,
    payload: []const u8,
};

fn sendHandshakeFrameThread(ctx: *HandshakeServerCtx) void {
    defer ctx.server.deinit();

    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, ctx.length, .big);
    net.writeAllStream(conn.stream, &len_buf) catch return;
    if (ctx.payload.len != 0) {
        net.writeAllStream(conn.stream, ctx.payload) catch return;
    }
}

test "gssenc writeFrame prefixes length and payload" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = FrameCaptureCtx{ .server = &server };
    var thread = try std.Thread.spawn(.{}, captureFrameThread, .{&ctx});

    var stream = try net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", port);
    defer stream.close();

    try writeFrame(stream, "hello");

    thread.join();
    try std.testing.expect(ctx.ok);
    try std.testing.expectEqual(@as(u32, 5), ctx.frame_len);
    try std.testing.expectEqualStrings("hello", ctx.payload[0..ctx.payload_len]);
}

test "gssenc writeFrame rejects oversized payload length" {
    const stream: net.Stream = undefined;
    const too_large_len: usize = @as(usize, std.math.maxInt(u32)) + 1;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.MessageTooLarge, writeFrame(stream, payload));
}

test "gssenc readHandshakeFrame reads length-prefixed payload" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = HandshakeServerCtx{ .server = &server, .length = 4, .payload = "tokn" };
    var thread = try std.Thread.spawn(.{}, sendHandshakeFrameThread, .{&ctx});
    defer thread.join();

    var stream = try net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", port);
    defer stream.close();

    const token = try readHandshakeFrame(std.testing.allocator, stream);
    defer std.testing.allocator.free(token);

    try std.testing.expectEqualStrings("tokn", token);
}

test "gssenc readHandshakeFrame rejects invalid zero length" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = HandshakeServerCtx{ .server = &server, .length = 0, .payload = "" };
    var thread = try std.Thread.spawn(.{}, sendHandshakeFrameThread, .{&ctx});
    defer thread.join();

    var stream = try net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", port);
    defer stream.close();

    try std.testing.expectError(
        error.InvalidGssEncHandshakeTokenLength,
        readHandshakeFrame(std.testing.allocator, stream),
    );
}

test "gssenc readHandshakeFrame rejects oversized token length" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = HandshakeServerCtx{ .server = &server, .length = PQ_GSS_AUTH_BUFFER + 1, .payload = "" };
    var thread = try std.Thread.spawn(.{}, sendHandshakeFrameThread, .{&ctx});
    defer thread.join();

    var stream = try net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", port);
    defer stream.close();

    try std.testing.expectError(
        error.InvalidGssEncHandshakeTokenLength,
        readHandshakeFrame(std.testing.allocator, stream),
    );
}
