// PostgreSQL SCRAM-SHA-256 Authentication
//
// Implements SASL SCRAM-SHA-256 authentication for PostgreSQL 10+.

const std = @import("std");
const crypto = std.crypto;
const rand_compat = @import("../runtime/rand.zig");

const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = crypto.hash.sha2.Sha256;
const Pbkdf2 = crypto.pwhash.pbkdf2;

const GS2_HEADER_NO_CHANNEL_BINDING = "n,,";
const GS2_HEADER_TLS_SERVER_END_POINT = "p=tls-server-end-point,,";
const SCRAM_MIN_ITERATIONS: u32 = 4096;
const SCRAM_MAX_ITERATIONS: u32 = 100_000;

/// SCRAM client for PostgreSQL authentication.
///
/// Supports SCRAM-SHA-256 and SCRAM-SHA-256-PLUS (`tls-server-end-point`).
pub const ScramClient = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    client_nonce: [24]u8,
    state: State = .initial,

    auth_message: ?[]u8 = null,
    salted_password: ?[32]u8 = null,
    channel_binding_data: ?[]u8 = null,
    gs2_header: []const u8 = GS2_HEADER_NO_CHANNEL_BINDING,

    const State = enum {
        initial,
        client_first_sent,
        client_final_sent,
        completed,
    };

    pub fn init(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ScramClient {
        var client = ScramClient{
            .allocator = allocator,
            .username = username,
            .password = password,
            .client_nonce = undefined,
        };
        rand_compat.bytes(&client.client_nonce);
        return client;
    }

    /// Create SCRAM client using `tls-server-end-point` channel binding bytes.
    pub fn initWithTlsServerEndPoint(
        allocator: std.mem.Allocator,
        username: []const u8,
        password: []const u8,
        channel_binding_data: []const u8,
    ) !ScramClient {
        var client = ScramClient.init(allocator, username, password);
        client.channel_binding_data = try allocator.dupe(u8, channel_binding_data);
        client.gs2_header = GS2_HEADER_TLS_SERVER_END_POINT;
        return client;
    }

    pub fn deinit(self: *ScramClient) void {
        if (self.auth_message) |msg| {
            self.allocator.free(msg);
            self.auth_message = null;
        }
        if (self.channel_binding_data) |data| {
            self.allocator.free(data);
            self.channel_binding_data = null;
        }
    }

    fn clientNonce(self: *const ScramClient, nonce_buf: *[32]u8) []const u8 {
        return std.base64.standard.Encoder.encode(nonce_buf, &self.client_nonce);
    }

    fn decodeBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
            return error.InvalidServerResponse;
        };

        const decoded = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(decoded);

        std.base64.standard.Decoder.decode(decoded, encoded) catch {
            return error.InvalidServerResponse;
        };
        return decoded;
    }

    fn encodeBase64Alloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
        _ = std.base64.standard.Encoder.encode(encoded, raw);
        return encoded;
    }

    fn channelBindingInputAlloc(self: *const ScramClient) ![]u8 {
        const binding_len = if (self.channel_binding_data) |data| data.len else 0;
        const total_len = self.gs2_header.len + binding_len;

        const input = try self.allocator.alloc(u8, total_len);
        @memcpy(input[0..self.gs2_header.len], self.gs2_header);
        if (self.channel_binding_data) |data| {
            @memcpy(input[self.gs2_header.len..], data);
        }
        return input;
    }

    /// Generate client-first-message (n,,n=<user>,r=<nonce>)
    pub fn clientFirstMessage(self: *ScramClient) ![]u8 {
        self.state = .client_first_sent;

        var nonce_buf: [32]u8 = undefined;
        const nonce = self.clientNonce(&nonce_buf);

        return std.fmt.allocPrint(
            self.allocator,
            "{s}n={s},r={s}",
            .{ self.gs2_header, self.username, nonce },
        );
    }

    /// Process server-first-message and generate client-final-message.
    ///
    /// server-first-message format: r=<nonce>,s=<salt>,i=<iterations>
    pub fn processServerFirst(self: *ScramClient, server_first: []const u8) ![]u8 {
        if (self.state != .client_first_sent) return error.InvalidScramState;

        var server_nonce: ?[]const u8 = null;
        var salt_b64: ?[]const u8 = null;
        var iterations: ?u32 = null;

        var parts = std.mem.splitScalar(u8, server_first, ',');
        while (parts.next()) |part| {
            if (std.mem.startsWith(u8, part, "r=")) {
                server_nonce = part[2..];
            } else if (std.mem.startsWith(u8, part, "s=")) {
                salt_b64 = part[2..];
            } else if (std.mem.startsWith(u8, part, "i=")) {
                iterations = std.fmt.parseInt(u32, part[2..], 10) catch return error.InvalidServerResponse;
            }
        }

        if (server_nonce == null or salt_b64 == null or iterations == null) {
            return error.InvalidServerResponse;
        }

        if (iterations.? < SCRAM_MIN_ITERATIONS or iterations.? > SCRAM_MAX_ITERATIONS) {
            return error.InvalidServerResponse;
        }

        var client_nonce_buf: [32]u8 = undefined;
        const client_nonce = self.clientNonce(&client_nonce_buf);
        if (!std.mem.startsWith(u8, server_nonce.?, client_nonce)) {
            return error.InvalidServerResponse;
        }

        const salt = try decodeBase64Alloc(self.allocator, salt_b64.?);
        defer self.allocator.free(salt);

        var salted_password: [32]u8 = undefined;
        try Pbkdf2(salted_password[0..], self.password, salt, iterations.?, HmacSha256);
        self.salted_password = salted_password;

        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", salted_password[0..]);

        var stored_key: [32]u8 = undefined;
        Sha256.hash(client_key[0..], &stored_key, .{});

        const client_first_bare = try std.fmt.allocPrint(
            self.allocator,
            "n={s},r={s}",
            .{ self.username, client_nonce },
        );
        defer self.allocator.free(client_first_bare);

        const channel_binding_input = try self.channelBindingInputAlloc();
        defer self.allocator.free(channel_binding_input);
        const channel_binding_b64 = try encodeBase64Alloc(self.allocator, channel_binding_input);
        defer self.allocator.free(channel_binding_b64);

        const client_final_without_proof = try std.fmt.allocPrint(
            self.allocator,
            "c={s},r={s}",
            .{ channel_binding_b64, server_nonce.? },
        );
        defer self.allocator.free(client_final_without_proof);

        const auth_message = try std.fmt.allocPrint(
            self.allocator,
            "{s},{s},{s}",
            .{ client_first_bare, server_first, client_final_without_proof },
        );
        errdefer self.allocator.free(auth_message);

        if (self.auth_message) |prev| {
            self.allocator.free(prev);
        }
        self.auth_message = auth_message;

        var client_signature: [32]u8 = undefined;
        HmacSha256.create(&client_signature, auth_message, stored_key[0..]);

        var client_proof: [32]u8 = undefined;
        for (client_key, 0..) |value, i| {
            client_proof[i] = value ^ client_signature[i];
        }

        var proof_b64_buf: [std.base64.standard.Encoder.calcSize(client_proof.len)]u8 = undefined;
        const proof_b64 = std.base64.standard.Encoder.encode(&proof_b64_buf, &client_proof);

        self.state = .client_final_sent;
        return std.fmt.allocPrint(
            self.allocator,
            "{s},p={s}",
            .{ client_final_without_proof, proof_b64 },
        );
    }

    /// Verify server-final-message (v=<base64 signature>).
    pub fn verifyServerFinal(self: *ScramClient, server_final: []const u8) !void {
        if (self.state != .client_final_sent) return error.InvalidScramState;
        if (server_final.len < 3) return error.InvalidServerFinalMessage;

        if (std.mem.startsWith(u8, server_final, "e=")) return error.ServerRejectedScram;
        if (!std.mem.startsWith(u8, server_final, "v=")) return error.InvalidServerFinalMessage;

        const signature_b64 = server_final[2..];
        const signature_len = std.base64.standard.Decoder.calcSizeForSlice(signature_b64) catch {
            return error.InvalidServerFinalMessage;
        };
        if (signature_len != 32) return error.InvalidServerFinalMessage;

        var expected_signature: [32]u8 = undefined;
        std.base64.standard.Decoder.decode(expected_signature[0..], signature_b64) catch {
            return error.InvalidServerFinalMessage;
        };

        const salted_password = self.salted_password orelse return error.InvalidScramState;
        const auth_message = self.auth_message orelse return error.InvalidScramState;

        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", salted_password[0..]);

        var computed_signature: [32]u8 = undefined;
        HmacSha256.create(&computed_signature, auth_message, server_key[0..]);

        if (!crypto.timing_safe.eql([32]u8, computed_signature, expected_signature)) {
            return error.InvalidServerSignature;
        }

        self.state = .completed;
    }
};

