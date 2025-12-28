//! MAC Address Types
//!
//! Support for PostgreSQL macaddr (6 bytes) and macaddr8 (8 bytes) types.

const std = @import("std");

/// 6-byte MAC address (macaddr)
pub const MacAddr = struct {
    bytes: [6]u8,

    pub fn fromBytes(bytes: [6]u8) MacAddr {
        return .{ .bytes = bytes };
    }

    /// Parse from text format: "08:00:2b:01:02:03" or "08-00-2b-01-02-03"
    pub fn fromText(text: []const u8) !MacAddr {
        if (text.len != 17) return error.InvalidMacAddr;

        var bytes: [6]u8 = undefined;
        var idx: usize = 0;

        var i: usize = 0;
        while (i < 17 and idx < 6) : (i += 3) {
            bytes[idx] = std.fmt.parseInt(u8, text[i .. i + 2], 16) catch return error.InvalidMacAddr;
            idx += 1;
        }

        if (idx != 6) return error.InvalidMacAddr;
        return .{ .bytes = bytes };
    }

    /// Format to text: "08:00:2b:01:02:03"
    pub fn toText(self: MacAddr, buf: *[17]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.bytes[0], self.bytes[1], self.bytes[2],
            self.bytes[3], self.bytes[4], self.bytes[5],
        }) catch unreachable;
        return buf[0..17];
    }

    pub fn eql(self: MacAddr, other: MacAddr) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// 8-byte MAC address (macaddr8)
pub const MacAddr8 = struct {
    bytes: [8]u8,

    pub fn fromBytes(bytes: [8]u8) MacAddr8 {
        return .{ .bytes = bytes };
    }

    /// Parse from text format: "08:00:2b:01:02:03:04:05"
    pub fn fromText(text: []const u8) !MacAddr8 {
        if (text.len != 23) return error.InvalidMacAddr8;

        var bytes: [8]u8 = undefined;
        var idx: usize = 0;

        var i: usize = 0;
        while (i < 23 and idx < 8) : (i += 3) {
            bytes[idx] = std.fmt.parseInt(u8, text[i .. i + 2], 16) catch return error.InvalidMacAddr8;
            idx += 1;
        }

        if (idx != 8) return error.InvalidMacAddr8;
        return .{ .bytes = bytes };
    }

    /// Format to text: "08:00:2b:01:02:03:04:05"
    pub fn toText(self: MacAddr8, buf: *[23]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            self.bytes[4], self.bytes[5], self.bytes[6], self.bytes[7],
        }) catch unreachable;
        return buf[0..23];
    }

    pub fn eql(self: MacAddr8, other: MacAddr8) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

// ==================== Tests ====================

test "MacAddr fromBytes" {
    const mac = MacAddr.fromBytes(.{ 0x08, 0x00, 0x2b, 0x01, 0x02, 0x03 });
    try std.testing.expectEqual(@as(u8, 0x08), mac.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x03), mac.bytes[5]);
}

test "MacAddr fromText" {
    const mac = try MacAddr.fromText("08:00:2b:01:02:03");
    try std.testing.expectEqual(@as(u8, 0x08), mac.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x2b), mac.bytes[2]);
}

test "MacAddr toText" {
    const mac = MacAddr.fromBytes(.{ 0x08, 0x00, 0x2b, 0x01, 0x02, 0x03 });
    var buf: [17]u8 = undefined;
    const text = mac.toText(&buf);
    try std.testing.expectEqualStrings("08:00:2b:01:02:03", text);
}

test "MacAddr8 fromText" {
    const mac = try MacAddr8.fromText("08:00:2b:01:02:03:04:05");
    try std.testing.expectEqual(@as(u8, 0x08), mac.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x05), mac.bytes[7]);
}
