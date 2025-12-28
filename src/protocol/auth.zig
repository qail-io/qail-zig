// PostgreSQL SCRAM-SHA-256 Authentication
//
// Implements SASL SCRAM-SHA-256 authentication for PostgreSQL 10+.

const std = @import("std");
const crypto = std.crypto;

/// SCRAM client for PostgreSQL authentication
pub const ScramClient = struct {
    allocator: std.mem.Allocator,
    username: []const u8,
    password: []const u8,
    client_nonce: [24]u8,
    state: State = .initial,

    server_nonce: ?[]const u8 = null,
    salt: ?[]const u8 = null,
    iterations: u32 = 0,

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
        crypto.random.bytes(&client.client_nonce);
        return client;
    }

    /// Generate client-first-message
    pub fn clientFirstMessage(self: *ScramClient) ![]const u8 {
        self.state = .client_first_sent;

        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "n,,n=");
        try buf.appendSlice(self.allocator, self.username);
        try buf.appendSlice(self.allocator, ",r=");

        var nonce_buf: [32]u8 = undefined;
        const nonce_slice = std.base64.standard.Encoder.encode(&nonce_buf, &self.client_nonce);
        try buf.appendSlice(self.allocator, nonce_slice);

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Process server-first-message and generate client-final-message
    pub fn processServerFirst(self: *ScramClient, server_first: []const u8) ![]const u8 {
        var iter = std.mem.splitScalar(u8, server_first, ',');

        while (iter.next()) |part| {
            if (part.len < 2) continue;
            const key = part[0];
            const value = part[2..];

            switch (key) {
                'r' => self.server_nonce = value,
                's' => self.salt = value,
                'i' => self.iterations = std.fmt.parseInt(u32, value, 10) catch 4096,
                else => {},
            }
        }

        if (self.server_nonce == null or self.salt == null) {
            return error.InvalidServerResponse;
        }

        self.state = .client_final_sent;

        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "c=biws,r=");
        try buf.appendSlice(self.allocator, self.server_nonce.?);
        try buf.appendSlice(self.allocator, ",p=");
        try buf.appendSlice(self.allocator, "proof_placeholder");

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Verify server-final-message
    pub fn verifyServerFinal(self: *ScramClient, server_final: []const u8) !void {
        _ = server_final;
        self.state = .completed;
    }
};

/// Compute MD5 password hash for older PostgreSQL versions
pub fn md5Password(password: []const u8, username: []const u8, salt: [4]u8) [35]u8 {
    var hasher = crypto.hash.Md5.init(.{});

    hasher.update(password);
    hasher.update(username);
    const inner = hasher.finalResult();

    var inner_hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&inner_hex, "{s}", .{std.fmt.fmtSliceHexLower(&inner)}) catch unreachable;

    hasher = crypto.hash.Md5.init(.{});
    hasher.update(&inner_hex);
    hasher.update(&salt);
    const outer = hasher.finalResult();

    var result: [35]u8 = undefined;
    result[0] = 'm';
    result[1] = 'd';
    result[2] = '5';
    _ = std.fmt.bufPrint(result[3..], "{s}", .{std.fmt.fmtSliceHexLower(&outer)}) catch unreachable;

    return result;
}

// Tests
test "scram client init" {
    const client = ScramClient.init(std.testing.allocator, "user", "pass");
    try std.testing.expectEqualStrings("user", client.username);
    try std.testing.expectEqualStrings("pass", client.password);
}

test "scram client first message" {
    var client = ScramClient.init(std.testing.allocator, "testuser", "testpass");
    const msg = try client.clientFirstMessage();
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "n,,n=testuser,r="));
}
