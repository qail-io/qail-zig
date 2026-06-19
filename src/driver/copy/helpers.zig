const std = @import("std");

pub fn encodeCopyRow(allocator: std.mem.Allocator, row: []const ?[]const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (row, 0..) |col, i| {
        if (i > 0) try out.append(allocator, '\t');
        if (col) |value| {
            try appendCopyTextField(&out, allocator, value);
        } else {
            try out.appendSlice(allocator, "\\N");
        }
    }
    try out.append(allocator, '\n');

    return try out.toOwnedSlice(allocator);
}

fn appendCopyTextField(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            0 => return error.InvalidCopyData,
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, byte),
        }
    }
}

pub fn sendCopyData(conn: anytype, data: []const u8) !void {
    if (data.len > std.math.maxInt(i32) - 4) return error.CopyDataTooLarge;
    const len: u32 = @intCast(data.len + 4);
    var header: [5]u8 = undefined;
    header[0] = 'd';
    std.mem.writeInt(u32, header[1..5], len, .big);

    try conn.send(&header);
    try conn.send(data);
}

pub fn sendCopyDone(conn: anytype) !void {
    const msg = [_]u8{ 'c', 0, 0, 0, 4 };
    try conn.send(&msg);
}

pub fn quoteIdentifierListAlloc(allocator: std.mem.Allocator, columns: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (columns, 0..) |column, i| {
        const quoted = try quoteQualifiedIdentifierAlloc(allocator, column);
        defer allocator.free(quoted);

        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, quoted);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn quoteQualifiedIdentifierAlloc(allocator: std.mem.Allocator, ident: []const u8) ![]u8 {
    if (ident.len == 0) return error.InvalidIdentifier;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, ident, '.');
    var wrote_part = false;
    while (parts.next()) |part| {
        try validateIdentifierPart(part);

        if (wrote_part) try out.append(allocator, '.');
        try out.append(allocator, '"');
        try out.appendSlice(allocator, part);
        try out.append(allocator, '"');
        wrote_part = true;
    }

    if (!wrote_part) return error.InvalidIdentifier;
    return try out.toOwnedSlice(allocator);
}

fn validateIdentifierPart(part: []const u8) !void {
    if (part.len == 0 or part.len > 63) return error.InvalidIdentifier;

    const first = part[0];
    if (!(first == '_' or std.ascii.isAlphabetic(first))) return error.InvalidIdentifier;

    for (part[1..]) |ch| {
        if (!(ch == '_' or std.ascii.isAlphanumeric(ch))) return error.InvalidIdentifier;
    }
}

test "quoteQualifiedIdentifierAlloc quotes qualified identifiers" {
    const quoted = try quoteQualifiedIdentifierAlloc(std.testing.allocator, "tenant.users");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("\"tenant\".\"users\"", quoted);
}

test "quoteQualifiedIdentifierAlloc rejects invalid identifier" {
    try std.testing.expectError(error.InvalidIdentifier, quoteQualifiedIdentifierAlloc(std.testing.allocator, "users;drop"));
}

test "encodeCopyRow escapes copy text structural bytes" {
    const row = [_]?[]const u8{
        "hello\tworld",
        "line\nnext",
        "carriage\rreturn",
        "back\\slash",
        null,
    };
    const encoded = try encodeCopyRow(std.testing.allocator, &row);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("hello\\tworld\tline\\nnext\tcarriage\\rreturn\tback\\\\slash\t\\N\n", encoded);
}

test "encodeCopyRow rejects nul bytes" {
    const row = [_]?[]const u8{"bad\x00value"};
    try std.testing.expectError(error.InvalidCopyData, encodeCopyRow(std.testing.allocator, &row));
}

test "sendCopyData rejects payload above i32 wire limit" {
    const MockConn = struct {
        send_count: usize = 0,

        pub fn send(self: *@This(), bytes: []const u8) !void {
            _ = bytes;
            self.send_count += 1;
        }
    };

    var conn = MockConn{};
    const too_large_len = @as(usize, std.math.maxInt(i32)) - 3;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.CopyDataTooLarge, sendCopyData(&conn, payload));
    try std.testing.expectEqual(@as(usize, 0), conn.send_count);
}