/// Compute MD5 password hash for older PostgreSQL versions.
///
/// Output format: "md5" + hex(MD5(hex(MD5(password + username)) + salt))
pub fn md5Password(password: []const u8, username: []const u8, salt: [4]u8) [35]u8 {
    var inner_hasher = crypto.hash.Md5.init(.{});
    inner_hasher.update(password);
    inner_hasher.update(username);

    var inner: [16]u8 = undefined;
    inner_hasher.final(&inner);

    const inner_hex = std.fmt.bytesToHex(inner, .lower);

    var outer_hasher = crypto.hash.Md5.init(.{});
    outer_hasher.update(&inner_hex);
    outer_hasher.update(&salt);

    var outer: [16]u8 = undefined;
    outer_hasher.final(&outer);

    var result: [35]u8 = undefined;
    result[0] = 'm';
    result[1] = 'd';
    result[2] = '5';
    const outer_hex = std.fmt.bytesToHex(outer, .lower);
    @memcpy(result[3..], &outer_hex);

    return result;
}

// Tests
test "scram client init" {
    const client = ScramClient.init(std.testing.allocator, "user", "pass");
    try std.testing.expectEqualStrings("user", client.username);
    try std.testing.expectEqualStrings("pass", client.password);
    try std.testing.expectEqualStrings(GS2_HEADER_NO_CHANNEL_BINDING, client.gs2_header);
}

