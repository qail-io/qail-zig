//! QAIL Text Parser - Join Clause Parser
//!
//! Parse JOIN clauses: inner join, left join, right join, etc.

const std = @import("std");
const ast = @import("../../ast/mod.zig");
const base = @import("base.zig");

const Join = ast.cmd.Join;
const JoinKind = ast.cmd.JoinKind;

const ParseError = base.ParseError;
const ParseResult = base.ParseResult;
const skipWhitespace = base.skipWhitespace;
const consumeTag = base.consumeTag;
const parseIdentifier = base.parseIdentifier;

/// Parse a JOIN clause: [inner|left|right|full|cross] join table on left = right
pub fn parseJoinClause(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult(?Join) {
    _ = allocator;
    var trimmed = skipWhitespace(input);

    // Determine join type
    const kind: JoinKind = blk: {
        if (consumeTag(trimmed, "left")) |after| {
            trimmed = skipWhitespace(after);
            break :blk .left;
        } else if (consumeTag(trimmed, "right")) |after| {
            trimmed = skipWhitespace(after);
            break :blk .right;
        } else if (consumeTag(trimmed, "full")) |after| {
            trimmed = skipWhitespace(after);
            break :blk .full;
        } else if (consumeTag(trimmed, "cross")) |after| {
            trimmed = skipWhitespace(after);
            break :blk .cross;
        } else if (consumeTag(trimmed, "inner")) |after| {
            trimmed = skipWhitespace(after);
            break :blk .inner;
        }
        break :blk .inner; // Default to inner
    };

    // Check for "join" keyword
    const after_join = consumeTag(trimmed, "join") orelse return .{
        .remaining = input,
        .value = null,
    };
    trimmed = skipWhitespace(after_join);

    // Parse table name
    const table = parseIdentifier(trimmed) catch return .{
        .remaining = input,
        .value = null,
    };
    trimmed = skipWhitespace(table.remaining);

    // Parse optional "on" condition: col1 = col2
    var on_left: []const u8 = "";
    var on_right: []const u8 = "";

    if (consumeTag(trimmed, "on")) |after_on| {
        trimmed = skipWhitespace(after_on);

        // Parse left column
        const left = parseIdentifier(trimmed) catch {
            return .{
                .remaining = trimmed,
                .value = .{
                    .kind = kind,
                    .table = table.value,
                    .on_left = "",
                    .on_right = "",
                    .alias = null,
                },
            };
        };
        trimmed = skipWhitespace(left.remaining);
        on_left = left.value;

        // Skip '='
        if (trimmed.len > 0 and trimmed[0] == '=') {
            trimmed = skipWhitespace(trimmed[1..]);
        }

        // Parse right column
        if (parseIdentifier(trimmed)) |right| {
            on_right = right.value;
            trimmed = skipWhitespace(right.remaining);
        } else |_| {}
    }

    return .{
        .remaining = trimmed,
        .value = .{
            .kind = kind,
            .table = table.value,
            .on_left = on_left,
            .on_right = on_right,
            .alias = null,
        },
    };
}

/// Parse all joins from input
pub fn parseJoins(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult([]Join) {
    var joins: std.ArrayList(Join) = .empty;
    errdefer joins.deinit(allocator);

    var remaining = input;

    while (true) {
        const result = try parseJoinClause(allocator, remaining);
        if (result.value) |join| {
            joins.append(allocator, join) catch return ParseError.InvalidSyntax;
            remaining = result.remaining;
        } else {
            break;
        }
    }

    return .{
        .remaining = remaining,
        .value = joins.toOwnedSlice(allocator) catch return ParseError.InvalidSyntax,
    };
}

// ==================== Tests ====================

test "parseJoinClause - inner join" {
    const allocator = std.testing.allocator;

    const result = try parseJoinClause(allocator, "join profiles on users.id = profiles.user_id");

    try std.testing.expect(result.value != null);
    const join = result.value.?;
    try std.testing.expectEqual(JoinKind.inner, join.kind);
    try std.testing.expectEqualStrings("profiles", join.table);
    try std.testing.expectEqualStrings("users.id", join.on_left);
    try std.testing.expectEqualStrings("profiles.user_id", join.on_right);
}

test "parseJoinClause - left join" {
    const allocator = std.testing.allocator;

    const result = try parseJoinClause(allocator, "left join orders on users.id = orders.user_id");

    try std.testing.expect(result.value != null);
    const join = result.value.?;
    try std.testing.expectEqual(JoinKind.left, join.kind);
    try std.testing.expectEqualStrings("orders", join.table);
}
