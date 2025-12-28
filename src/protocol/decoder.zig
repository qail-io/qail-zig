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

test "decode c string" {
    const data = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0, 'w', 'o', 'r', 'l', 'd', 0 };
    var decoder = Decoder.init(&data);

    const s1 = try decoder.readCString();
    try std.testing.expectEqualStrings("hello", s1);

    const s2 = try decoder.readCString();
    try std.testing.expectEqualStrings("world", s2);
}
