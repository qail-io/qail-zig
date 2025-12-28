// JSON/JSONB Helpers
//
// PostgreSQL JSON and JSONB parsing utilities.

const std = @import("std");

/// Parse JSONB wire format to JSON value
/// JSONB starts with a version byte (currently 1)
pub fn parseJsonb(data: []const u8, allocator: std.mem.Allocator) !std.json.Value {
    if (data.len == 0) return .null;

    // JSONB format: version (1 byte) + JSON text
    const json_data = if (data[0] == 1) data[1..] else data;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    return parsed.value;
}

/// Parse plain JSON text
pub fn parseJson(data: []const u8, allocator: std.mem.Allocator) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    return parsed.value;
}

/// Stringify JSON value
pub fn stringify(value: std.json.Value, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    try std.json.stringify(value, .{}, stream.writer());
    return stream.getWritten();
}

// ==================== Tests ====================

test "parseJson" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const value = try parseJson("{\"key\": 123}", arena.allocator());
    try std.testing.expect(value == .object);
}

test "parseJsonb with version byte" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Version 1 + JSON
    const data = "\x01{\"a\":1}";
    const value = try parseJsonb(data, arena.allocator());
    try std.testing.expect(value == .object);
}
