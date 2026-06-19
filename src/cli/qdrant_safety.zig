const std = @import("std");

const MAX_PATH_SEGMENT_LEN: usize = 255;

fn isPathSegmentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.';
}

pub fn validatePathSegment(segment: []const u8) !void {
    if (segment.len == 0 or segment.len > MAX_PATH_SEGMENT_LEN) return error.InvalidQdrantPathSegment;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
        return error.InvalidQdrantPathSegment;
    }

    for (segment) |ch| {
        if (!isPathSegmentChar(ch)) return error.InvalidQdrantPathSegment;
    }
}

pub fn validatePointId(ref_id: []const u8) !void {
    if (std.mem.trim(u8, ref_id, " \t\r\n").len == 0) return error.InvalidQdrantPointId;
    for (ref_id) |ch| {
        if (ch == 0) return error.InvalidQdrantPointId;
    }
    if (std.fmt.parseInt(i64, ref_id, 10)) |num| {
        if (num < 0) return error.InvalidQdrantPointId;
    } else |_| {}
}

pub fn validateVector(vector: []const f32) !void {
    if (vector.len == 0) return error.InvalidQdrantVector;
    for (vector) |value| {
        if (!std.math.isFinite(value)) return error.InvalidQdrantVector;
    }
}

pub fn writePointId(writer: anytype, ref_id: []const u8) !void {
    try validatePointId(ref_id);
    if (std.fmt.parseInt(u64, ref_id, 10)) |num| {
        try writer.print("{d}", .{num});
        return;
    } else |_| {}
    try std.json.Stringify.value(ref_id, .{}, writer);
}

test "qdrant path segments reject url control syntax" {
    try validatePathSegment("products_search");
    try validatePathSegment("products.search-2026");

    const invalid = [_][]const u8{
        "",
        ".",
        "..",
        "products/search",
        "products?wait=false",
        "products#snapshots",
        "products%2fdelete",
        " products",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidQdrantPathSegment, validatePathSegment(value));
    }
}

test "qdrant point ids reject empty and negative numeric ids" {
    try validatePointId("42");
    try validatePointId("uuid-like-id");

    try std.testing.expectError(error.InvalidQdrantPointId, validatePointId(""));
    try std.testing.expectError(error.InvalidQdrantPointId, validatePointId(" \t"));
    try std.testing.expectError(error.InvalidQdrantPointId, validatePointId("-1"));
    try std.testing.expectError(error.InvalidQdrantPointId, validatePointId("bad\x00id"));
}

test "qdrant vectors must be non-empty and finite" {
    try validateVector(&[_]f32{ 0.1, -0.2 });
    try std.testing.expectError(error.InvalidQdrantVector, validateVector(&[_]f32{}));
    try std.testing.expectError(error.InvalidQdrantVector, validateVector(&[_]f32{std.math.inf(f32)}));
    try std.testing.expectError(error.InvalidQdrantVector, validateVector(&[_]f32{std.math.nan(f32)}));
}
