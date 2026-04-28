const std = @import("std");

/// Small raw-SQL helper surface used by `driver.zig`.
///
/// The goal is to keep raw SQL string construction in one module so it can be
/// audited and removed incrementally as AST-native replacements land.
pub const AlterTableRlsMode = enum {
    enable,
    disable,
    force,
    no_force,
};

pub fn begin() []const u8 {
    return "BEGIN";
}

pub fn commit() []const u8 {
    return "COMMIT";
}

pub fn rollback() []const u8 {
    return "ROLLBACK";
}

pub fn healthCheck() []const u8 {
    return "SELECT 1";
}

pub fn identifySystem() []const u8 {
    return "IDENTIFY_SYSTEM";
}

pub fn unlistenAll() []const u8 {
    return "UNLISTEN *";
}

pub fn buildExplainFormatJson(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "EXPLAIN (FORMAT JSON) {s}", .{sql});
}

pub fn buildListen(allocator: std.mem.Allocator, channel: []const u8) ![]u8 {
    const quoted_channel = try quoteIdentifierAlloc(allocator, channel);
    defer allocator.free(quoted_channel);
    return std.fmt.allocPrint(allocator, "LISTEN {s}", .{quoted_channel});
}

pub fn buildUnlisten(allocator: std.mem.Allocator, channel: []const u8) ![]u8 {
    const quoted_channel = try quoteIdentifierAlloc(allocator, channel);
    defer allocator.free(quoted_channel);
    return std.fmt.allocPrint(allocator, "UNLISTEN {s}", .{quoted_channel});
}

pub fn buildAlterTableRls(
    allocator: std.mem.Allocator,
    table: []const u8,
    mode: AlterTableRlsMode,
) ![]u8 {
    const quoted_table = try quoteIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);
    return std.fmt.allocPrint(allocator, "ALTER TABLE {s} {s}", .{ quoted_table, rlsClause(mode) });
}

pub fn buildDeallocatePrepared(allocator: std.mem.Allocator, stmt_name: []const u8) ![]u8 {
    if (stmt_name.len == 0) return error.InvalidStatementName;
    for (stmt_name) |ch| {
        if (!isIdentifierChar(ch)) return error.InvalidStatementName;
    }
    return std.fmt.allocPrint(allocator, "DEALLOCATE {s}", .{stmt_name});
}

fn rlsClause(mode: AlterTableRlsMode) []const u8 {
    return switch (mode) {
        .enable => "ENABLE ROW LEVEL SECURITY",
        .disable => "DISABLE ROW LEVEL SECURITY",
        .force => "FORCE ROW LEVEL SECURITY",
        .no_force => "NO FORCE ROW LEVEL SECURITY",
    };
}

fn quoteIdentifierAlloc(allocator: std.mem.Allocator, ident: []const u8) ![]u8 {
    if (ident.len == 0) return error.InvalidIdentifier;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    for (ident) |ch| {
        if (ch == 0) return error.InvalidIdentifier;
        if (ch == '"') {
            try out.appendSlice(allocator, "\"\"");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "build listen quotes identifier" {
    const sql = try buildListen(std.testing.allocator, "chan\"nel");
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("LISTEN \"chan\"\"nel\"", sql);
}

test "build unlisten quotes identifier" {
    const sql = try buildUnlisten(std.testing.allocator, "chan\"nel");
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("UNLISTEN \"chan\"\"nel\"", sql);
}

test "build listen rejects invalid identifier bytes" {
    try std.testing.expectError(error.InvalidIdentifier, buildListen(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidIdentifier, buildListen(std.testing.allocator, "chan\x00nel"));
}

test "build alter table rls sql quotes identifier" {
    const sql = try buildAlterTableRls(std.testing.allocator, "tenant\"orders", .enable);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("ALTER TABLE \"tenant\"\"orders\" ENABLE ROW LEVEL SECURITY", sql);
}

test "build deallocate prepared statement sql validates name" {
    const sql = try buildDeallocatePrepared(std.testing.allocator, "s0123abcd");
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("DEALLOCATE s0123abcd", sql);

    try std.testing.expectError(error.InvalidStatementName, buildDeallocatePrepared(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidStatementName, buildDeallocatePrepared(std.testing.allocator, "drop;all"));
}
