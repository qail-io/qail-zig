// Numeric/Decimal Type
//
// PostgreSQL NUMERIC type with arbitrary precision.

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

    /// Decode PostgreSQL's binary NUMERIC wire format.
    ///
    /// The returned `digits` slice is owned by `allocator` and must be freed by
    /// the caller. PostgreSQL stores NUMERIC as a short header followed by
    /// base-10000 digits; malformed signs, truncated payloads, trailing bytes,
    /// and out-of-range digits are rejected.
    pub fn fromBinaryAlloc(allocator: std.mem.Allocator, bytes: []const u8) !Numeric {
        if (bytes.len < 8) return error.InvalidNumericData;

        const ndigits = std.mem.readInt(u16, bytes[0..2], .big);
        const weight = std.mem.readInt(i16, bytes[2..4], .big);
        const sign_raw = std.mem.readInt(u16, bytes[4..6], .big);
        const dscale = std.mem.readInt(u16, bytes[6..8], .big);
        const digits_bytes = std.math.mul(usize, @as(usize, ndigits), 2) catch return error.InvalidNumericData;
        const expected_len = std.math.add(usize, 8, digits_bytes) catch return error.InvalidNumericData;
        if (bytes.len != expected_len) return error.InvalidNumericData;

        const sign: Sign = switch (sign_raw) {
            0x0000 => .positive,
            0x4000 => .negative,
            0xC000 => .nan,
            else => return error.InvalidNumericData,
        };

        if (sign == .nan) {
            return .{
                .sign = .nan,
                .weight = weight,
                .dscale = dscale,
                .digits = try allocator.alloc(u16, 0),
            };
        }

        const digits = try allocator.alloc(u16, ndigits);
        errdefer allocator.free(digits);

        var pos: usize = 8;
        for (digits) |*digit| {
            const value = std.mem.readInt(u16, bytes[pos .. pos + 2], .big);
            if (value > 9999) return error.InvalidNumericData;
            digit.* = value;
            pos += 2;
        }

        return .{
            .sign = sign,
            .weight = weight,
            .dscale = dscale,
            .digits = digits,
        };
    }

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
        return Numeric.tryFromFloat(f) catch @panic("non-finite numeric value");
    }

    /// Fallible float constructor that rejects NaN and Infinity.
    pub fn tryFromFloat(f: f64) !Numeric {
        if (!std.math.isFinite(f)) return error.NonFiniteNumeric;
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

test "Numeric tryFromFloat rejects non-finite values" {
    try std.testing.expectError(error.NonFiniteNumeric, Numeric.tryFromFloat(std.math.nan(f64)));
    try std.testing.expectError(error.NonFiniteNumeric, Numeric.tryFromFloat(std.math.inf(f64)));
    try std.testing.expectError(error.NonFiniteNumeric, Numeric.tryFromFloat(-std.math.inf(f64)));
}

test "Numeric fromBinaryAlloc decodes negative weight safely" {
    const bytes = [_]u8{
        0x00, 0x01, // ndigits
        0xff, 0xfe, // weight = -2
        0x00, 0x00, // positive
        0x00, 0x08, // dscale
        0x00, 0x01, // digit
    };

    const num = try Numeric.fromBinaryAlloc(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(num.digits);

    try std.testing.expectEqual(Sign.positive, num.sign);
    try std.testing.expectEqual(@as(i16, -2), num.weight);
    try std.testing.expectEqual(@as(u16, 8), num.dscale);
    try std.testing.expectEqualSlices(u16, &.{1}, num.digits);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00000001), num.toFloat(), 0.0000000000001);
}

test "Numeric fromBinaryAlloc rejects malformed payloads" {
    try std.testing.expectError(error.InvalidNumericData, Numeric.fromBinaryAlloc(std.testing.allocator, &.{ 0x00, 0x01 }));

    const invalid_sign = [_]u8{
        0x00, 0x01, // ndigits
        0x00, 0x00, // weight
        0x20, 0x00, // invalid sign
        0x00, 0x00, // dscale
        0x00, 0x01, // digit
    };
    try std.testing.expectError(error.InvalidNumericData, Numeric.fromBinaryAlloc(std.testing.allocator, &invalid_sign));

    const invalid_digit = [_]u8{
        0x00, 0x01, // ndigits
        0x00, 0x00, // weight
        0x00, 0x00, // positive
        0x00, 0x00, // dscale
        0x27, 0x10, // digit = 10000
    };
    try std.testing.expectError(error.InvalidNumericData, Numeric.fromBinaryAlloc(std.testing.allocator, &invalid_digit));

    const trailing = [_]u8{
        0x00, 0x00, // ndigits
        0x00, 0x00, // weight
        0x00, 0x00, // positive
        0x00, 0x00, // dscale
        0x00, // trailing byte
    };
    try std.testing.expectError(error.InvalidNumericData, Numeric.fromBinaryAlloc(std.testing.allocator, &trailing));
}

test "Numeric fromBinaryAlloc decodes NaN" {
    const bytes = [_]u8{
        0x00, 0x00, // ndigits
        0x00, 0x00, // weight
        0xc0, 0x00, // NaN
        0x00, 0x00, // dscale
    };

    const num = try Numeric.fromBinaryAlloc(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(num.digits);

    try std.testing.expectEqual(Sign.nan, num.sign);
    try std.testing.expect(std.math.isNan(num.toFloat()));
}
