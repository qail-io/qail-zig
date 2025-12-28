// Timestamp Type
//
// PostgreSQL TIMESTAMP and TIMESTAMPTZ support.

const std = @import("std");

/// PostgreSQL epoch (2000-01-01 00:00:00 UTC)
pub const PG_EPOCH_OFFSET: i64 = 946684800; // Seconds from Unix epoch to PG epoch

/// PostgreSQL timestamp value
pub const Timestamp = struct {
    /// Microseconds since PostgreSQL epoch (2000-01-01)
    microseconds: i64,

    /// Create from microseconds since PG epoch
    pub fn fromMicros(us: i64) Timestamp {
        return .{ .microseconds = us };
    }

    /// Create from Unix epoch seconds
    pub fn fromEpoch(unix_secs: i64) Timestamp {
        return .{ .microseconds = (unix_secs - PG_EPOCH_OFFSET) * 1_000_000 };
    }

    /// Convert to Unix epoch seconds
    pub fn toEpoch(self: Timestamp) i64 {
        return @divTrunc(self.microseconds, 1_000_000) + PG_EPOCH_OFFSET;
    }

    /// Convert to Unix epoch milliseconds
    pub fn toEpochMillis(self: Timestamp) i64 {
        return @divTrunc(self.microseconds, 1_000) + (PG_EPOCH_OFFSET * 1_000);
    }

    /// Get microsecond component
    pub fn micros(self: Timestamp) u32 {
        return @intCast(@mod(self.microseconds, 1_000_000));
    }

    /// Format as ISO-8601 (simplified)
    pub fn format(self: Timestamp, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const epoch_secs = self.toEpoch();
        const epoch_days = @divFloor(epoch_secs, 86400);
        const day_secs = @mod(epoch_secs, 86400);

        // Simplified date calculation (approximate)
        const year = 1970 + @as(i64, @intCast(@divFloor(epoch_days, 365)));
        const month = @as(u32, 1);
        const day = @as(u32, 1) + @as(u32, @intCast(@mod(epoch_days, 365)));

        const hours = @as(u32, @intCast(@divFloor(day_secs, 3600)));
        const mins = @as(u32, @intCast(@mod(@divFloor(day_secs, 60), 60)));
        const secs = @as(u32, @intCast(@mod(day_secs, 60)));

        try std.fmt.format(writer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year, month, day, hours, mins, secs,
        });
    }
};

// ==================== Tests ====================

test "Timestamp fromEpoch toEpoch" {
    const unix_time: i64 = 1703721600; // 2023-12-28 00:00:00 UTC
    const ts = Timestamp.fromEpoch(unix_time);
    try std.testing.expectEqual(unix_time, ts.toEpoch());
}

test "Timestamp PG epoch offset" {
    try std.testing.expectEqual(@as(i64, 946684800), PG_EPOCH_OFFSET);
}
