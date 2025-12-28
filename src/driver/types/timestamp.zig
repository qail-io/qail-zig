//! Temporal Types for PostgreSQL
//!
//! PostgreSQL date/time type conversions.
//! Port of qail.rs/qail-pg/src/types/temporal.rs
//!
//! PostgreSQL stores:
//! - TIMESTAMP: microseconds since 2000-01-01 00:00:00 UTC
//! - DATE: days since 2000-01-01
//! - TIME: microseconds since midnight

const std = @import("std");

/// PostgreSQL epoch (2000-01-01 00:00:00 UTC)
/// Difference from Unix epoch (1970-01-01) in seconds
pub const PG_EPOCH_OFFSET_SEC: i64 = 946_684_800;

/// PostgreSQL epoch offset in microseconds
pub const PG_EPOCH_OFFSET_USEC: i64 = PG_EPOCH_OFFSET_SEC * 1_000_000;

/// Days in each month (non-leap year)
const DAYS_IN_MONTH = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

// ==================== Timestamp ====================

/// Timestamp without timezone (microseconds since 2000-01-01)
pub const Timestamp = struct {
    /// Microseconds since PostgreSQL epoch (2000-01-01)
    usec: i64,

    /// Create from microseconds since PG epoch
    pub fn fromPgUsec(usec: i64) Timestamp {
        return .{ .usec = usec };
    }

    /// Create from Unix epoch seconds
    pub fn fromUnixSecs(unix_secs: i64) Timestamp {
        return .{ .usec = unix_secs * 1_000_000 - PG_EPOCH_OFFSET_USEC };
    }

    /// Create from Unix epoch milliseconds
    pub fn fromUnixMillis(unix_ms: i64) Timestamp {
        return .{ .usec = unix_ms * 1_000 - PG_EPOCH_OFFSET_USEC };
    }

    /// Convert to Unix epoch seconds
    pub fn toUnixSecs(self: Timestamp) i64 {
        return @divTrunc(self.usec + PG_EPOCH_OFFSET_USEC, 1_000_000);
    }

    /// Convert to Unix epoch milliseconds
    pub fn toUnixMillis(self: Timestamp) i64 {
        return @divTrunc(self.usec + PG_EPOCH_OFFSET_USEC, 1_000);
    }

    /// Convert to Unix epoch microseconds
    pub fn toUnixUsec(self: Timestamp) i64 {
        return self.usec + PG_EPOCH_OFFSET_USEC;
    }

    /// Parse from binary (8 bytes, big endian)
    pub fn fromBinary(bytes: []const u8) ?Timestamp {
        if (bytes.len != 8) return null;
        const usec = std.mem.readInt(i64, bytes[0..8], .big);
        return Timestamp.fromPgUsec(usec);
    }

    /// Encode to binary (8 bytes, big endian)
    pub fn toBinary(self: Timestamp, buf: *[8]u8) void {
        std.mem.writeInt(i64, buf, self.usec, .big);
    }
};

// ==================== Date ====================

/// Date type (days since 2000-01-01)
pub const Date = struct {
    /// Days since PostgreSQL epoch (2000-01-01)
    days: i32,

    /// Create from days since PG epoch
    pub fn fromPgDays(days: i32) Date {
        return .{ .days = days };
    }

    /// Create from year, month, day
    pub fn fromYmd(year: i32, month: u8, day: u8) Date {
        return .{ .days = daysFromYmd(year, month, day) };
    }

    /// Parse from binary (4 bytes, big endian)
    pub fn fromBinary(bytes: []const u8) ?Date {
        if (bytes.len != 4) return null;
        const days = std.mem.readInt(i32, bytes[0..4], .big);
        return Date.fromPgDays(days);
    }

    /// Encode to binary (4 bytes, big endian)
    pub fn toBinary(self: Date, buf: *[4]u8) void {
        std.mem.writeInt(i32, buf, self.days, .big);
    }

    /// Convert to (year, month, day)
    pub fn toYmd(self: Date) struct { year: i32, month: u8, day: u8 } {
        var days = self.days;
        var year: i32 = 2000;

        // Years
        while (days >= daysInYear(year)) {
            days -= daysInYear(year);
            year += 1;
        }
        while (days < 0) {
            year -= 1;
            days += daysInYear(year);
        }

        // Months
        var month: u8 = 1;
        while (month <= 12) {
            const dim = daysInMonth(year, month);
            if (days < dim) break;
            days -= dim;
            month += 1;
        }

        return .{
            .year = year,
            .month = month,
            .day = @intCast(days + 1),
        };
    }
};

// ==================== Time ====================

