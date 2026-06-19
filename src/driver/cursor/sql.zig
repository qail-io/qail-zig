const std = @import("std");

pub fn buildDeclare(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
    query_sql: []const u8,
) ![]u8 {
    const quoted_cursor = try quoteIdentifierAlloc(allocator, cursor_name);
    defer allocator.free(quoted_cursor);
    return std.fmt.allocPrint(allocator, "DECLARE {s} CURSOR FOR {s}", .{ quoted_cursor, query_sql });
}

pub fn buildFetch(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
    batch_size: usize,
) ![]u8 {
    if (batch_size == 0) return error.InvalidCursorBatchSize;
    const quoted_cursor = try quoteIdentifierAlloc(allocator, cursor_name);
    defer allocator.free(quoted_cursor);
    return std.fmt.allocPrint(allocator, "FETCH {d} FROM {s}", .{ batch_size, quoted_cursor });
}

pub fn buildClose(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
) ![]u8 {
    const quoted_cursor = try quoteIdentifierAlloc(allocator, cursor_name);
    defer allocator.free(quoted_cursor);
    return std.fmt.allocPrint(allocator, "CLOSE {s}", .{quoted_cursor});
}

fn quoteIdentifierAlloc(allocator: std.mem.Allocator, ident: []const u8) ![]u8 {
    if (ident.len == 0) return error.InvalidCursorName;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    for (ident) |ch| {
        if (ch == 0) return error.InvalidCursorName;
        if (ch == '"') {
            try out.appendSlice(allocator, "\"\"");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

test "cursor sql builders" {
    const declare = try buildDeclare(std.testing.allocator, "c1", "SELECT * FROM users");
    defer std.testing.allocator.free(declare);
    try std.testing.expectEqualStrings("DECLARE \"c1\" CURSOR FOR SELECT * FROM users", declare);

    const fetch = try buildFetch(std.testing.allocator, "c1", 50);
    defer std.testing.allocator.free(fetch);
    try std.testing.expectEqualStrings("FETCH 50 FROM \"c1\"", fetch);

    const close = try buildClose(std.testing.allocator, "c1");
    defer std.testing.allocator.free(close);
    try std.testing.expectEqualStrings("CLOSE \"c1\"", close);
}

test "cursor sql builders quote unsafe cursor names" {
    const fetch = try buildFetch(std.testing.allocator, "c\"; DROP TABLE users; --", 50);
    defer std.testing.allocator.free(fetch);
    try std.testing.expectEqualStrings("FETCH 50 FROM \"c\"\"; DROP TABLE users; --\"", fetch);

    try std.testing.expectError(error.InvalidCursorName, buildClose(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidCursorName, buildClose(std.testing.allocator, "bad\x00name"));
}

test "cursor sql builders reject zero batch size" {
    try std.testing.expectError(error.InvalidCursorBatchSize, buildFetch(std.testing.allocator, "c1", 0));
}
