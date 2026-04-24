//! Protocol fail-closed tests (wire encoder).
//!
//! Focused on fail-closed behavior and byte-level correctness.

const std = @import("std");
const Encoder = @import("../protocol/encoder.zig").Encoder;

test "wire: query message type and length" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeQuery("SELECT 1");
    const bytes = encoder.getWritten();

    try std.testing.expectEqual(@as(u8, 'Q'), bytes[0]);
    const declared_len = std.mem.readInt(u32, bytes[1..5], .big);
    try std.testing.expectEqual(@as(u32, 4 + "SELECT 1".len + 1), declared_len);
    try std.testing.expectEqual(@as(usize, 1 + declared_len), bytes.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
}

test "wire: empty query has correct length and null terminator" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    try encoder.encodeQuery("");
    const bytes = encoder.getWritten();

    const declared_len = std.mem.readInt(u32, bytes[1..5], .big);
    try std.testing.expectEqual(@as(u32, 5), declared_len);
    try std.testing.expectEqual(@as(usize, 6), bytes.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
}

test "wire: bind rejects too many params" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const max_params = @as(usize, @intCast(std.math.maxInt(i16))) + 1;
    const params = try std.testing.allocator.alloc(?[]const u8, max_params);
    defer std.testing.allocator.free(params);
    for (params) |*p| p.* = null;

    const result = encoder.encodeBind("", "", params);
    try std.testing.expectError(error.TooManyParameters, result);
}

test "wire: parse rejects too many param types" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const max_params = @as(usize, @intCast(std.math.maxInt(i16))) + 1;
    const types = try std.testing.allocator.alloc(u32, max_params);
    defer std.testing.allocator.free(types);
    for (types) |*t| t.* = 0;

    const result = encoder.encodeParse("", "SELECT 1", types);
    try std.testing.expectError(error.TooManyParameters, result);
}

test "wire: bind encodes null param length as -1" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const params = [_]?[]const u8{null};
    try encoder.encodeBind("", "", &params);
    const bytes = encoder.getWritten();

    // Payload starts at byte 5. Portal cstring + stmt cstring + format count (2) + param count (2).
    const payload = bytes[5..];
    const param_data_start = 1 + 1 + 2 + 2;
    const marker = std.mem.readInt(i32, payload[param_data_start..][0..4], .big);
    try std.testing.expectEqual(@as(i32, -1), marker);
}

test "wire: parse rejects embedded nul in statement name cstring" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const result = encoder.encodeParse("stmt\x00name", "SELECT 1", &.{});
    try std.testing.expectError(error.NullByte, result);
}

test "wire: bind rejects embedded nul in portal cstring" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const result = encoder.encodeBind("po\x00rtal", "stmt", &.{});
    try std.testing.expectError(error.NullByte, result);
}

test "wire: bind rejects embedded nul in statement cstring" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const result = encoder.encodeBind("portal", "st\x00mt", &.{});
    try std.testing.expectError(error.NullByte, result);
}

test "wire: describe portal rejects embedded nul in portal cstring" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const result = encoder.encodeDescribePortal("po\x00rtal");
    try std.testing.expectError(error.NullByte, result);
}

test "wire: execute rejects embedded nul in portal cstring" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();

    const result = encoder.encodeExecute("po\x00rtal", 0);
    try std.testing.expectError(error.NullByte, result);
}
