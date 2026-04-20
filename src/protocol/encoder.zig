// PostgreSQL Protocol Encoder
//
// Encodes frontend messages to PostgreSQL wire format.

const std = @import("std");
const wire = @import("wire.zig");

const FrontendMessage = wire.FrontendMessage;
const PROTOCOL_VERSION = wire.PROTOCOL_VERSION;
const max_wire_message_len: usize = std.math.maxInt(i32);

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
            .buffer = .empty,
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

    fn addLenChecked(total: *usize, add: usize) !void {
        total.* = std.math.add(usize, total.*, add) catch return error.MessageTooLarge;
    }

    fn addCStringLenChecked(total: *usize, s: []const u8) !void {
        try addLenChecked(total, s.len);
        try addLenChecked(total, 1);
    }

    fn toWireLen(total: usize) !u32 {
        if (total > max_wire_message_len) return error.MessageTooLarge;
        return @intCast(total);
    }

    fn toWireI32Len(total: usize) !i32 {
        if (total > max_wire_message_len) return error.MessageTooLarge;
        return @intCast(total);
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
        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, "user");
        try addCStringLenChecked(&msg_len_usize, user);
        try addCStringLenChecked(&msg_len_usize, "database");
        try addCStringLenChecked(&msg_len_usize, database);
        for (extra_params) |param| {
            try addCStringLenChecked(&msg_len_usize, param.name);
            try addCStringLenChecked(&msg_len_usize, param.value);
        }
        try addLenChecked(&msg_len_usize, 1);
        const msg_len = try toWireLen(msg_len_usize);

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

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, password);
        const msg_len = try toWireLen(msg_len_usize);
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

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, mechanism);
        try addLenChecked(&msg_len_usize, 4);

        var response_len: i32 = -1;

        if (initial_response) |response| {
            try addLenChecked(&msg_len_usize, response.len);
            response_len = try toWireI32Len(response.len);
        }
        const msg_len = try toWireLen(msg_len_usize);

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

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addLenChecked(&msg_len_usize, response.len);
        const msg_len = try toWireLen(msg_len_usize);
        try self.writeByte(@intFromEnum(FrontendMessage.password));
        try self.writeU32(msg_len);
        try self.writeBytes(response);
    }

    /// Encode Query (Simple Query Protocol)
    pub fn encodeQuery(self: *Encoder, sql: []const u8) !void {
        self.reset();

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, sql);
        const msg_len = try toWireLen(msg_len_usize);
        try self.writeByte(@intFromEnum(FrontendMessage.query));
        try self.writeU32(msg_len);
        try self.writeCString(sql);
    }

    /// Encode Parse (Extended Query Protocol)
    pub fn encodeParse(self: *Encoder, stmt_name: []const u8, sql: []const u8, param_types: []const u32) !void {
        self.reset();
        if (param_types.len > std.math.maxInt(i16)) return error.TooManyParameters;

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, stmt_name);
        try addCStringLenChecked(&msg_len_usize, sql);
        try addLenChecked(&msg_len_usize, 2);
        const param_type_bytes = std.math.mul(usize, param_types.len, 4) catch return error.MessageTooLarge;
        try addLenChecked(&msg_len_usize, param_type_bytes);
        const msg_len = try toWireLen(msg_len_usize);

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
        if (params.len > std.math.maxInt(i16)) return error.TooManyParameters;

        var params_size: usize = 0;
        for (params) |param| {
            try addLenChecked(&params_size, 4);
            if (param) |p| {
                _ = try toWireI32Len(p.len);
                try addLenChecked(&params_size, p.len);
            }
        }

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, portal);
        try addCStringLenChecked(&msg_len_usize, stmt_name);
        try addLenChecked(&msg_len_usize, 2);
        try addLenChecked(&msg_len_usize, 2);
        try addLenChecked(&msg_len_usize, params_size);
        try addLenChecked(&msg_len_usize, 2);
        const msg_len = try toWireLen(msg_len_usize);

        try self.writeByte(@intFromEnum(FrontendMessage.bind));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeCString(stmt_name);
        try self.writeU16(0);
        try self.writeU16(@intCast(params.len));

        for (params) |param| {
            if (param) |p| {
                try self.writeI32(try toWireI32Len(p.len));
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

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addLenChecked(&msg_len_usize, 1);
        try addCStringLenChecked(&msg_len_usize, portal);
        const msg_len = try toWireLen(msg_len_usize);
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
        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, portal);
        try addLenChecked(&msg_len_usize, 4);
        const msg_len = try toWireLen(msg_len_usize);
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
        if (params.len > std.math.maxInt(i16)) return error.TooManyParameters;
        var params_size: usize = 0;
        for (params) |param| {
            try addLenChecked(&params_size, 4);
            if (param) |p| {
                _ = try toWireI32Len(p.len);
                try addLenChecked(&params_size, p.len);
            }
        }

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, portal);
        try addCStringLenChecked(&msg_len_usize, stmt_name);
        try addLenChecked(&msg_len_usize, 2);
        try addLenChecked(&msg_len_usize, 2);
        try addLenChecked(&msg_len_usize, params_size);
        try addLenChecked(&msg_len_usize, 2);
        const msg_len = try toWireLen(msg_len_usize);

        try self.writeByte(@intFromEnum(FrontendMessage.bind));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeCString(stmt_name);
        try self.writeU16(0);
        try self.writeU16(@intCast(params.len));

        for (params) |param| {
            if (param) |p| {
                try self.writeI32(try toWireI32Len(p.len));
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

test "encode query rejects oversized payload" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const sql = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.MessageTooLarge, encoder.encodeQuery(sql));
}

test "encode bind rejects oversized parameter payload" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_param = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];
    const params = [_]?[]const u8{huge_param};

    try std.testing.expectError(error.MessageTooLarge, encoder.encodeBind("", "", &params));
}

test "encode startup rejects oversized startup fields" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_user = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.MessageTooLarge, encoder.encodeStartupWithParams(huge_user, "db", &.{}));
}
