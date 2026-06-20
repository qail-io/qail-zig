const std = @import("std");

const MAX_IDENT_LEN: usize = 63;

pub fn buildDeclare(
    allocator: std.mem.Allocator,
    cursor_name: []const u8,
    query_sql: []const u8,
) ![]u8 {
    try validateTrustedCursorQuerySql(query_sql);
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
    try validateCursorName(ident);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    try out.appendSlice(allocator, ident);
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

fn validateCursorName(name: []const u8) !void {
    if (name.len == 0 or name.len > MAX_IDENT_LEN) return error.InvalidCursorName;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return error.InvalidCursorName;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidCursorName;
    }
}

fn validateTrustedCursorQuerySql(sql: []const u8) !void {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidCursorQuery;
    if (!startsWithKeyword(trimmed, "select") and !startsWithKeyword(trimmed, "with")) {
        return error.InvalidCursorQuery;
    }
    if (containsUnsafeSqlControl(trimmed)) return error.UnsafeSqlFragment;
}

fn startsWithKeyword(value: []const u8, keyword: []const u8) bool {
    if (value.len < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(value[0..keyword.len], keyword)) return false;
    if (value.len == keyword.len) return true;
    const next = value[keyword.len];
    return !std.ascii.isAlphanumeric(next) and next != '_';
}

fn containsUnsafeSqlControl(value: []const u8) bool {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;

    while (i < value.len) {
        const b = value[i];
        if (b == 0) return true;

        if (in_single) {
            if (b == '\'') {
                if (i + 1 < value.len and value[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                in_single = false;
            }
            i += 1;
            continue;
        }

        if (in_double) {
            if (b == '"') {
                if (i + 1 < value.len and value[i + 1] == '"') {
                    i += 2;
                    continue;
                }
                in_double = false;
            }
            i += 1;
            continue;
        }

        switch (b) {
            '\'' => in_single = true,
            '"' => in_double = true,
            ';' => return true,
            '-' => if (i + 1 < value.len and value[i + 1] == '-') return true,
            '/' => if (i + 1 < value.len and value[i + 1] == '*') return true,
            '*' => if (i + 1 < value.len and value[i + 1] == '/') return true,
            else => {},
        }
        i += 1;
    }

    return in_single or in_double;
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

test "cursor sql builders reject invalid cursor names" {
    try std.testing.expectError(error.InvalidCursorName, buildClose(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidCursorName, buildFetch(std.testing.allocator, "1cursor", 50));
    try std.testing.expectError(error.InvalidCursorName, buildFetch(std.testing.allocator, "bad.name", 50));
    try std.testing.expectError(error.InvalidCursorName, buildFetch(std.testing.allocator, "bad\"name", 50));
    try std.testing.expectError(error.InvalidCursorName, buildFetch(std.testing.allocator, "bad;name", 50));
    try std.testing.expectError(error.InvalidCursorName, buildClose(std.testing.allocator, "bad\x00name"));
}

test "cursor sql builders reject zero batch size" {
    try std.testing.expectError(error.InvalidCursorBatchSize, buildFetch(std.testing.allocator, "c1", 0));
}

test "cursor declare rejects unsafe query sql fragments" {
    try std.testing.expectError(error.InvalidCursorQuery, buildDeclare(std.testing.allocator, "c1", ""));
    try std.testing.expectError(error.InvalidCursorQuery, buildDeclare(std.testing.allocator, "c1", "DELETE FROM users"));
    try std.testing.expectError(error.UnsafeSqlFragment, buildDeclare(std.testing.allocator, "c1", "SELECT 1; DROP TABLE users"));
    try std.testing.expectError(error.UnsafeSqlFragment, buildDeclare(std.testing.allocator, "c1", "SELECT 1 -- trailing"));
    try std.testing.expectError(error.UnsafeSqlFragment, buildDeclare(std.testing.allocator, "c1", "SELECT 'unterminated"));
    try std.testing.expectError(error.UnsafeSqlFragment, buildDeclare(std.testing.allocator, "c1", "SELECT 1\x00"));

    const quoted = try buildDeclare(std.testing.allocator, "c1", "SELECT ';' AS semi");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("DECLARE \"c1\" CURSOR FOR SELECT ';' AS semi", quoted);
}
