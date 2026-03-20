// PostgreSQL Protocol Decoder
//
// Decodes backend messages from PostgreSQL wire format.

const std = @import("std");
const wire = @import("wire.zig");

const BackendMessage = wire.BackendMessage;
const AuthType = wire.AuthType;
const TransactionStatus = wire.TransactionStatus;
const FieldDescription = wire.FieldDescription;
const ErrorInfo = wire.ErrorInfo;
const ErrorField = wire.ErrorField;

/// Protocol decoder - reads PostgreSQL wire format messages
pub const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data };
    }

    pub fn remaining(self: *const Decoder) usize {
        return self.data.len - self.pos;
    }

    pub fn hasMore(self: *const Decoder) bool {
        return self.remaining() >= 5; // Minimum message size
    }

    // ==================== Reading Helpers ====================

    fn readByte(self: *Decoder) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    fn readU32(self: *Decoder) !u32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return value;
    }

    fn readU16(self: *Decoder) !u16 {
        if (self.pos + 2 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return value;
    }

    fn readI32(self: *Decoder) !i32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return value;
    }

    fn readI16(self: *Decoder) !i16 {
        if (self.pos + 2 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(i16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return value;
    }

    fn readCString(self: *Decoder) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != 0) {
            self.pos += 1;
        }
        if (self.pos >= self.data.len) return error.EndOfStream;
        const str = self.data[start..self.pos];
        self.pos += 1; // Skip null terminator
        return str;
    }

    fn readBytes(self: *Decoder, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        const bytes = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return bytes;
    }

    fn skip(self: *Decoder, len: usize) !void {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        self.pos += len;
    }

    // ==================== Message Parsing ====================

    /// Read message header (type + length), returns (msg_type, payload_length)
    pub fn readHeader(self: *Decoder) !struct { msg_type: BackendMessage, length: u32 } {
        const msg_type_byte = try self.readByte();
        const length = try self.readU32();
        return .{
            .msg_type = @enumFromInt(msg_type_byte),
            .length = length,
        };
    }

    /// Parse AuthenticationOk/etc message
    pub fn parseAuthentication(self: *Decoder) !AuthType {
        const auth_type = try self.readU32();
        return @enumFromInt(auth_type);
    }

    /// Parse MD5 salt from AuthenticationMD5Password payload.
    ///
    /// Must be called after `parseAuthentication()` when auth type is `md5_password`.
    pub fn parseAuthenticationMd5Salt(self: *Decoder) ![4]u8 {
        const salt_bytes = try self.readBytes(4);
        if (self.remaining() != 0) return error.InvalidAuthenticationPayload;

        var salt: [4]u8 = undefined;
        std.mem.copyForwards(u8, salt[0..], salt_bytes);
        return salt;
    }

    /// Parse SASL mechanism list from AuthenticationSASL payload.
    ///
    /// Must be called after `parseAuthentication()` when auth type is `sasl`.
    pub fn parseAuthenticationSaslMechanisms(self: *Decoder, allocator: std.mem.Allocator) ![][]const u8 {
        var mechs: std.ArrayList([]const u8) = .{};
        defer mechs.deinit(allocator);

        while (true) {
            const mechanism = try self.readCString();
            if (mechanism.len == 0) break; // Final list terminator
            try mechs.append(allocator, mechanism);
        }

        if (self.remaining() != 0 or mechs.items.len == 0) {
            return error.InvalidSaslMechanismList;
        }

        return try mechs.toOwnedSlice(allocator);
    }

    /// Parse opaque SASL data payload (AuthenticationSASLContinue / AuthenticationSASLFinal).
    ///
    /// Must be called after `parseAuthentication()`.
    pub fn parseAuthenticationSaslData(self: *Decoder) ![]const u8 {
        const data = self.data[self.pos..];
        self.pos = self.data.len;
        return data;
    }

    /// Parse ParameterStatus message
    pub fn parseParameterStatus(self: *Decoder) !struct { name: []const u8, value: []const u8 } {
        const name = try self.readCString();
        const value = try self.readCString();
        return .{ .name = name, .value = value };
    }

    /// Parse BackendKeyData message
    pub fn parseBackendKeyData(self: *Decoder) !struct { process_id: u32, secret_key: u32 } {
        const process_id = try self.readU32();
        const secret_key = try self.readU32();
        return .{ .process_id = process_id, .secret_key = secret_key };
    }

    /// Parse NotificationResponse message.
    ///
    /// Payload format: i32(process_id) + cstring(channel) + cstring(payload)
    pub fn parseNotificationResponse(self: *Decoder) !struct { process_id: i32, channel: []const u8, payload: []const u8 } {
        const process_id = try self.readI32();
        const channel = try self.readCString();
        const payload = try self.readCString();
        if (self.remaining() != 0) return error.InvalidNotificationPayload;
        return .{
            .process_id = process_id,
            .channel = channel,
            .payload = payload,
        };
    }

    /// Parse CopyIn/CopyOut/CopyBoth response payload.
    ///
    /// Payload format: u8(overall_format) + i16(column_count) + i16[column_count](column_formats)
    pub fn parseCopyResponse(self: *Decoder, allocator: std.mem.Allocator) !struct { format: u8, column_formats: []u8 } {
        const format = try self.readByte();
        const raw_count = try self.readI16();
        if (raw_count < 0) return error.InvalidCopyResponse;

        const column_count: usize = @intCast(raw_count);
        var column_formats = try allocator.alloc(u8, column_count);
        errdefer allocator.free(column_formats);

        for (0..column_count) |i| {
            const raw_format = try self.readI16();
            if (raw_format != 0 and raw_format != 1) return error.InvalidCopyResponse;
            column_formats[i] = @intCast(raw_format);
        }

        if (self.remaining() != 0) return error.InvalidCopyResponse;
        return .{
            .format = format,
            .column_formats = column_formats,
        };
    }

    /// Parse ReadyForQuery message
    pub fn parseReadyForQuery(self: *Decoder) !TransactionStatus {
        const status = try self.readByte();
        return @enumFromInt(status);
    }

    /// Parse RowDescription message
    pub fn parseRowDescription(self: *Decoder, allocator: std.mem.Allocator) ![]FieldDescription {
        const field_count = try self.readU16();
        var fields = try allocator.alloc(FieldDescription, field_count);
        errdefer allocator.free(fields);

        for (0..field_count) |i| {
            fields[i] = .{
                .name = try self.readCString(),
                .table_oid = try self.readU32(),
                .column_index = try self.readU16(),
                .type_oid = try self.readU32(),
                .type_len = try self.readI16(),
                .type_modifier = try self.readI32(),
                .format_code = try self.readU16(),
            };
        }

        return fields;
    }

    /// Parse DataRow message, returns column values (null for NULL)
    pub fn parseDataRow(self: *Decoder, allocator: std.mem.Allocator) ![]?[]const u8 {
        const col_count = try self.readU16();
        var columns = try allocator.alloc(?[]const u8, col_count);
        errdefer allocator.free(columns);

        for (0..col_count) |i| {
            const len = try self.readI32();
            if (len < 0) {
                columns[i] = null; // NULL value
            } else {
                columns[i] = try self.readBytes(@intCast(len));
            }
        }

        return columns;
    }

    /// Parse CommandComplete message
    pub fn parseCommandComplete(self: *Decoder) ![]const u8 {
        return try self.readCString();
    }

    /// Parse ErrorResponse message
    pub fn parseErrorResponse(self: *Decoder) !ErrorInfo {
        var info = ErrorInfo{};

        while (true) {
            const field_type = try self.readByte();
            if (field_type == 0) break;

            const value = try self.readCString();

            switch (@as(ErrorField, @enumFromInt(field_type))) {
                .severity => info.severity = value,
                .code => info.code = value,
                .message => info.message = value,
                .detail => info.detail = value,
                .hint => info.hint = value,
                .position => info.position = value,
                else => {}, // Ignore unknown fields
            }
        }

        return info;
    }
};

