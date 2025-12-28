// INET/CIDR Types
//
// PostgreSQL network address types support.

const std = @import("std");

/// IP address family
pub const Family = enum {
    v4,
    v6,

    pub fn addressLen(self: Family) usize {
        return switch (self) {
            .v4 => 4,
            .v6 => 16,
        };
    }
};

/// CIDR/INET value
pub const Cidr = struct {
    address: [16]u8,
    family: Family,
    netmask: u8,
    is_cidr: bool = true,

    /// Create IPv4 CIDR
    pub fn initV4(addr: [4]u8, mask: u8) Cidr {
        var result = Cidr{
            .address = [_]u8{0} ** 16,
            .family = .v4,
            .netmask = mask,
        };
        @memcpy(result.address[0..4], &addr);
        return result;
    }

    /// Create IPv6 CIDR
    pub fn initV6(addr: [16]u8, mask: u8) Cidr {
        return .{
            .address = addr,
            .family = .v6,
            .netmask = mask,
        };
    }

    /// Get address bytes slice
    pub fn addressBytes(self: *const Cidr) []const u8 {
        return self.address[0..self.family.addressLen()];
    }

    /// Format as string (e.g., "192.168.1.0/24")
    pub fn format(self: Cidr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.family) {
            .v4 => {
                try std.fmt.format(writer, "{}.{}.{}.{}/{}", .{
                    self.address[0],
                    self.address[1],
                    self.address[2],
                    self.address[3],
                    self.netmask,
                });
            },
            .v6 => {
                // Simplified IPv6 format (full notation)
                for (0..8) |i| {
                    if (i > 0) try writer.writeAll(":");
                    const high = self.address[i * 2];
                    const low = self.address[i * 2 + 1];
                    try std.fmt.format(writer, "{x:0>2}{x:0>2}", .{ high, low });
                }
                try std.fmt.format(writer, "/{}", .{self.netmask});
            },
        }
    }
};

// ==================== Tests ====================

test "Cidr v4" {
    const cidr = Cidr.initV4(.{ 192, 168, 1, 0 }, 24);
    try std.testing.expectEqual(Family.v4, cidr.family);
    try std.testing.expectEqual(@as(u8, 24), cidr.netmask);
}

test "Cidr v6" {
    const addr = [_]u8{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 12;
    const cidr = Cidr.initV6(addr, 64);
    try std.testing.expectEqual(Family.v6, cidr.family);
    try std.testing.expectEqual(@as(u8, 64), cidr.netmask);
}
