//! PostgreSQL OID Types
//!
//! Maps PostgreSQL OIDs to Zig types.

const std = @import("std");

/// Common PostgreSQL type OIDs
pub const Oid = struct {
    // Boolean
    pub const bool_oid: u32 = 16;

    // Numeric
    pub const int2_oid: u32 = 21;
    pub const int4_oid: u32 = 23;
    pub const int8_oid: u32 = 20;
    pub const float4_oid: u32 = 700;
    pub const float8_oid: u32 = 701;
    pub const numeric_oid: u32 = 1700;

    // String
    pub const text_oid: u32 = 25;
    pub const varchar_oid: u32 = 1043;
    pub const char_oid: u32 = 18;
    pub const bpchar_oid: u32 = 1042;
    pub const name_oid: u32 = 19;

    // Binary
    pub const bytea_oid: u32 = 17;

    // Date/Time
    pub const date_oid: u32 = 1082;
    pub const time_oid: u32 = 1083;
    pub const timestamp_oid: u32 = 1114;
    pub const timestamptz_oid: u32 = 1184;
    pub const interval_oid: u32 = 1186;

    // JSON
    pub const json_oid: u32 = 114;
    pub const jsonb_oid: u32 = 3802;

    // UUID
    pub const uuid_oid: u32 = 2950;

    // Arrays (base + 1-dimensional offset)
    pub const int4_array_oid: u32 = 1007;
    pub const int8_array_oid: u32 = 1016;
    pub const text_array_oid: u32 = 1009;
    pub const float8_array_oid: u32 = 1022;

    // Special
    pub const void_oid: u32 = 2278;
    pub const unknown_oid: u32 = 705;
};

/// Get type name from OID
pub fn oidToName(oid: u32) []const u8 {
    return switch (oid) {
        Oid.bool_oid => "bool",
        Oid.int2_oid => "int2",
        Oid.int4_oid => "int4",
        Oid.int8_oid => "int8",
        Oid.float4_oid => "float4",
        Oid.float8_oid => "float8",
        Oid.numeric_oid => "numeric",
        Oid.text_oid => "text",
        Oid.varchar_oid => "varchar",
        Oid.char_oid => "char",
        Oid.bpchar_oid => "bpchar",
        Oid.name_oid => "name",
        Oid.bytea_oid => "bytea",
        Oid.date_oid => "date",
        Oid.time_oid => "time",
        Oid.timestamp_oid => "timestamp",
        Oid.timestamptz_oid => "timestamptz",
        Oid.interval_oid => "interval",
        Oid.json_oid => "json",
        Oid.jsonb_oid => "jsonb",
        Oid.uuid_oid => "uuid",
        Oid.int4_array_oid => "int4[]",
        Oid.int8_array_oid => "int8[]",
        Oid.text_array_oid => "text[]",
        Oid.float8_array_oid => "float8[]",
        else => "unknown",
    };
}

/// Check if OID represents an array type
pub fn isArrayOid(oid: u32) bool {
    return switch (oid) {
        Oid.int4_array_oid,
        Oid.int8_array_oid,
        Oid.text_array_oid,
        Oid.float8_array_oid,
        => true,
        else => false,
    };
}

/// Parse text representation to i32
pub fn textToInt32(text: []const u8) !i32 {
    return std.fmt.parseInt(i32, text, 10);
}

/// Parse text representation to i64
pub fn textToInt64(text: []const u8) !i64 {
    return std.fmt.parseInt(i64, text, 10);
}

/// Parse text representation to f64
pub fn textToFloat64(text: []const u8) !f64 {
    return std.fmt.parseFloat(f64, text);
}

/// Parse text representation to bool
pub fn textToBool(text: []const u8) bool {
    return text.len > 0 and (text[0] == 't' or text[0] == 'T' or text[0] == '1');
}

// Tests
test "oid to name" {
    try std.testing.expectEqualStrings("int4", oidToName(Oid.int4_oid));
    try std.testing.expectEqualStrings("text", oidToName(Oid.text_oid));
    try std.testing.expectEqualStrings("jsonb", oidToName(Oid.jsonb_oid));
}

test "is array oid" {
    try std.testing.expect(isArrayOid(Oid.int4_array_oid));
    try std.testing.expect(!isArrayOid(Oid.int4_oid));
}

test "text to int32" {
    try std.testing.expectEqual(@as(i32, 42), try textToInt32("42"));
    try std.testing.expectEqual(@as(i32, -100), try textToInt32("-100"));
}

test "text to bool" {
    try std.testing.expect(textToBool("t"));
    try std.testing.expect(textToBool("true"));
    try std.testing.expect(!textToBool("f"));
    try std.testing.expect(!textToBool("false"));
}
