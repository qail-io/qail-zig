// QAIL Text Parser - Clause Parsers
//
// Parse query clauses: fields, where, order by, limit, offset.
// Port of qail.rs/qail-core/src/parser/grammar/clauses.rs

const std = @import("std");
const ast = @import("../../ast/mod.zig");
const base = @import("base.zig");

const Value = ast.Value;
const Operator = ast.Operator;
const Expr = ast.Expr;
const Condition = ast.Condition;
const WhereClause = ast.cmd.WhereClause;
const OrderBy = ast.cmd.OrderBy;
const SortOrder = ast.SortOrder;
const LogicalOp = ast.LogicalOp;

const ParseError = base.ParseError;
const ParseResult = base.ParseResult;
const skipWhitespace = base.skipWhitespace;
const skipWhitespace1 = base.skipWhitespace1;
const consumeTag = base.consumeTag;
const parseIdentifier = base.parseIdentifier;
const parseValue = base.parseValue;
const parseOperator = base.parseOperator;

// ==================== Fields Clause ====================

/// Parse: fields id, email, name
/// Returns slice of column expressions
pub fn parseFieldsClause(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult([]Expr) {
    var trimmed = skipWhitespace(input);

    // Check for "fields" keyword
    const after_fields = consumeTag(trimmed, "fields") orelse return .{
        .remaining = input,
        .value = &.{},
    };
    trimmed = skipWhitespace(after_fields);

    var columns: std.ArrayList(Expr) = .empty;
    errdefer columns.deinit(allocator);

    // Parse first column (required if "fields" present)
    const first = parseColumnExpr(trimmed) catch |err| {
        columns.deinit(allocator);
        return err;
    };
    columns.append(allocator, first.value) catch return ParseError.InvalidSyntax;
    trimmed = skipWhitespace(first.remaining);

    // Parse remaining columns separated by commas
    while (trimmed.len > 0 and trimmed[0] == ',') {
        trimmed = skipWhitespace(trimmed[1..]);
        const col = parseColumnExpr(trimmed) catch break;
        columns.append(allocator, col.value) catch return ParseError.InvalidSyntax;
        trimmed = skipWhitespace(col.remaining);
    }

    return .{
        .remaining = trimmed,
        .value = columns.toOwnedSlice(allocator) catch return ParseError.InvalidSyntax,
    };
}

/// Parse a single column expression: *, col, col as alias, count(col)
fn parseColumnExpr(input: []const u8) ParseError!ParseResult(Expr) {
    const trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return ParseError.UnexpectedEnd;

    // Star
    if (trimmed[0] == '*') {
        return .{ .remaining = trimmed[1..], .value = .star };
    }

    // Parse identifier
    const ident = try parseIdentifier(trimmed);
    var remaining = skipWhitespace(ident.remaining);

    // Check for "as alias"
    if (consumeTag(remaining, "as")) |after_as| {
        remaining = skipWhitespace(after_as);
        const alias = try parseIdentifier(remaining);
        return .{
            .remaining = alias.remaining,
            .value = .{ .aliased = .{ .name = ident.value, .alias = alias.value } },
        };
    }

    return .{ .remaining = remaining, .value = .{ .named = ident.value } };
}

// ==================== Where Clause ====================

/// Parse: where col = val and col2 > val2
pub fn parseWhereClause(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult([]WhereClause) {
    var trimmed = skipWhitespace(input);

    // Check for "where" keyword
    const after_where = consumeTag(trimmed, "where") orelse return .{
        .remaining = input,
        .value = &.{},
    };
    trimmed = try skipWhitespace1(after_where);

    var clauses: std.ArrayList(WhereClause) = .empty;
    errdefer clauses.deinit(allocator);

    // Parse first condition
    const first = try parseCondition(trimmed);
    clauses.append(allocator, .{ .condition = first.value, .logical_op = .@"and" }) catch return ParseError.InvalidSyntax;
    trimmed = skipWhitespace(first.remaining);

    // Parse remaining conditions with AND/OR
    while (true) {
        const logical_op: LogicalOp = blk: {
            if (consumeTag(trimmed, "and")) |after| {
                trimmed = skipWhitespace(after);
                break :blk .@"and";
            } else if (consumeTag(trimmed, "or")) |after| {
                trimmed = skipWhitespace(after);
                break :blk .@"or";
            }
            break;
        };

        const cond = parseCondition(trimmed) catch break;
        clauses.append(allocator, .{ .condition = cond.value, .logical_op = logical_op }) catch return ParseError.InvalidSyntax;
        trimmed = skipWhitespace(cond.remaining);
    }

    return .{
        .remaining = trimmed,
        .value = clauses.toOwnedSlice(allocator) catch return ParseError.InvalidSyntax,
    };
}

/// Parse a single condition: col = val
fn parseCondition(input: []const u8) ParseError!ParseResult(Condition) {
    const trimmed = skipWhitespace(input);

    // Parse column name
    const col = try parseIdentifier(trimmed);
    var remaining = skipWhitespace(col.remaining);

    // Parse operator
    const op = try parseOperator(remaining);
    remaining = skipWhitespace(op.remaining);

    // Handle IS NULL / IS NOT NULL (no value)
    if (op.value == .is_null or op.value == .is_not_null) {
        return .{
            .remaining = remaining,
            .value = Condition.init(col.value, op.value, .null),
        };
    }

    // Parse value
    const val = try parseValue(remaining);

    return .{
        .remaining = val.remaining,
        .value = Condition.init(col.value, op.value, val.value),
    };
}

// ==================== Order By Clause ====================

/// Parse: order by col desc, col2 asc
pub fn parseOrderByClause(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult([]OrderBy) {
    var trimmed = skipWhitespace(input);

    // Check for "order by" keyword
    const after_order = consumeTag(trimmed, "order") orelse return .{
        .remaining = input,
        .value = &.{},
    };
    trimmed = skipWhitespace(after_order);
    const after_by = consumeTag(trimmed, "by") orelse return .{
        .remaining = input,
        .value = &.{},
    };
    trimmed = skipWhitespace(after_by);

    var orders: std.ArrayList(OrderBy) = .empty;
    errdefer orders.deinit(allocator);

    // Parse first order
    const first = try parseOrderItem(trimmed);
    orders.append(allocator, first.value) catch return ParseError.InvalidSyntax;
    trimmed = skipWhitespace(first.remaining);

    // Parse remaining orders
    while (trimmed.len > 0 and trimmed[0] == ',') {
        trimmed = skipWhitespace(trimmed[1..]);
        const order = parseOrderItem(trimmed) catch break;
        orders.append(allocator, order.value) catch return ParseError.InvalidSyntax;
        trimmed = skipWhitespace(order.remaining);
    }

    return .{
        .remaining = trimmed,
        .value = orders.toOwnedSlice(allocator) catch return ParseError.InvalidSyntax,
    };
}

/// Parse: col [desc|asc] [nulls first|last]
fn parseOrderItem(input: []const u8) ParseError!ParseResult(OrderBy) {
    const trimmed = skipWhitespace(input);

    // Parse column
    const col = try parseIdentifier(trimmed);
    var remaining = skipWhitespace(col.remaining);

    // Parse optional direction
    var order: SortOrder = .asc;
    if (consumeTag(remaining, "desc")) |after| {
        order = .desc;
        remaining = skipWhitespace(after);
    } else if (consumeTag(remaining, "asc")) |after| {
        order = .asc;
        remaining = skipWhitespace(after);
    }

    // Parse optional nulls handling
    if (consumeTag(remaining, "nulls")) |after_nulls| {
        remaining = skipWhitespace(after_nulls);
        if (consumeTag(remaining, "first")) |after| {
            order = if (order == .desc) .desc_nulls_first else .asc_nulls_first;
            remaining = skipWhitespace(after);
        } else if (consumeTag(remaining, "last")) |after| {
            order = if (order == .desc) .desc_nulls_last else .asc_nulls_last;
            remaining = skipWhitespace(after);
        }
    }

    return .{
        .remaining = remaining,
        .value = .{ .column = col.value, .order = order },
    };
}

// ==================== Limit/Offset Clauses ====================

/// Parse: limit 10
pub fn parseLimitClause(input: []const u8) ParseError!ParseResult(?i64) {
    const trimmed = skipWhitespace(input);

    const after_limit = consumeTag(trimmed, "limit") orelse return .{
        .remaining = input,
        .value = null,
    };
    const remaining = skipWhitespace(after_limit);

    const val = try parseValue(remaining);
    const limit = switch (val.value) {
        .int => |n| n,
        .param => |_| return .{ .remaining = val.remaining, .value = null }, // Dynamic limit
        else => return ParseError.InvalidNumber,
    };

    return .{ .remaining = val.remaining, .value = limit };
}

/// Parse: offset 20
pub fn parseOffsetClause(input: []const u8) ParseError!ParseResult(?i64) {
    const trimmed = skipWhitespace(input);

    const after_offset = consumeTag(trimmed, "offset") orelse return .{
        .remaining = input,
        .value = null,
    };
    const remaining = skipWhitespace(after_offset);

    const val = try parseValue(remaining);
    const offset = switch (val.value) {
        .int => |n| n,
        .param => |_| return .{ .remaining = val.remaining, .value = null },
        else => return ParseError.InvalidNumber,
    };

    return .{ .remaining = val.remaining, .value = offset };
}

// ==================== Tests ====================

test "parseFieldsClause" {
    const allocator = std.testing.allocator;

    const result = try parseFieldsClause(allocator, "fields id, email, name where");
    defer allocator.free(result.value);

    try std.testing.expectEqual(@as(usize, 3), result.value.len);
    try std.testing.expectEqualStrings("id", result.value[0].named);
    try std.testing.expectEqualStrings("email", result.value[1].named);
    try std.testing.expectEqualStrings("name", result.value[2].named);
}

test "parseWhereClause" {
    const allocator = std.testing.allocator;

    const result = try parseWhereClause(allocator, "where active = true and age > 18");
    defer allocator.free(result.value);

    try std.testing.expectEqual(@as(usize, 2), result.value.len);
    try std.testing.expectEqualStrings("active", result.value[0].condition.column);
    try std.testing.expectEqualStrings("age", result.value[1].condition.column);
}

test "parseOrderByClause" {
    const allocator = std.testing.allocator;

    const result = try parseOrderByClause(allocator, "order by created_at desc, name asc");
    defer allocator.free(result.value);

    try std.testing.expectEqual(@as(usize, 2), result.value.len);
    try std.testing.expectEqual(SortOrder.desc, result.value[0].order);
    try std.testing.expectEqual(SortOrder.asc, result.value[1].order);
}

test "parseLimitClause" {
    const result = try parseLimitClause("limit 10 offset");
    try std.testing.expectEqual(@as(?i64, 10), result.value);
}
