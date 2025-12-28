// QAIL Text Parser - Main Entry Point
//
// Parses QAIL v2 keyword-based syntax into QailCmd AST.
//
// Syntax Overview
// ```
// get users
// fields id, email
// where active = true
// order by created_at desc
// limit 10
// ```

const std = @import("std");
const ast = @import("../../ast/mod.zig");

pub const base = @import("base.zig");
pub const clauses = @import("clauses.zig");
pub const joins = @import("joins.zig");

const QailCmd = ast.QailCmd;
const CmdKind = ast.CmdKind;
const Expr = ast.Expr;

const ParseError = base.ParseError;
const ParseResult = base.ParseResult;
const skipWhitespace = base.skipWhitespace;
const skipWhitespace1 = base.skipWhitespace1;

/// Parse a complete QAIL query string.
/// Returns error if parsing fails.
/// Note: The returned QailCmd holds slices into the input string - caller must ensure input outlives result.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !QailCmd {
    const result = try parseRoot(allocator, input);

    if (result.remaining.len > 0) {
        const trimmed = skipWhitespace(result.remaining);
        if (trimmed.len > 0) {
            return ParseError.InvalidSyntax;
        }
    }

    return result.value;
}

/// Parse root entry point - returns QailCmd and remaining input
pub fn parseRoot(allocator: std.mem.Allocator, input: []const u8) !ParseResult(QailCmd) {
    var remaining = skipWhitespace(input);

    // Parse action (get, set, del, add, make, begin, commit, rollback)
    const action_result = try base.parseAction(remaining);
    const kind = action_result.value.kind;
    const distinct = action_result.value.distinct;
    remaining = action_result.remaining;

    // Transaction commands (no table)
    if (kind == .begin or kind == .commit or kind == .rollback) {
        return .{
            .remaining = remaining,
            .value = switch (kind) {
                .begin => QailCmd.beginTx(),
                .commit => QailCmd.commitTx(),
                .rollback => QailCmd.rollbackTx(),
                else => unreachable,
            },
        };
    }

    // Parse table name
    remaining = skipWhitespace1(remaining) catch return ParseError.InvalidSyntax;
    const table_result = try base.parseIdentifier(remaining);
    remaining = skipWhitespace(table_result.remaining);

    // Build initial command
    var cmd = switch (kind) {
        .get => QailCmd.get(table_result.value),
        .set => QailCmd.set(table_result.value),
        .del => QailCmd.del(table_result.value),
        .add => QailCmd.add(table_result.value),
        .make => QailCmd.make(table_result.value),
        else => QailCmd.get(table_result.value),
    };
    cmd.distinct = distinct;

    // Parse optional joins
    const joins_result = try joins.parseJoins(allocator, remaining);
    if (joins_result.value.len > 0) {
        cmd.joins = joins_result.value;
    }
    remaining = joins_result.remaining;

    // Parse optional fields clause
    const fields_result = try clauses.parseFieldsClause(allocator, remaining);
    if (fields_result.value.len > 0) {
        cmd.columns = fields_result.value;
    }
    remaining = fields_result.remaining;

    // Parse optional where clause
    const where_result = try clauses.parseWhereClause(allocator, remaining);
    if (where_result.value.len > 0) {
        cmd.where_clauses = where_result.value;
    }
    remaining = where_result.remaining;

    // Parse optional order by clause
    const order_result = try clauses.parseOrderByClause(allocator, remaining);
    if (order_result.value.len > 0) {
        cmd.order_by = order_result.value;
    }
    remaining = order_result.remaining;

    // Parse optional limit clause
    const limit_result = try clauses.parseLimitClause(remaining);
    if (limit_result.value) |limit| {
        cmd.limit_val = limit;
    }
    remaining = limit_result.remaining;

    // Parse optional offset clause
    const offset_result = try clauses.parseOffsetClause(remaining);
    if (offset_result.value) |offset| {
        cmd.offset_val = offset;
    }
    remaining = offset_result.remaining;

    return .{
        .remaining = remaining,
        .value = cmd,
    };
}

/// Strip SQL comments from input
fn stripSqlComments(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Line comment: --
        if (i + 1 < input.len and input[i] == '-' and input[i + 1] == '-') {
            i += 2;
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            if (i < input.len) {
                try result.append(allocator, '\n');
                i += 1;
            }
            continue;
        }

        // Block comment: /* */
        if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    try result.append(allocator, ' ');
                    break;
                }
                i += 1;
            }
            continue;
        }

        try result.append(allocator, input[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

// ==================== Tests ====================

test "parse simple get" {
    const allocator = std.testing.allocator;

    const cmd = try parse(allocator, "get users");
    try std.testing.expectEqual(CmdKind.get, cmd.kind);
    try std.testing.expectEqualStrings("users", cmd.table);
}

test "parse get with fields" {
    const allocator = std.testing.allocator;

    const cmd = try parse(allocator, "get users fields id, email");
    defer allocator.free(cmd.columns);

    try std.testing.expectEqual(CmdKind.get, cmd.kind);
    try std.testing.expectEqual(@as(usize, 2), cmd.columns.len);
}

test "parse get with where" {
    const allocator = std.testing.allocator;

    const cmd = try parse(allocator, "get users where active = true");
    defer allocator.free(cmd.where_clauses);

    try std.testing.expectEqual(CmdKind.get, cmd.kind);
    try std.testing.expectEqual(@as(usize, 1), cmd.where_clauses.len);
}

test "parse full query" {
    const allocator = std.testing.allocator;

    const cmd = try parse(allocator,
        \\get users
        \\fields id, email, name
        \\where active = true and age > 18
        \\order by created_at desc
        \\limit 10
    );
    defer {
        allocator.free(cmd.columns);
        allocator.free(cmd.where_clauses);
        allocator.free(cmd.order_by);
    }

    try std.testing.expectEqual(CmdKind.get, cmd.kind);
    try std.testing.expectEqualStrings("users", cmd.table);
    try std.testing.expectEqual(@as(usize, 3), cmd.columns.len);
    try std.testing.expectEqual(@as(usize, 2), cmd.where_clauses.len);
    try std.testing.expectEqual(@as(usize, 1), cmd.order_by.len);
    try std.testing.expectEqual(@as(?i64, 10), cmd.limit_val);
}

test "parse transaction commands" {
    const allocator = std.testing.allocator;

    const begin = try parse(allocator, "begin");
    try std.testing.expectEqual(CmdKind.begin, begin.kind);

    const commit = try parse(allocator, "commit");
    try std.testing.expectEqual(CmdKind.commit, commit.kind);

    const rollback = try parse(allocator, "rollback");
    try std.testing.expectEqual(CmdKind.rollback, rollback.kind);
}

test "stripSqlComments" {
    const allocator = std.testing.allocator;

    const result = try stripSqlComments(allocator, "get users -- comment\nwhere id = 1");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "--") == null);
}