// ==================== Tests ====================

test "decode simple message header" {
    const data = [_]u8{ 'Z', 0, 0, 0, 5, 'I' }; // ReadyForQuery + Idle
    var decoder = Decoder.init(&data);

    const header = try decoder.readHeader();
    try std.testing.expectEqual(BackendMessage.ready_for_query, header.msg_type);
    try std.testing.expectEqual(@as(u32, 5), header.length);
}

test "decode ready for query" {
    const data = [_]u8{'I'}; // Idle
    var decoder = Decoder.init(&data);

    const status = try decoder.parseReadyForQuery();
    try std.testing.expectEqual(TransactionStatus.idle, status);
}

test "decode authentication ok" {
    const data = [_]u8{ 0, 0, 0, 0 }; // AuthOk = 0
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.ok, auth_type);
}

test "decode authentication md5 salt" {
    const data = [_]u8{ 0, 0, 0, 5, 0x12, 0x34, 0x56, 0x78 };
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.md5_password, auth_type);

    const salt = try decoder.parseAuthenticationMd5Salt();
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, &salt);
}

test "decode authentication sasl mechanisms" {
    const data = [_]u8{
        0,    0,    0,    10, // SASL auth code
        'S',  'C',  'R',  'A', 'M', '-', 'S', 'H',
        'A',  '-',  '2',  '5', '6', 0,
        'S',  'C',  'R',  'A', 'M', '-', 'S', 'H',
        'A',  '-',  '2',  '5', '6', '-', 'P', 'L',
        'U',  'S',  0,
        0,
    };
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.sasl, auth_type);

    const mechs = try decoder.parseAuthenticationSaslMechanisms(std.testing.allocator);
    defer std.testing.allocator.free(mechs);

    try std.testing.expectEqual(@as(usize, 2), mechs.len);
    try std.testing.expectEqualStrings("SCRAM-SHA-256", mechs[0]);
    try std.testing.expectEqualStrings("SCRAM-SHA-256-PLUS", mechs[1]);
}

