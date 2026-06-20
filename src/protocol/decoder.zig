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

    pub fn validateBackendMessagePayload(msg_type: BackendMessage, payload: []const u8) !void {
        var decoder = Decoder.init(payload);
        switch (msg_type) {
            .backend_key_data => _ = try decoder.parseBackendKeyData(),
            .command_complete => _ = try decoder.parseCommandComplete(),
            .copy_done,
            .empty_query,
            .no_data,
            .parse_complete,
            .bind_complete,
            .close_complete,
            .portal_suspended,
            => if (payload.len != 0) return error.InvalidBackendMessagePayload,
            .data_row => try decoder.validateDataRowPayload(),
            .error_response, .notice => _ = try decoder.parseErrorResponse(),
            .notification => _ = try decoder.parseNotificationResponse(),
            .parameter_status => _ = try decoder.parseParameterStatus(),
            .ready_for_query => _ = try decoder.parseReadyForQuery(),
            else => {},
        }
    }

    pub fn validateBackendMessagePayloadByte(msg_type: u8, payload: []const u8) !void {
        try validateBackendMessagePayload(@enumFromInt(msg_type), payload);
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

    fn readUtf8CString(self: *Decoder) ![]const u8 {
        const str = try self.readCString();
        if (!std.unicode.utf8ValidateSlice(str)) return error.InvalidUtf8;
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

    fn peekDataRowColumnCount(self: *const Decoder) !usize {
        if (self.pos + 2 > self.data.len) return error.EndOfStream;
        return @intCast(std.mem.readInt(u16, self.data[self.pos..][0..2], .big));
    }

    // ==================== Message Parsing ====================

    /// Read message header (type + length), returns (msg_type, payload_length)
    pub fn readHeader(self: *Decoder) !struct { msg_type: BackendMessage, length: u32 } {
        const msg_type_byte = try self.readByte();
        const length = try self.readU32();
        if (length < 4) return error.InvalidMessageLength;
        return .{
            .msg_type = @enumFromInt(msg_type_byte),
            .length = length,
        };
    }

    /// Parse AuthenticationOk/etc message
    pub fn parseAuthentication(self: *Decoder) !AuthType {
        const auth_type = try self.readU32();
        const parsed: AuthType = @enumFromInt(auth_type);

        switch (parsed) {
            // Fixed-size auth variants: only 4-byte auth code is valid.
            .ok,
            .kerberos_v5,
            .cleartext_password,
            .scm_credential,
            .gss,
            .sspi,
            => if (self.remaining() != 0) return error.InvalidAuthenticationPayload,

            // MD5 variant: 4-byte auth code + 4-byte salt.
            .md5_password => if (self.remaining() != 4) return error.InvalidAuthenticationPayload,

            // Variable-size variants parsed by dedicated helpers.
            .sasl,
            .sasl_continue,
            .sasl_final,
            .gss_continue,
            => {},
            else => {},
        }

        return parsed;
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
        var mechs: std.ArrayList([]const u8) = .empty;
        defer mechs.deinit(allocator);

        while (true) {
            const mechanism = self.readUtf8CString() catch return error.InvalidSaslMechanismList;
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
        const name = self.readUtf8CString() catch return error.InvalidParameterStatusPayload;
        if (name.len == 0) return error.InvalidParameterStatusPayload;
        const value = self.readUtf8CString() catch return error.InvalidParameterStatusPayload;
        if (self.remaining() != 0) return error.InvalidParameterStatusPayload;
        return .{ .name = name, .value = value };
    }

    /// Parse BackendKeyData message.
    ///
    /// Protocol 3.0 uses a fixed 4-byte cancel key.
    /// Protocol 3.2 can carry variable-length cancel key bytes (4..=256).
    ///
    /// For compatibility with legacy `i32` cancel wrappers, this parser returns:
    /// - `secret_key`: real 4-byte key when present
    /// - `secret_key`: `0` for extended-length keys
    /// - `secret_key_bytes`: full `4..=256` bytes used by protocol 3.2 cancel
    pub fn parseBackendKeyData(self: *Decoder) !struct { process_id: u32, secret_key: u32, secret_key_bytes: []const u8 } {
        const process_id = try self.readU32();
        if (process_id == 0 or process_id > std.math.maxInt(i32)) return error.InvalidBackendKeyDataPayload;
        const secret_len = self.remaining();
        if (secret_len < 4 or secret_len > 256) return error.InvalidBackendKeyDataPayload;

        const secret_key_bytes = try self.readBytes(secret_len);
        const secret_key: u32 = if (secret_len == 4)
            std.mem.readInt(u32, secret_key_bytes[0..4], .big)
        else
            0;

        if (self.remaining() != 0) return error.InvalidBackendKeyDataPayload;
        return .{
            .process_id = process_id,
            .secret_key = secret_key,
            .secret_key_bytes = secret_key_bytes,
        };
    }

    pub const NegotiateProtocolVersion = struct {
        newest_minor_supported: u32,
        unrecognized_options: [][]const u8,
    };

    /// Parse NegotiateProtocolVersion payload.
    pub fn parseNegotiateProtocolVersion(
        self: *Decoder,
        allocator: std.mem.Allocator,
    ) !NegotiateProtocolVersion {
        if (self.remaining() < 8) return error.InvalidNegotiateProtocolVersionPayload;
        const newest_minor_supported = try self.readU32();
        const raw_count = try self.readI32();
        if (raw_count < 0) return error.InvalidNegotiateProtocolVersionPayload;

        const option_count: usize = @intCast(raw_count);
        // Each option is NUL-terminated, so even an empty option consumes 1 byte.
        if (option_count > self.remaining()) return error.InvalidNegotiateProtocolVersionPayload;

        var options = try allocator.alloc([]const u8, option_count);
        var parsed: usize = 0;
        errdefer allocator.free(options);
        while (parsed < option_count) : (parsed += 1) {
            options[parsed] = self.readUtf8CString() catch return error.InvalidNegotiateProtocolVersionPayload;
        }
        if (self.remaining() != 0) return error.InvalidNegotiateProtocolVersionPayload;

        return .{
            .newest_minor_supported = newest_minor_supported,
            .unrecognized_options = options,
        };
    }

    /// Parse protocol minor from NegotiateProtocolVersion field.
    ///
    /// Supports both:
    /// - pure minor values (0, 1, 2, ...)
    /// - packed protocol version values (`3 << 16 | minor`)
    pub fn parseProtocolMinorFromNegotiate(newest_minor_supported: u32) !u16 {
        if (newest_minor_supported <= std.math.maxInt(u16)) {
            return @intCast(newest_minor_supported);
        }

        const major: u16 = @intCast(newest_minor_supported >> 16);
        const minor: u16 = @intCast(newest_minor_supported & 0xFFFF);
        if (major != 3) return error.InvalidNegotiateProtocolVersionPayload;
        return minor;
    }

    /// Parse NotificationResponse message.
    ///
    /// Payload format: i32(process_id) + cstring(channel) + cstring(payload)
    pub fn parseNotificationResponse(self: *Decoder) !struct { process_id: i32, channel: []const u8, payload: []const u8 } {
        const process_id = try self.readI32();
        if (process_id <= 0) return error.InvalidNotificationPayload;
        const channel = self.readUtf8CString() catch return error.InvalidNotificationPayload;
        if (channel.len == 0) return error.InvalidNotificationPayload;
        const payload = self.readUtf8CString() catch return error.InvalidNotificationPayload;
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
        if (format != 0 and format != 1) return error.InvalidCopyResponse;

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
        if (self.remaining() != 1) return error.InvalidReadyForQueryPayload;
        const status = try self.readByte();
        return switch (status) {
            'I' => .idle,
            'T' => .in_transaction,
            'E' => .failed,
            else => error.InvalidReadyForQueryStatus,
        };
    }

    /// Parse RowDescription message
    pub fn parseRowDescription(self: *Decoder, allocator: std.mem.Allocator) ![]FieldDescription {
        const raw_field_count = try self.readI16();
        if (raw_field_count < 0) return error.InvalidRowDescriptionPayload;
        const field_count: usize = @intCast(raw_field_count);

        const min_field_bytes = std.math.mul(usize, field_count, 19) catch return error.InvalidRowDescriptionPayload;
        if (self.remaining() < min_field_bytes) return error.InvalidRowDescriptionPayload;

        var fields = try allocator.alloc(FieldDescription, field_count);
        errdefer allocator.free(fields);

        for (0..field_count) |i| {
            fields[i] = .{
                .name = self.readUtf8CString() catch return error.InvalidRowDescriptionPayload,
                .table_oid = try self.readU32(),
                .column_index = try self.readU16(),
                .type_oid = try self.readU32(),
                .type_len = try self.readI16(),
                .type_modifier = try self.readI32(),
                .format_code = blk: {
                    const format_code = try self.readU16();
                    if (format_code != 0 and format_code != 1) return error.InvalidRowDescriptionPayload;
                    break :blk format_code;
                },
            };
        }

        if (self.remaining() != 0) return error.InvalidRowDescriptionPayload;
        return fields;
    }

    /// Parse DataRow message, returns borrowed column slices (null for NULL).
    ///
    /// Returned byte slices alias the decoder input buffer and are only valid
    /// until the underlying message buffer is reused.
    pub fn parseDataRow(self: *Decoder, allocator: std.mem.Allocator) ![]?[]const u8 {
        const col_count = try self.peekDataRowColumnCount();
        const columns = try allocator.alloc(?[]const u8, col_count);
        errdefer allocator.free(columns);

        _ = try self.parseDataRowInto(columns);
        return columns;
    }

    /// Validate a DataRow payload without allocating column storage.
    pub fn validateDataRowPayload(self: *Decoder) !void {
        const raw_count = self.readU16() catch return error.InvalidDataRowPayload;
        const col_count: usize = @intCast(raw_count);

        for (0..col_count) |_| {
            const len = self.readI32() catch return error.InvalidDataRowPayload;
            if (len == -1) continue;
            if (len < -1) return error.InvalidDataRowPayload;
            _ = self.readBytes(@intCast(len)) catch return error.InvalidDataRowPayload;
        }

        if (self.remaining() != 0) return error.InvalidDataRowPayload;
    }

    /// Parse DataRow payload into caller-provided column slice.
    ///
    /// Returned slice aliases the provided `columns` storage and each non-null
    /// value aliases the decoder input payload.
    pub fn parseDataRowInto(self: *Decoder, columns: []?[]const u8) ![]?[]const u8 {
        const raw_count = try self.readU16();
        const col_count: usize = @intCast(raw_count);
        if (columns.len < col_count) return error.ColumnBufferTooSmall;

        const out = columns[0..col_count];
        for (0..col_count) |i| {
            const len = try self.readI32();
            if (len == -1) {
                out[i] = null; // NULL value
            } else if (len < -1) {
                return error.InvalidDataRowPayload;
            } else {
                out[i] = try self.readBytes(@intCast(len));
            }
        }

        if (self.remaining() != 0) return error.InvalidDataRowPayload;
        return out;
    }

    /// Parse DataRow payload and return only the first column.
    ///
    /// Still validates the full payload shape, but avoids caller-side
    /// allocation and per-column output materialization.
    pub fn parseDataRowFirstColumn(self: *Decoder) !?[]const u8 {
        const raw_count = try self.readU16();
        const col_count: usize = @intCast(raw_count);

        var first_column: ?[]const u8 = null;
        for (0..col_count) |i| {
            const len = try self.readI32();
            if (len == -1) {
                if (i == 0) first_column = null;
            } else if (len < -1) {
                return error.InvalidDataRowPayload;
            } else {
                const value = try self.readBytes(@intCast(len));
                if (i == 0) first_column = value;
            }
        }

        if (self.remaining() != 0) return error.InvalidDataRowPayload;
        return first_column;
    }

    /// Parse DataRow message and deep-copy all non-null column bytes.
    ///
    /// Returned slices are allocator-owned and must be freed by caller:
    /// free each non-null column value, then free the columns slice.
    pub fn parseDataRowOwned(self: *Decoder, allocator: std.mem.Allocator) ![]?[]const u8 {
        const col_count = try self.readU16();
        var columns = try allocator.alloc(?[]const u8, col_count);
        var copied: usize = 0;
        errdefer {
            for (columns[0..copied]) |maybe_col| {
                if (maybe_col) |col| allocator.free(col);
            }
            allocator.free(columns);
        }

        for (0..col_count) |i| {
            const len = try self.readI32();
            if (len == -1) {
                columns[i] = null;
            } else if (len < -1) {
                return error.InvalidDataRowPayload;
            } else {
                const borrowed = try self.readBytes(@intCast(len));
                columns[i] = try allocator.dupe(u8, borrowed);
            }
            copied += 1;
        }

        if (self.remaining() != 0) return error.InvalidDataRowPayload;
        return columns;
    }

    /// Parse CommandComplete message
    pub fn parseCommandComplete(self: *Decoder) ![]const u8 {
        const tag = self.readUtf8CString() catch return error.InvalidCommandCompletePayload;
        if (tag.len == 0) return error.InvalidCommandCompletePayload;
        if (self.remaining() != 0) return error.InvalidCommandCompletePayload;
        return tag;
    }

    /// Parse ErrorResponse message
    pub fn parseErrorResponse(self: *Decoder) !ErrorInfo {
        var info = ErrorInfo{};

        while (true) {
            const field_type = try self.readByte();
            if (field_type == 0) break;

            const value = self.readUtf8CString() catch return error.InvalidErrorResponsePayload;

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

        if (self.remaining() != 0) return error.InvalidErrorResponsePayload;
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

test "decode simple message header rejects invalid length field" {
    const data = [_]u8{ 'Z', 0, 0, 0, 3 };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidMessageLength, decoder.readHeader());
}

test "decode ready for query" {
    const data = [_]u8{'I'}; // Idle
    var decoder = Decoder.init(&data);

    const status = try decoder.parseReadyForQuery();
    try std.testing.expectEqual(TransactionStatus.idle, status);
}

test "decode ready for query rejects invalid status byte" {
    const data = [_]u8{'X'};
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidReadyForQueryStatus, decoder.parseReadyForQuery());
}

test "decode ready for query rejects trailing bytes" {
    const data = [_]u8{ 'I', 0 };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidReadyForQueryPayload, decoder.parseReadyForQuery());
}

test "decode authentication ok" {
    const data = [_]u8{ 0, 0, 0, 0 }; // AuthOk = 0
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.ok, auth_type);
}

test "decode authentication ok rejects trailing bytes" {
    const data = [_]u8{
        0, 0, 0, 0,
        1,
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidAuthenticationPayload, decoder.parseAuthentication());
}

test "decode authentication md5 salt" {
    const data = [_]u8{ 0, 0, 0, 5, 0x12, 0x34, 0x56, 0x78 };
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.md5_password, auth_type);

    const salt = try decoder.parseAuthenticationMd5Salt();
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, &salt);
}

