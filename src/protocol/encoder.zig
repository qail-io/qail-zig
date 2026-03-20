// PostgreSQL Protocol Encoder
//
// Encodes frontend messages to PostgreSQL wire format.

const std = @import("std");
const wire = @import("wire.zig");

const FrontendMessage = wire.FrontendMessage;
const PROTOCOL_VERSION = wire.PROTOCOL_VERSION;

/// Protocol encoder - writes PostgreSQL wire format messages
pub const Encoder = struct {
    pub const StartupParam = struct {
        name: []const u8,
        value: []const u8,
    };

    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .buffer = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *Encoder) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn getWritten(self: *const Encoder) []const u8 {
        return self.buffer.items;
    }

    // ==================== Encoding Helpers ====================

    /// Write a big-endian u32
    fn writeU32(self: *Encoder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    /// Write a big-endian u16
    fn writeU16(self: *Encoder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    /// Write a big-endian i32
    fn writeI32(self: *Encoder, value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    /// Write a big-endian i16
    fn writeI16(self: *Encoder, value: i16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    /// Write a null-terminated string
    fn writeCString(self: *Encoder, str: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, str);
        try self.buffer.append(self.allocator, 0);
    }

    /// Write raw bytes
    fn writeBytes(self: *Encoder, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    /// Write a single byte
    fn writeByte(self: *Encoder, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    // ==================== Frontend Messages ====================

    /// Encode StartupMessage (no message type byte, just length + version + params)
    pub fn encodeStartup(self: *Encoder, user: []const u8, database: []const u8) !void {
        return self.encodeStartupWithParams(user, database, &.{});
    }

    /// Encode StartupMessage with additional startup parameters.
    pub fn encodeStartupWithParams(
        self: *Encoder,
        user: []const u8,
        database: []const u8,
        extra_params: []const StartupParam,
    ) !void {
        self.reset();

        // length(4) + version(4) + mandatory params + extra params + final terminator
        var msg_len: u32 = 4 + 4 + 5 + @as(u32, @intCast(user.len)) + 1 + 9 + @as(u32, @intCast(database.len)) + 1 + 1;
        for (extra_params) |param| {
            msg_len += @as(u32, @intCast(param.name.len + 1 + param.value.len + 1));
        }

        try self.writeU32(msg_len);
        try self.writeU32(PROTOCOL_VERSION);
        try self.writeCString("user");
        try self.writeCString(user);
        try self.writeCString("database");
        try self.writeCString(database);
        for (extra_params) |param| {
            try self.writeCString(param.name);
            try self.writeCString(param.value);
        }
        try self.writeByte(0); // End of parameters
    }

    /// Encode PasswordMessage
    pub fn encodePassword(self: *Encoder, password: []const u8) !void {
        self.reset();

        const msg_len: u32 = 4 + @as(u32, @intCast(password.len)) + 1;
        try self.writeByte(@intFromEnum(FrontendMessage.password));
        try self.writeU32(msg_len);
        try self.writeCString(password);
    }

    /// Encode SASLInitialResponse (SCRAM first message).
    ///
    /// PostgreSQL wire format:
    /// 'p' + len + mechanism\0 + i32(initial_response_len) + initial_response
    pub fn encodeSaslInitialResponse(
        self: *Encoder,
        mechanism: []const u8,
        initial_response: ?[]const u8,
    ) !void {
        self.reset();

        var msg_len: u32 = 4 + @as(u32, @intCast(mechanism.len)) + 1 + 4;
        var response_len: i32 = -1;

        if (initial_response) |response| {
            msg_len += @as(u32, @intCast(response.len));
            response_len = @intCast(response.len);
        }

        try self.writeByte(@intFromEnum(FrontendMessage.password));
        try self.writeU32(msg_len);
        try self.writeCString(mechanism);
        try self.writeI32(response_len);

        if (initial_response) |response| {
            try self.writeBytes(response);
        }
    }

    /// Encode SASLResponse (SCRAM continue/final message).
    ///
    /// PostgreSQL wire format:
    /// 'p' + len + response
    pub fn encodeSaslResponse(self: *Encoder, response: []const u8) !void {
        self.reset();

        const msg_len: u32 = 4 + @as(u32, @intCast(response.len));
        try self.writeByte(@intFromEnum(FrontendMessage.password));
        try self.writeU32(msg_len);
        try self.writeBytes(response);
    }

    /// Encode Query (Simple Query Protocol)
    pub fn encodeQuery(self: *Encoder, sql: []const u8) !void {
        self.reset();

        const msg_len: u32 = 4 + @as(u32, @intCast(sql.len)) + 1;
        try self.writeByte(@intFromEnum(FrontendMessage.query));
        try self.writeU32(msg_len);
        try self.writeCString(sql);
    }

    /// Encode Parse (Extended Query Protocol)
    pub fn encodeParse(self: *Encoder, stmt_name: []const u8, sql: []const u8, param_types: []const u32) !void {
        self.reset();

        const msg_len: u32 = 4 + @as(u32, @intCast(stmt_name.len)) + 1 + @as(u32, @intCast(sql.len)) + 1 + 2 + @as(u32, @intCast(param_types.len * 4));

        try self.writeByte(@intFromEnum(FrontendMessage.parse));
        try self.writeU32(msg_len);
        try self.writeCString(stmt_name);
        try self.writeCString(sql);
        try self.writeU16(@intCast(param_types.len));

        for (param_types) |oid| {
            try self.writeU32(oid);
        }
    }

    /// Encode Bind
    pub fn encodeBind(
        self: *Encoder,
        portal: []const u8,
        stmt_name: []const u8,
        params: []const ?[]const u8,
    ) !void {
        self.reset();

        var params_size: u32 = 0;
        for (params) |param| {
            params_size += 4;
            if (param) |p| {
                params_size += @intCast(p.len);
            }
        }

        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + @as(u32, @intCast(stmt_name.len)) + 1 + 2 + 2 + params_size + 2;

        try self.writeByte(@intFromEnum(FrontendMessage.bind));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeCString(stmt_name);
        try self.writeU16(0);
        try self.writeU16(@intCast(params.len));

        for (params) |param| {
            if (param) |p| {
                try self.writeI32(@intCast(p.len));
                try self.writeBytes(p);
            } else {
                try self.writeI32(-1);
            }
        }

        try self.writeU16(0);
    }

    /// Encode Describe (portal)
    pub fn encodeDescribePortal(self: *Encoder, portal: []const u8) !void {
        self.reset();

        const msg_len: u32 = 4 + 1 + @as(u32, @intCast(portal.len)) + 1;
        try self.writeByte(@intFromEnum(FrontendMessage.describe));
        try self.writeU32(msg_len);
        try self.writeByte('P');
        try self.writeCString(portal);
    }

    /// Encode Execute
    pub fn encodeExecute(self: *Encoder, portal: []const u8, max_rows: u32) !void {
        self.reset();
        try self.appendExecute(portal, max_rows);
    }

    /// Append Execute (no reset - for pipelining)
    pub fn appendExecute(self: *Encoder, portal: []const u8, max_rows: u32) !void {
        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + 4;
        try self.writeByte(@intFromEnum(FrontendMessage.execute));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeU32(max_rows);
    }

    /// Encode Sync
    pub fn encodeSync(self: *Encoder) !void {
        self.reset();
        try self.appendSync();
    }

    /// Append Sync (no reset - for pipelining)
    pub fn appendSync(self: *Encoder) !void {
        try self.writeByte(@intFromEnum(FrontendMessage.sync));
        try self.writeU32(4);
    }

    /// Encode Terminate
    pub fn encodeTerminate(self: *Encoder) !void {
        self.reset();
        try self.writeByte(@intFromEnum(FrontendMessage.terminate));
        try self.writeU32(4);
    }

    /// Encode Flush
    pub fn encodeFlush(self: *Encoder) !void {
        self.reset();
        try self.writeByte(@intFromEnum(FrontendMessage.flush));
        try self.writeU32(4);
    }

    /// Append Bind (no reset - for pipelining)
    pub fn appendBind(
        self: *Encoder,
        portal: []const u8,
        stmt_name: []const u8,
        params: []const ?[]const u8,
    ) !void {
        var params_size: u32 = 0;
        for (params) |param| {
            params_size += 4;
            if (param) |p| {
                params_size += @intCast(p.len);
            }
        }

        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + @as(u32, @intCast(stmt_name.len)) + 1 + 2 + 2 + params_size + 2;

        try self.writeByte(@intFromEnum(FrontendMessage.bind));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeCString(stmt_name);
        try self.writeU16(0);
        try self.writeU16(@intCast(params.len));

        for (params) |param| {
            if (param) |p| {
                try self.writeI32(@intCast(p.len));
                try self.writeBytes(p);
            } else {
                try self.writeI32(-1);
            }
        }

        try self.writeU16(0);
    }
};

// ==================== Tests ====================

test "encode startup message" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeStartup("postgres", "testdb");
    const bytes = encoder.getWritten();

    const len = std.mem.readInt(u32, bytes[0..4], .big);
    try std.testing.expectEqual(@as(u32, @intCast(bytes.len)), len);

    const version = std.mem.readInt(u32, bytes[4..8], .big);
    try std.testing.expectEqual(PROTOCOL_VERSION, version);
}

test "encode startup message with params" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeStartupWithParams(
        "postgres",
        "testdb",
        &.{
            .{ .name = "replication", .value = "database" },
            .{ .name = "application_name", .value = "qail-zig" },
        },
    );
    const bytes = encoder.getWritten();
    const len = std.mem.readInt(u32, bytes[0..4], .big);

    try std.testing.expectEqual(@as(u32, @intCast(bytes.len)), len);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "replication") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "database") != null);
}