test "decode authentication sasl data" {
    const data = [_]u8{ 0, 0, 0, 11, 'r', '=', 'a', ',', 's', '=', 'b' };
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.sasl_continue, auth_type);

    const sasl_data = try decoder.parseAuthenticationSaslData();
    try std.testing.expectEqualStrings("r=a,s=b", sasl_data);
}

test "decode notification response" {
    const data = [_]u8{
        0,   0,   0,   123, // process id
        'm', 'y', '_', 'c', 'h', 'a', 'n', 0, // channel
        'h', 'e', 'l', 'l', 'o', 0, // payload
    };
    var decoder = Decoder.init(&data);

    const notification = try decoder.parseNotificationResponse();
    try std.testing.expectEqual(@as(i32, 123), notification.process_id);
    try std.testing.expectEqualStrings("my_chan", notification.channel);
    try std.testing.expectEqualStrings("hello", notification.payload);
}

test "decode copy response" {
    const data = [_]u8{
        0, // overall format
        0, 2, // 2 column formats
        0, 0, // text
        0, 1, // binary
    };
    var decoder = Decoder.init(&data);

    const copy = try decoder.parseCopyResponse(std.testing.allocator);
    defer std.testing.allocator.free(copy.column_formats);

    try std.testing.expectEqual(@as(u8, 0), copy.format);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, copy.column_formats);
}

test "decode c string" {
    const data = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0, 'w', 'o', 'r', 'l', 'd', 0 };
    var decoder = Decoder.init(&data);

    const s1 = try decoder.readCString();
    try std.testing.expectEqualStrings("hello", s1);

    const s2 = try decoder.readCString();
    try std.testing.expectEqualStrings("world", s2);
}
