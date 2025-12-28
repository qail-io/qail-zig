// QAIL Text Parser - Base Utilities
//
// Core parsing functions for identifiers, values, operators, and actions.
// Port of qail.rs/qail-core/src/parser/grammar/base.rs

const std = @import("std");
const ast = @import("../../ast/mod.zig");

const Value = ast.Value;
const Operator = ast.Operator;
const CmdKind = ast.CmdKind;

/// Parse result: remaining input and parsed value
pub fn ParseResult(comptime T: type) type {
    return struct {
        remaining: []const u8,
        value: T,
    };
}

/// ParseError for when parsing fails
pub const ParseError = error{
    UnexpectedEnd,
    InvalidSyntax,
    InvalidNumber,
    InvalidOperator,
    InvalidAction,
    UnterminatedString,
};

// ==================== Character Utilities ====================

/// Skip leading whitespace, return remaining input
pub fn skipWhitespace(input: []const u8) []const u8 {
    var i: usize = 0;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    return input[i..];
}

/// Skip at least one whitespace character
pub fn skipWhitespace1(input: []const u8) ParseError![]const u8 {
    if (input.len == 0 or !std.ascii.isWhitespace(input[0])) {
        return ParseError.InvalidSyntax;
    }
    return skipWhitespace(input);
}

/// Check if character is valid for identifier
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

/// Case-insensitive string comparison
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Check if input starts with tag (case-insensitive)
pub fn startsWithIgnoreCase(input: []const u8, tag: []const u8) bool {
    if (input.len < tag.len) return false;
    return eqlIgnoreCase(input[0..tag.len], tag);
}

/// Consume tag if present (case-insensitive), return remaining
pub fn consumeTag(input: []const u8, tag: []const u8) ?[]const u8 {
    if (startsWithIgnoreCase(input, tag)) {
        // Ensure tag ends at word boundary for keywords
        if (input.len > tag.len and isIdentChar(input[tag.len])) {
            return null;
        }
        return input[tag.len..];
    }
    return null;
}

// ==================== Core Parsers ====================

/// Parse an identifier (table name, column name, or qualified table.column)
pub fn parseIdentifier(input: []const u8) ParseError!ParseResult([]const u8) {
    const trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return ParseError.UnexpectedEnd;

    // Check for valid start character
    if (!std.ascii.isAlphabetic(trimmed[0]) and trimmed[0] != '_') {
        return ParseError.InvalidSyntax;
    }

    var end: usize = 0;
    while (end < trimmed.len and isIdentChar(trimmed[end])) : (end += 1) {}

    if (end == 0) return ParseError.InvalidSyntax;

    return .{
        .remaining = trimmed[end..],
        .value = trimmed[0..end],
    };
}

/// Parse a value: string, number, bool, null, $param, :named_param
pub fn parseValue(input: []const u8) ParseError!ParseResult(Value) {
    const trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return ParseError.UnexpectedEnd;

    // Parameter: $1, $2
    if (trimmed[0] == '$') {
        var end: usize = 1;
        while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
        if (end == 1) return ParseError.InvalidNumber;
        const num = std.fmt.parseInt(u16, trimmed[1..end], 10) catch return ParseError.InvalidNumber;
        return .{ .remaining = trimmed[end..], .value = .{ .param = num } };
    }

    // Named parameter: :name
    if (trimmed[0] == ':') {
        var end: usize = 1;
        while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '_')) : (end += 1) {}
        if (end == 1) return ParseError.InvalidSyntax;
        return .{ .remaining = trimmed[end..], .value = .{ .named_param = trimmed[1..end] } };
    }

    // Boolean: true, false
    if (consumeTag(trimmed, "true")) |remaining| {
        return .{ .remaining = remaining, .value = .{ .bool = true } };
    }
    if (consumeTag(trimmed, "false")) |remaining| {
        return .{ .remaining = remaining, .value = .{ .bool = false } };
    }

    // Null
    if (consumeTag(trimmed, "null")) |remaining| {
        return .{ .remaining = remaining, .value = .null };
    }

    // String (single quoted)
    if (trimmed[0] == '\'') {
        var end: usize = 1;
        while (end < trimmed.len and trimmed[end] != '\'') : (end += 1) {}
        if (end >= trimmed.len) return ParseError.UnterminatedString;
        return .{ .remaining = trimmed[end + 1 ..], .value = .{ .string = trimmed[1..end] } };
    }

    // String (double quoted)
    if (trimmed[0] == '"') {
        var end: usize = 1;
        while (end < trimmed.len and trimmed[end] != '"') : (end += 1) {}
        if (end >= trimmed.len) return ParseError.UnterminatedString;
        return .{ .remaining = trimmed[end + 1 ..], .value = .{ .string = trimmed[1..end] } };
    }

    // Number (integer or float)
    if (std.ascii.isDigit(trimmed[0]) or (trimmed[0] == '-' and trimmed.len > 1 and std.ascii.isDigit(trimmed[1]))) {
        var end: usize = if (trimmed[0] == '-') @as(usize, 1) else @as(usize, 0);
        var is_float = false;

        while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}

        // Check for decimal point
        if (end < trimmed.len and trimmed[end] == '.') {
            is_float = true;
            end += 1;
            while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) : (end += 1) {}
        }

        if (is_float) {
            const num = std.fmt.parseFloat(f64, trimmed[0..end]) catch return ParseError.InvalidNumber;
            return .{ .remaining = trimmed[end..], .value = .{ .float = num } };
        } else {
            const num = std.fmt.parseInt(i64, trimmed[0..end], 10) catch return ParseError.InvalidNumber;
            return .{ .remaining = trimmed[end..], .value = .{ .int = num } };
        }
    }

    // Column reference (identifier)
    const ident = try parseIdentifier(trimmed);
    return .{ .remaining = ident.remaining, .value = .{ .column = ident.value } };
}

