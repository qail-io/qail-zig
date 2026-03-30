const std = @import("std");

pub fn buildDeclare(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
    query_sql: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "DECLARE {s} CURSOR FOR {s}", .{ cursor_name, query_sql });
}

pub fn buildFetch(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
    batch_size: usize,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "FETCH {d} FROM {s}", .{ batch_size, cursor_name });
}

pub fn buildClose(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "CLOSE {s}", .{cursor_name});
}

test "cursor sql builders" {
    const declare = try buildDeclare(std.testing.allocator, "c1", "SELECT * FROM users");
    defer std.testing.allocator.free(declare);
    try std.testing.expectEqualStrings("DECLARE c1 CURSOR FOR SELECT * FROM users", declare);

    const fetch = try buildFetch(std.testing.allocator, "c1", 50);
    defer std.testing.allocator.free(fetch);
    try std.testing.expectEqualStrings("FETCH 50 FROM c1", fetch);

    const close = try buildClose(std.testing.allocator, "c1");
    defer std.testing.allocator.free(close);
    try std.testing.expectEqualStrings("CLOSE c1", close);
}