/// Time type (microseconds since midnight)
pub const Time = struct {
    /// Microseconds since midnight
    usec: i64,

    /// Create from hours, minutes, seconds, microseconds
    pub fn new(h: u8, m: u8, s: u8, us: u32) Time {
        return .{
            .usec = @as(i64, h) * 3_600_000_000 +
                @as(i64, m) * 60_000_000 +
                @as(i64, s) * 1_000_000 +
                @as(i64, us),
        };
    }

    /// Create from microseconds since midnight
    pub fn fromUsec(usec: i64) Time {
        return .{ .usec = usec };
    }

    /// Get hours component (0-23)
    pub fn hour(self: Time) u8 {
        return @intCast(@divTrunc(@mod(self.usec, 86_400_000_000), 3_600_000_000));
    }

    /// Get minutes component (0-59)
    pub fn minute(self: Time) u8 {
        return @intCast(@divTrunc(@mod(self.usec, 3_600_000_000), 60_000_000));
    }

    /// Get seconds component (0-59)
    pub fn second(self: Time) u8 {
        return @intCast(@divTrunc(@mod(self.usec, 60_000_000), 1_000_000));
    }

    /// Get microseconds component (0-999999)
    pub fn microsecond(self: Time) u32 {
        return @intCast(@mod(self.usec, 1_000_000));
    }

    /// Parse from binary (8 bytes, big endian)
    pub fn fromBinary(bytes: []const u8) ?Time {
        if (bytes.len != 8) return null;
        const usec = std.mem.readInt(i64, bytes[0..8], .big);
        return Time.fromUsec(usec);
    }

    /// Encode to binary (8 bytes, big endian)
    pub fn toBinary(self: Time, buf: *[8]u8) void {
        std.mem.writeInt(i64, buf, self.usec, .big);
    }
};

// ==================== Interval ====================

/// Interval type (months + days + microseconds)
pub const Interval = struct {
    months: i32,
    days: i32,
    usec: i64,

    /// Create a new interval
    pub fn new(months: i32, days: i32, usec: i64) Interval {
        return .{ .months = months, .days = days, .usec = usec };
    }

    /// Create from seconds
    pub fn fromSeconds(secs: i64) Interval {
        return .{ .months = 0, .days = 0, .usec = secs * 1_000_000 };
    }

    /// Create from days
    pub fn fromDays(days: i32) Interval {
        return .{ .months = 0, .days = days, .usec = 0 };
    }

    /// Parse from binary (16 bytes: 8 usec + 4 days + 4 months)
    pub fn fromBinary(bytes: []const u8) ?Interval {
        if (bytes.len != 16) return null;
        return .{
            .usec = std.mem.readInt(i64, bytes[0..8], .big),
            .days = std.mem.readInt(i32, bytes[8..12], .big),
            .months = std.mem.readInt(i32, bytes[12..16], .big),
        };
    }
};

// ==================== Helpers ====================

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn daysInYear(year: i32) i32 {
    return if (isLeapYear(year)) 366 else 365;
}

fn daysInMonth(year: i32, month: u8) i32 {
    if (month == 2 and isLeapYear(year)) return 29;
    return DAYS_IN_MONTH[month - 1];
}

fn daysFromYmd(year: i32, month: u8, day: u8) i32 {
    var days: i32 = 0;

    // Years from 2000
    var y: i32 = 2000;
    while (y < year) : (y += 1) {
        days += daysInYear(y);
    }
    while (y > year) {
        y -= 1;
        days -= daysInYear(y);
    }

    // Months
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += daysInMonth(year, m);
    }

    // Days
    days += day - 1;

    return days;
}

// ==================== Tests ====================

test "Timestamp Unix conversion" {
    const unix_secs: i64 = 1704067200; // 2024-01-01 00:00:00 UTC
    const ts = Timestamp.fromUnixSecs(unix_secs);
    try std.testing.expectEqual(unix_secs, ts.toUnixSecs());
}

test "Timestamp binary roundtrip" {
    const ts = Timestamp.fromPgUsec(789_012_345_678_900);
    var buf: [8]u8 = undefined;
    ts.toBinary(&buf);
    const parsed = Timestamp.fromBinary(&buf).?;
    try std.testing.expectEqual(ts.usec, parsed.usec);
}

test "Date fromYmd toYmd" {
    const date = Date.fromYmd(2024, 12, 25);
    const ymd = date.toYmd();
    try std.testing.expectEqual(@as(i32, 2024), ymd.year);
    try std.testing.expectEqual(@as(u8, 12), ymd.month);
    try std.testing.expectEqual(@as(u8, 25), ymd.day);
}

test "Time components" {
    const time = Time.new(12, 30, 45, 123456);
    try std.testing.expectEqual(@as(u8, 12), time.hour());
    try std.testing.expectEqual(@as(u8, 30), time.minute());
    try std.testing.expectEqual(@as(u8, 45), time.second());
    try std.testing.expectEqual(@as(u32, 123456), time.microsecond());
}

test "Interval binary parsing" {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i64, buf[0..8], 3_600_000_000, .big); // 1 hour
    std.mem.writeInt(i32, buf[8..12], 7, .big); // 7 days
    std.mem.writeInt(i32, buf[12..16], 1, .big); // 1 month

    const interval = Interval.fromBinary(&buf).?;
    try std.testing.expectEqual(@as(i32, 1), interval.months);
    try std.testing.expectEqual(@as(i32, 7), interval.days);
    try std.testing.expectEqual(@as(i64, 3_600_000_000), interval.usec);
}
