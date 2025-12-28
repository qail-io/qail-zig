// UUID Type
//
// PostgreSQL UUID type support with 16-byte binary and 36-byte hex formats.

const std = @import("std");

/// UUID value (16 bytes)
pub const Uuid = struct {
    bytes: [16]u8,

    /// Create from raw 16-byte array
    pub fn fromBytes(bytes: [16]u8) Uuid {
        return .{ .bytes = bytes };
    }

    /// Parse from 36-character hex string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
    pub fn fromHex(hex: []const u8) !Uuid {
        if (hex.len != 36) return error.InvalidUuidLength;

        var result: [16]u8 = undefined;
        var byte_idx: usize = 0;
        var i: usize = 0;

        while (i < 36 and byte_idx < 16) {
            if (hex[i] == '-') {
                i += 1;
                continue;
            }

            const high = try hexDigit(hex[i]);
            const low = try hexDigit(hex[i + 1]);
            result[byte_idx] = (high << 4) | low;
            byte_idx += 1;
            i += 2;
        }

        return .{ .bytes = result };
    }

    /// Convert to 36-character hex string
    pub fn toHex(self: Uuid) [36]u8 {
        const hex_chars = "0123456789abcdef";
        var result: [36]u8 = undefined;
        var pos: usize = 0;

        for (self.bytes, 0..) |byte, i| {
            result[pos] = hex_chars[byte >> 4];
            result[pos + 1] = hex_chars[byte & 0x0F];
            pos += 2;

            // Add dashes at positions 8, 13, 18, 23
            if (i == 3 or i == 5 or i == 7 or i == 9) {
                result[pos] = '-';
                pos += 1;
            }
        }

        return result;
    }

    /// Format for printing
    pub fn format(self: Uuid, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(&self.toHex());
    }

    fn hexDigit(c: u8) !u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => error.InvalidHexDigit,
        };
    }
};

// ==================== Tests ====================

test "Uuid fromBytes" {
    const bytes = [_]u8{0x12} ** 16;
    const uuid = Uuid.fromBytes(bytes);
    try std.testing.expectEqual(bytes, uuid.bytes);
}

test "Uuid toHex" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
    const uuid = Uuid.fromBytes(bytes);
    const hex = uuid.toHex();
    try std.testing.expectEqualStrings("12345678-9abc-def0-1234-56789abcdef0", &hex);
}

test "Uuid fromHex" {
    const uuid = try Uuid.fromHex("12345678-9abc-def0-1234-56789abcdef0");
    const expected = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
    try std.testing.expectEqual(expected, uuid.bytes);
}