test "decode authentication md5 rejects missing salt bytes" {
    const data = [_]u8{
        0, 0, 0, 5,
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidAuthenticationPayload, decoder.parseAuthentication());
}

test "decode authentication sasl mechanisms" {
    const data = [_]u8{
        0,   0,   0,   10, // SASL auth code
        'S', 'C', 'R', 'A',
        'M', '-', 'S', 'H',
        'A', '-', '2', '5',
        '6', 0,   'S', 'C',
        'R', 'A', 'M', '-',
        'S', 'H', 'A', '-',
        '2', '5', '6', '-',
        'P', 'L', 'U', 'S',
        0,   0,
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

test "decode authentication sasl rejects invalid utf8 mechanism" {
    const data = [_]u8{
        0,    0, 0, 10, // SASL auth code
        0xff, 0, 0,
    };
    var decoder = Decoder.init(&data);

    const auth_type = try decoder.parseAuthentication();
    try std.testing.expectEqual(AuthType.sasl, auth_type);
    try std.testing.expectError(error.InvalidSaslMechanismList, decoder.parseAuthenticationSaslMechanisms(std.testing.allocator));
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
        0, 0, 0, 123, // process id
        'm', 'y', '_', 'c', 'h', 'a', 'n', 0, // channel
        'h', 'e', 'l', 'l', 'o', 0, // payload
    };
    var decoder = Decoder.init(&data);

    const notification = try decoder.parseNotificationResponse();
    try std.testing.expectEqual(@as(i32, 123), notification.process_id);
    try std.testing.expectEqualStrings("my_chan", notification.channel);
    try std.testing.expectEqualStrings("hello", notification.payload);
}

test "decode notification response rejects empty channel" {
    const data = [_]u8{
        0, 0, 0, 123, // process id
        0, // empty channel
        'h', 'e', 'l', 'l', 'o', 0, // payload
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidNotificationPayload, decoder.parseNotificationResponse());
}

test "decode notification response rejects non-positive process id" {
    const zero_pid = [_]u8{
        0,   0,   0, 0, // invalid process id
        'c', 'h', 0, 'o',
        'k', 0,
    };
    var zero_decoder = Decoder.init(&zero_pid);
    try std.testing.expectError(error.InvalidNotificationPayload, zero_decoder.parseNotificationResponse());

    const negative_pid = [_]u8{
        255, 255, 255, 255, // -1 as signed i32
        'c', 'h', 0,   'o',
        'k', 0,
    };
    var negative_decoder = Decoder.init(&negative_pid);
    try std.testing.expectError(error.InvalidNotificationPayload, negative_decoder.parseNotificationResponse());
}

test "decode notification response rejects invalid utf8 channel or payload" {
    const bad_channel = [_]u8{
        0, 0, 0, 123, // process id
        0xff, 0, // invalid channel
        'h', 'e', 'l', 'l', 'o', 0, // payload
    };
    var channel_decoder = Decoder.init(&bad_channel);
    try std.testing.expectError(error.InvalidNotificationPayload, channel_decoder.parseNotificationResponse());

    const bad_payload = [_]u8{
        0, 0, 0, 123, // process id
        'c', 'h', 0, // channel
        0xff, 0, // invalid payload
    };
    var payload_decoder = Decoder.init(&bad_payload);
    try std.testing.expectError(error.InvalidNotificationPayload, payload_decoder.parseNotificationResponse());
}

test "decode parameter status rejects trailing bytes" {
    const data = [_]u8{
        'a', 0,
        'b', 0,
        'x',
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidParameterStatusPayload, decoder.parseParameterStatus());
}

test "decode parameter status rejects empty name" {
    const data = [_]u8{
        0,
        'v',
        'a',
        'l',
        'u',
        'e',
        0,
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidParameterStatusPayload, decoder.parseParameterStatus());
}

test "decode parameter status rejects invalid utf8 name or value" {
    const bad_name = [_]u8{ 0xff, 0, 'v', 0 };
    var name_decoder = Decoder.init(&bad_name);
    try std.testing.expectError(error.InvalidParameterStatusPayload, name_decoder.parseParameterStatus());

    const bad_value = [_]u8{ 'n', 0, 0xff, 0 };
    var value_decoder = Decoder.init(&bad_value);
    try std.testing.expectError(error.InvalidParameterStatusPayload, value_decoder.parseParameterStatus());
}

test "decode negotiate protocol version payload" {
    const data = [_]u8{
        0, 0, 0, 2, // newest minor supported
        0,   0, 0,   2, // unrecognized option count
        'a', 0, 'b', 0,
    };
    var decoder = Decoder.init(&data);
    const negotiate = try decoder.parseNegotiateProtocolVersion(std.testing.allocator);
    defer std.testing.allocator.free(negotiate.unrecognized_options);

    try std.testing.expectEqual(@as(u32, 2), negotiate.newest_minor_supported);
    try std.testing.expectEqual(@as(usize, 2), negotiate.unrecognized_options.len);
    try std.testing.expectEqualStrings("a", negotiate.unrecognized_options[0]);
    try std.testing.expectEqualStrings("b", negotiate.unrecognized_options[1]);
}

test "decode negotiate protocol version rejects invalid utf8 option" {
    const data = [_]u8{
        0, 0, 0, 2, // newest minor supported
        0,    0, 0, 1, // unrecognized option count
        0xff, 0,
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(
        error.InvalidNegotiateProtocolVersionPayload,
        decoder.parseNegotiateProtocolVersion(std.testing.allocator),
    );
}

test "decode negotiate protocol version rejects impossible option count" {
    const data = [_]u8{
        0, 3, 0, 0, // packed 3.0
        0, 0, 4, 0, // unrecognized option count = 1024
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(
        error.InvalidNegotiateProtocolVersionPayload,
        decoder.parseNegotiateProtocolVersion(std.testing.allocator),
    );
}

test "parse protocol minor from negotiate supports packed format" {
    try std.testing.expectEqual(@as(u16, 2), try Decoder.parseProtocolMinorFromNegotiate(2));
    try std.testing.expectEqual(@as(u16, 2), try Decoder.parseProtocolMinorFromNegotiate((@as(u32, 3) << 16) | 2));
    try std.testing.expectError(error.InvalidNegotiateProtocolVersionPayload, Decoder.parseProtocolMinorFromNegotiate((@as(u32, 4) << 16) | 0));
}

test "decode backend key data with legacy 4-byte key" {
    const data = [_]u8{
        0, 0, 0, 1, // process id
        0, 0, 0, 2, // secret key
    };
    var decoder = Decoder.init(&data);

    const key = try decoder.parseBackendKeyData();
    try std.testing.expectEqual(@as(u32, 1), key.process_id);
    try std.testing.expectEqual(@as(u32, 2), key.secret_key);
    try std.testing.expectEqual(@as(usize, 4), key.secret_key_bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2 }, key.secret_key_bytes);
}

test "decode backend key data rejects non-positive signed process id" {
    const zero_pid = [_]u8{
        0, 0, 0, 0, // invalid process id
        0, 0, 0, 2, // secret key
    };
    var zero_decoder = Decoder.init(&zero_pid);
    try std.testing.expectError(error.InvalidBackendKeyDataPayload, zero_decoder.parseBackendKeyData());

    const negative_pid = [_]u8{
        255, 255, 255, 249, // -7 as signed i32
        0,   0,   0,   2,
    };
    var negative_decoder = Decoder.init(&negative_pid);
    try std.testing.expectError(error.InvalidBackendKeyDataPayload, negative_decoder.parseBackendKeyData());
}

test "decode backend key data accepts extended key payload" {
    const data = [_]u8{
        0, 0, 0, 1, // process id
        1, 2, 3, 4, 5, 6, 7, 8, // extended key bytes
    };
    var decoder = Decoder.init(&data);

    const key = try decoder.parseBackendKeyData();
    try std.testing.expectEqual(@as(u32, 1), key.process_id);
    // Legacy i32 key is compatibility-only for 4-byte keys.
    try std.testing.expectEqual(@as(u32, 0), key.secret_key);
    try std.testing.expectEqual(@as(usize, 8), key.secret_key_bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, key.secret_key_bytes);
}

test "decode backend key data rejects key shorter than 4 bytes" {
    const data = [_]u8{
        0, 0, 0, 1, // process id
        1, 2, 3, // 3 bytes (invalid)
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidBackendKeyDataPayload, decoder.parseBackendKeyData());
}

test "decode backend key data rejects key longer than 256 bytes" {
    var data: [4 + 257]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 1, .big);
    @memset(data[4..], 0xAA);

    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidBackendKeyDataPayload, decoder.parseBackendKeyData());
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

test "decode copy response rejects invalid overall format" {
    const data = [_]u8{
        2, // invalid overall format
        0,
        0,
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidCopyResponse, decoder.parseCopyResponse(std.testing.allocator));
}

test "decode row description rejects negative field count" {
    const data = [_]u8{
        255, 255, // -1 fields
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidRowDescriptionPayload, decoder.parseRowDescription(std.testing.allocator));
}

test "decode row description rejects invalid format code" {
    const data = [_]u8{
        0, 1, // field count = 1
        'i', 'd', 0, // field name
        0, 0, 0, 1, // table oid
        0, 1, // column index
        0, 0, 0, 23, // type oid
        0, 4, // type len
        255, 255, 255, 255, // type modifier
        0, 2, // invalid format code
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidRowDescriptionPayload, decoder.parseRowDescription(std.testing.allocator));
}

test "decode row description rejects invalid utf8 field name" {
    const data = [_]u8{
        0, 1, // field count = 1
        0xff, 0, // invalid field name
        0, 0, 0, 1, // table oid
        0, 1, // column index
        0, 0, 0, 23, // type oid
        0, 4, // type len
        255, 255, 255, 255, // type modifier
        0, 0, // format code
    };
    var decoder = Decoder.init(&data);
    try std.testing.expectError(error.InvalidRowDescriptionPayload, decoder.parseRowDescription(std.testing.allocator));
}

test "decode data row into caller buffer" {
    const payload = [_]u8{
        0, 2, // column count
        0, 0, 0, 1, 'a', // col0 = "a"
        255, 255, 255, 255, // col1 = NULL
    };
    var decoder = Decoder.init(&payload);
    var scratch = [_]?[]const u8{ null, null };
    const cols = try decoder.parseDataRowInto(&scratch);

    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("a", cols[0].?);
    try std.testing.expect(cols[1] == null);
}

test "decode data row first column" {
    const payload = [_]u8{
        0, 3, // column count
        0, 0, 0, 2, '4', '2', // col0 = "42"
        0, 0, 0, 1, 'x', // col1 = "x"
        255, 255, 255, 255, // col2 = NULL
    };
    var decoder = Decoder.init(&payload);
    const first = try decoder.parseDataRowFirstColumn();

    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("42", first.?);
}

test "decode data row first column handles null first value" {
    const payload = [_]u8{
        0, 2, // column count
        255, 255, 255, 255, // col0 = NULL
        0, 0, 0, 1, 'a', // col1 = "a"
    };
    var decoder = Decoder.init(&payload);
    const first = try decoder.parseDataRowFirstColumn();
    try std.testing.expect(first == null);
}

test "decode data row first column rejects invalid negative length" {
    const payload = [_]u8{
        0, 1, // column count
        255, 255, 255, 254, // -2 (invalid)
    };
    var decoder = Decoder.init(&payload);
    try std.testing.expectError(error.InvalidDataRowPayload, decoder.parseDataRowFirstColumn());
}

test "decode data row first column rejects trailing bytes" {
    const payload = [_]u8{
        0, 1, // column count
        0,   0, 0, 1, // len=1
        'a',
        'x', // trailing
    };
    var decoder = Decoder.init(&payload);
    try std.testing.expectError(error.InvalidDataRowPayload, decoder.parseDataRowFirstColumn());
}

test "validate backend payload rejects malformed data row" {
    const missing_column_len = [_]u8{
        0, 1, // one column, but no column length
    };
    try std.testing.expectError(
        error.InvalidDataRowPayload,
        Decoder.validateBackendMessagePayloadByte('D', &missing_column_len),
    );
}

test "decode data row into caller buffer rejects undersized storage" {
    const payload = [_]u8{
        0, 2, // column count
        255, 255, 255, 255, // col0 = NULL
        255, 255, 255, 255, // col1 = NULL
    };
    var decoder = Decoder.init(&payload);
    var scratch = [_]?[]const u8{null};
    try std.testing.expectError(error.ColumnBufferTooSmall, decoder.parseDataRowInto(&scratch));
}

test "decode data row into caller buffer rejects invalid negative length" {
    const payload = [_]u8{
        0, 1, // column count
        255, 255, 255, 254, // -2 (invalid)
    };
    var decoder = Decoder.init(&payload);
    var scratch = [_]?[]const u8{null};
    try std.testing.expectError(error.InvalidDataRowPayload, decoder.parseDataRowInto(&scratch));
}

test "decode data row into caller buffer rejects trailing bytes" {
    const payload = [_]u8{
        0, 1, // column count
        0,   0, 0, 1, // len=1
        'a',
        'x', // trailing
    };
    var decoder = Decoder.init(&payload);
    var scratch = [_]?[]const u8{null};
    try std.testing.expectError(error.InvalidDataRowPayload, decoder.parseDataRowInto(&scratch));
}

test "decode data row owned rejects invalid negative length" {
    const payload = [_]u8{
        0, 1, // column count
        255, 255, 255, 254, // -2 (invalid)
    };
    var decoder = Decoder.init(&payload);
    try std.testing.expectError(error.InvalidDataRowPayload, decoder.parseDataRowOwned(std.testing.allocator));
}

test "decode data row owned rejects trailing bytes" {
    const payload = [_]u8{
        0, 1, // column count
        0,   0, 0, 1, // len=1
        'a',
        'x', // trailing
    };
    var decoder = Decoder.init(&payload);
    try std.testing.expectError(error.InvalidDataRowPayload, decoder.parseDataRowOwned(std.testing.allocator));
}

test "decode command complete rejects trailing bytes" {
    const data = [_]u8{
        'S', 'E', 'L', 'E', 'C', 'T', ' ', '1', 0,
        'x',
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidCommandCompletePayload, decoder.parseCommandComplete());
}

test "decode command complete rejects invalid utf8 tag" {
    const data = [_]u8{ 0xff, 0 };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidCommandCompletePayload, decoder.parseCommandComplete());
}

