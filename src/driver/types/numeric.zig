//! Numeric/Decimal Type
//!
//! PostgreSQL NUMERIC type with arbitrary precision.

const std = @import("std");

/// Sign of numeric value
pub const Sign = enum {
    positive,
    negative,
    nan,
};

/// PostgreSQL NUMERIC value
pub const Numeric = struct {
    sign: Sign = .positive,
    weight: i16 = 0, // Position of first digit (power of 10000)
    dscale: u16 = 0, // Display scale (decimal places)
    digits: []const u16, // Base-10000 digits

    /// Convert to f64 (may lose precision)
    pub fn toFloat(self: Numeric) f64 {
        if (self.sign == .nan) return std.math.nan(f64);
        if (self.digits.len == 0) return 0.0;

        var result: f64 = 0.0;
        var power: i32 = @as(i32, self.weight) * 4;

        for (self.digits) |digit| {
            result += @as(f64, @floatFromInt(digit)) * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(power)));
            power -= 4;
        }

        return if (self.sign == .negative) -result else result;
    }

    /// Estimate string length needed
    pub fn estimatedStringLen(self: Numeric) usize {
        // weight * 4 + dscale + sign + decimal point + buffer
        const int_digits = if (self.weight >= 0) @as(usize, @intCast(self.weight + 1)) * 4 else 1;
        return int_digits + self.dscale + 3; // +3 for sign, '.', '\0'
    }

    /// Convert to string
    pub fn toString(self: Numeric, buf: []u8) []const u8 {
        if (self.sign == .nan) {
            if (buf.len >= 3) {
                @memcpy(buf[0..3], "NaN");
                return buf[0..3];
            }
            return "";
        }

        // Simple implementation: use float conversion
        const f = self.toFloat();
        const written = std.fmt.bufPrint(buf, "{d}", .{f}) catch return "";
        return written;
    }

    /// Create from float (approximate)
    pub fn fromFloat(f: f64) Numeric {
        if (std.math.isNan(f)) {
            return .{ .sign = .nan, .digits = &.{} };
        }

        const sign: Sign = if (f < 0) .negative else .positive;
        const abs = @abs(f);

        // Simple: treat as single digit (very approximate)
        const int_part: u16 = @intFromFloat(@min(abs, 65535.0));

        return .{
            .sign = sign,
            .weight = 0,
            .dscale = 0,
            .digits = &[_]u16{int_part},
        };
    }
};

// ==================== Tests ====================

test "Numeric toFloat" {
    const digits = [_]u16{ 1234, 5678 };
    const num = Numeric{
        .sign = .positive,
        .weight = 0,
        .dscale = 4,
        .digits = &digits,
    };
    const f = num.toFloat();
    try std.testing.expect(f > 1234.0);
}

test "Numeric NaN" {
    const num = Numeric{ .sign = .nan, .digits = &.{} };
    try std.testing.expect(std.math.isNan(num.toFloat()));
}
