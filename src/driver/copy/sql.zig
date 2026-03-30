const std = @import("std");
const helpers = @import("helpers.zig");

pub fn buildCopyInSql(
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
) ![]u8 {
    const quoted_table = try helpers.quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);

    const quoted_cols = try helpers.quoteIdentifierListAlloc(allocator, columns);
    defer allocator.free(quoted_cols);

    return std.fmt.allocPrint(allocator, "COPY {s} ({s}) FROM STDIN", .{ quoted_table, quoted_cols });
}

pub fn buildCopyOutSql(
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const []const u8,
) ![]u8 {
    const quoted_table = try helpers.quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);

    const quoted_cols = try helpers.quoteIdentifierListAlloc(allocator, columns);
    defer allocator.free(quoted_cols);

    return std.fmt.allocPrint(allocator, "COPY (SELECT {s} FROM {s}) TO STDOUT", .{ quoted_cols, quoted_table });
}

test "build copy in sql quotes identifiers" {
    const sql = try buildCopyInSql(std.testing.allocator, "tenant.users", &.{ "id", "name" });
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("COPY \"tenant\".\"users\" (\"id\", \"name\") FROM STDIN", sql);
}

test "build copy out sql quotes identifiers" {
    const sql = try buildCopyOutSql(std.testing.allocator, "tenant.users", &.{ "id", "name" });
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("COPY (SELECT \"id\", \"name\" FROM \"tenant\".\"users\") TO STDOUT", sql);
}