test "validate backend payload rejects malformed fast control frames" {
    try std.testing.expectError(
        error.InvalidCommandCompletePayload,
        Decoder.validateBackendMessagePayloadByte('C', "SELECT 1"),
    );

    try std.testing.expectError(
        error.InvalidReadyForQueryPayload,
        Decoder.validateBackendMessagePayloadByte('Z', "II"),
    );
}

test "decode command complete rejects empty tag" {
    const data = [_]u8{0};
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidCommandCompletePayload, decoder.parseCommandComplete());
}

test "decode error response rejects invalid utf8 field" {
    const data = [_]u8{
        'M', 0xff, 0,
        0,
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidErrorResponsePayload, decoder.parseErrorResponse());
}

test "decode error response rejects trailing bytes" {
    const data = [_]u8{
        'M', 'e', 'r', 'r', 0,
        0,   'x',
    };
    var decoder = Decoder.init(&data);

    try std.testing.expectError(error.InvalidErrorResponsePayload, decoder.parseErrorResponse());
}

test "decode c string" {
    const data = [_]u8{ 'h', 'e', 'l', 'l', 'o', 0, 'w', 'o', 'r', 'l', 'd', 0 };
    var decoder = Decoder.init(&data);

    const s1 = try decoder.readCString();
    try std.testing.expectEqualStrings("hello", s1);

    const s2 = try decoder.readCString();
    try std.testing.expectEqualStrings("world", s2);
}