test "scram client first message" {
    var client = ScramClient.init(std.testing.allocator, "testuser", "testpass");
    defer client.deinit();

    const msg = try client.clientFirstMessage();
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "n,,n=testuser,r="));
}

test "scram client first message with tls-server-end-point binding" {
    var client = try ScramClient.initWithTlsServerEndPoint(
        std.testing.allocator,
        "testuser",
        "testpass",
        &.{ 0xDE, 0xAD, 0xBE, 0xEF },
    );
    defer client.deinit();

    const msg = try client.clientFirstMessage();
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "p=tls-server-end-point,,n=testuser,r="));
}

test "scram process server first and create proof" {
    var client = ScramClient.init(std.testing.allocator, "testuser", "testpass");
    defer client.deinit();

    const first = try client.clientFirstMessage();
    defer std.testing.allocator.free(first);

    var nonce_buf: [32]u8 = undefined;
    const nonce = client.clientNonce(&nonce_buf);
    const server_first = try std.fmt.allocPrint(
        std.testing.allocator,
        "r={s}ServerPart,s=cmFuZG9tc2FsdA==,i=4096",
        .{nonce},
    );
    defer std.testing.allocator.free(server_first);

    const final = try client.processServerFirst(server_first);
    defer std.testing.allocator.free(final);

    try std.testing.expect(std.mem.startsWith(u8, final, "c=biws,r="));
    try std.testing.expect(std.mem.indexOf(u8, final, ",p=") != null);
}

test "scram plus final carries channel binding payload" {
    const channel_binding_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var client = try ScramClient.initWithTlsServerEndPoint(
        std.testing.allocator,
        "testuser",
        "testpass",
        &channel_binding_data,
    );
    defer client.deinit();

    const first = try client.clientFirstMessage();
    defer std.testing.allocator.free(first);

    var nonce_buf: [32]u8 = undefined;
    const nonce = client.clientNonce(&nonce_buf);
    const server_first = try std.fmt.allocPrint(
        std.testing.allocator,
        "r={s}ServerPart,s=cmFuZG9tc2FsdA==,i=4096",
        .{nonce},
    );
    defer std.testing.allocator.free(server_first);

    const final = try client.processServerFirst(server_first);
    defer std.testing.allocator.free(final);

    var parts = std.mem.splitScalar(u8, final, ',');
    var c_b64: ?[]const u8 = null;
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "c=")) {
            c_b64 = part[2..];
            break;
        }
    }

    const encoded = c_b64 orelse return error.InvalidServerResponse;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try std.testing.allocator.alloc(u8, decoded_len);
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);

    const expected_len = GS2_HEADER_TLS_SERVER_END_POINT.len + channel_binding_data.len;
    const expected = try std.testing.allocator.alloc(u8, expected_len);
    defer std.testing.allocator.free(expected);
    @memcpy(expected[0..GS2_HEADER_TLS_SERVER_END_POINT.len], GS2_HEADER_TLS_SERVER_END_POINT);
    @memcpy(expected[GS2_HEADER_TLS_SERVER_END_POINT.len..], &channel_binding_data);

    try std.testing.expectEqualSlices(u8, expected, decoded);
}

test "scram verify server final" {
    var client = ScramClient.init(std.testing.allocator, "testuser", "testpass");
    defer client.deinit();

    const first = try client.clientFirstMessage();
    defer std.testing.allocator.free(first);

    var nonce_buf: [32]u8 = undefined;
    const nonce = client.clientNonce(&nonce_buf);
    const server_first = try std.fmt.allocPrint(
        std.testing.allocator,
        "r={s}ServerPart,s=cmFuZG9tc2FsdA==,i=4096",
        .{nonce},
    );
    defer std.testing.allocator.free(server_first);

    const final = try client.processServerFirst(server_first);
    defer std.testing.allocator.free(final);

    const salted_password = client.salted_password orelse unreachable;
    const auth_message = client.auth_message orelse unreachable;

    var server_key: [32]u8 = undefined;
    HmacSha256.create(&server_key, "Server Key", salted_password[0..]);

    var server_signature: [32]u8 = undefined;
    HmacSha256.create(&server_signature, auth_message, server_key[0..]);

    var signature_b64_buf: [std.base64.standard.Encoder.calcSize(server_signature.len)]u8 = undefined;
    const signature_b64 = std.base64.standard.Encoder.encode(&signature_b64_buf, &server_signature);
    const server_final = try std.fmt.allocPrint(std.testing.allocator, "v={s}", .{signature_b64});
    defer std.testing.allocator.free(server_final);

    try client.verifyServerFinal(server_final);
}

test "md5 password known vector" {
    const md5 = md5Password("secret", "postgres", .{ 0x12, 0x34, 0x56, 0x78 });
    try std.testing.expectEqualStrings("md521561af64619ca746c2a6c4d6cbedb30", md5[0..]);
}