/// Parse comparison operator
pub fn parseOperator(input: []const u8) ParseError!ParseResult(Operator) {
    const trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return ParseError.UnexpectedEnd;

    // Multi-word operators (must check first)
    if (consumeTag(trimmed, "is not null")) |remaining| return .{ .remaining = remaining, .value = .is_not_null };
    if (consumeTag(trimmed, "is null")) |remaining| return .{ .remaining = remaining, .value = .is_null };
    if (consumeTag(trimmed, "not in")) |remaining| return .{ .remaining = remaining, .value = .not_in };
    if (consumeTag(trimmed, "not ilike")) |remaining| return .{ .remaining = remaining, .value = .not_ilike };
    if (consumeTag(trimmed, "not like")) |remaining| return .{ .remaining = remaining, .value = .not_like };
    if (consumeTag(trimmed, "ilike")) |remaining| return .{ .remaining = remaining, .value = .ilike };
    if (consumeTag(trimmed, "like")) |remaining| return .{ .remaining = remaining, .value = .like };
    if (consumeTag(trimmed, "in")) |remaining| return .{ .remaining = remaining, .value = .in };
    if (consumeTag(trimmed, "between")) |remaining| return .{ .remaining = remaining, .value = .between };

    // Two-char operators
    if (trimmed.len >= 2) {
        const two = trimmed[0..2];
        if (std.mem.eql(u8, two, ">=")) return .{ .remaining = trimmed[2..], .value = .gte };
        if (std.mem.eql(u8, two, "<=")) return .{ .remaining = trimmed[2..], .value = .lte };
        if (std.mem.eql(u8, two, "!=")) return .{ .remaining = trimmed[2..], .value = .ne };
        if (std.mem.eql(u8, two, "<>")) return .{ .remaining = trimmed[2..], .value = .ne };
    }

    // Single-char operators
    if (trimmed[0] == '=') return .{ .remaining = trimmed[1..], .value = .eq };
    if (trimmed[0] == '>') return .{ .remaining = trimmed[1..], .value = .gt };
    if (trimmed[0] == '<') return .{ .remaining = trimmed[1..], .value = .lt };
    if (trimmed[0] == '~') return .{ .remaining = trimmed[1..], .value = .regex };

    return ParseError.InvalidOperator;
}

/// Parse action keyword: get, set, del, add, make
/// Returns (CmdKind, distinct flag)
pub fn parseAction(input: []const u8) ParseError!ParseResult(struct { kind: CmdKind, distinct: bool }) {
    const trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return ParseError.UnexpectedEnd;

    // get distinct
    if (consumeTag(trimmed, "get")) |after_get| {
        const after_ws = skipWhitespace(after_get);
        if (consumeTag(after_ws, "distinct")) |remaining| {
            return .{ .remaining = remaining, .value = .{ .kind = .get, .distinct = true } };
        }
        return .{ .remaining = after_get, .value = .{ .kind = .get, .distinct = false } };
    }

    // set / update
    if (consumeTag(trimmed, "set")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .set, .distinct = false } };
    if (consumeTag(trimmed, "update")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .set, .distinct = false } };

    // del / delete
    if (consumeTag(trimmed, "delete")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .del, .distinct = false } };
    if (consumeTag(trimmed, "del")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .del, .distinct = false } };

    // add / insert
    if (consumeTag(trimmed, "insert")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .add, .distinct = false } };
    if (consumeTag(trimmed, "add")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .add, .distinct = false } };

    // make / create
    if (consumeTag(trimmed, "create")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .make, .distinct = false } };
    if (consumeTag(trimmed, "make")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .make, .distinct = false } };

    // Transaction commands
    if (consumeTag(trimmed, "begin")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .begin, .distinct = false } };
    if (consumeTag(trimmed, "commit")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .commit, .distinct = false } };
    if (consumeTag(trimmed, "rollback")) |remaining| return .{ .remaining = remaining, .value = .{ .kind = .rollback, .distinct = false } };

    return ParseError.InvalidAction;
}

// ==================== Tests ====================

test "parseIdentifier" {
    const result = try parseIdentifier("users where");
    try std.testing.expectEqualStrings("users", result.value);
    try std.testing.expectEqualStrings(" where", result.remaining);

    const result2 = try parseIdentifier("user_profiles.id = 1");
    try std.testing.expectEqualStrings("user_profiles.id", result2.value);
}

test "parseValue - integers" {
    const result = try parseValue("42 ");
    try std.testing.expectEqual(Value{ .int = 42 }, result.value);
}

test "parseValue - strings" {
    const result = try parseValue("'hello world'");
    try std.testing.expectEqualStrings("hello world", result.value.string);
}

test "parseValue - params" {
    const result = try parseValue("$1 and");
    try std.testing.expectEqual(Value{ .param = 1 }, result.value);
}

test "parseOperator" {
    const result = try parseOperator("= 5");
    try std.testing.expectEqual(Operator.eq, result.value);

    const result2 = try parseOperator(">= 10");
    try std.testing.expectEqual(Operator.gte, result2.value);

    const result3 = try parseOperator("is null");
    try std.testing.expectEqual(Operator.is_null, result3.value);
}

test "parseAction" {
    const result = try parseAction("get users");
    try std.testing.expectEqual(CmdKind.get, result.value.kind);
    try std.testing.expect(!result.value.distinct);

    const result2 = try parseAction("get distinct users");
    try std.testing.expectEqual(CmdKind.get, result2.value.kind);
    try std.testing.expect(result2.value.distinct);
}
