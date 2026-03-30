const std = @import("std");

pub fn encodeCopyRow(allocator: std.mem.Allocator, row: []const ?[]const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(allocator);

    for (row) |col| {
        if (col) |value| {
            try parts.append(allocator, value);
        } else {
            try parts.append(allocator, "\\N");
        }
    }

    const joined = try std.mem.join(allocator, "\t", parts.items);
    defer allocator.free(joined);

    return try std.fmt.allocPrint(allocator, "{s}\n", .{joined});
}

pub fn sendCopyData(conn: anytype, data: []const u8) !void {
    if (data.len > std.math.maxInt(u32) - 4) return error.CopyDataTooLarge;
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
    var out: std.ArrayListUnmanaged(u8) = .{};
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

    var out: std.ArrayListUnmanaged(u8) = .{};
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