test "encode simple query" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeQuery("SELECT 1");
    const bytes = encoder.getWritten();

    try std.testing.expectEqual(@as(u8, 'Q'), bytes[0]);

    const len = std.mem.readInt(u32, bytes[1..5], .big);
    try std.testing.expectEqual(@as(u32, 13), len);
}

test "encode sync" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeSync();
    const bytes = encoder.getWritten();

    try std.testing.expectEqual(@as(u8, 'S'), bytes[0]);
    try std.testing.expectEqual(@as(usize, 5), bytes.len);
}

test "encode sasl initial response" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeSaslInitialResponse("SCRAM-SHA-256", "n,,n=user,r=nonce");
    const bytes = encoder.getWritten();

    try std.testing.expectEqual(@as(u8, 'p'), bytes[0]);
    try std.testing.expectEqual(
        @as(u32, 4 + "SCRAM-SHA-256".len + 1 + 4 + "n,,n=user,r=nonce".len),
        std.mem.readInt(u32, bytes[1..5], .big),
    );

    const mechanism = bytes[5 .. 5 + "SCRAM-SHA-256".len];
    try std.testing.expectEqualStrings("SCRAM-SHA-256", mechanism);

    const response_len_off = 5 + "SCRAM-SHA-256".len + 1;
    const response_len = std.mem.readInt(i32, bytes[response_len_off .. response_len_off + 4], .big);
    try std.testing.expectEqual(@as(i32, "n,,n=user,r=nonce".len), response_len);
}

test "encode sasl response" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeSaslResponse("c=biws,r=nonce,p=proof");
    const bytes = encoder.getWritten();

    try std.testing.expectEqual(@as(u8, 'p'), bytes[0]);
    try std.testing.expectEqual(
        @as(u32, 4 + "c=biws,r=nonce,p=proof".len),
        std.mem.readInt(u32, bytes[1..5], .big),
    );
    try std.testing.expectEqualStrings("c=biws,r=nonce,p=proof", bytes[5..]);
}
