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
    const first = try parseColumnExpr(trimmed);
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
    errdefer {
        freeWhereClauseAllocations(allocator, clauses.items);
        clauses.deinit(allocator);
    }

    // Parse first condition
    const first = try parseCondition(allocator, trimmed);
    clauses.append(allocator, .{ .condition = first.value, .logical_op = .@"and" }) catch {
        freeConditionValueAllocations(allocator, &first.value);
        return ParseError.InvalidSyntax;
    };
    trimmed = skipWhitespace(first.remaining);

    var saw_and = false;
    var saw_or = false;

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

        switch (logical_op) {
            .@"and" => saw_and = true,
            .@"or" => saw_or = true,
        }

        const cond = try parseCondition(allocator, trimmed);
        clauses.append(allocator, .{ .condition = cond.value, .logical_op = .@"and" }) catch {
            freeConditionValueAllocations(allocator, &cond.value);
            return ParseError.InvalidSyntax;
        };
        trimmed = skipWhitespace(cond.remaining);
    }

    // Keep parser semantics aligned with qail.rs:
    // textual WHERE chains must be either pure-AND or pure-OR.
    if (saw_and and saw_or) {
        return ParseError.InvalidSyntax;
    }

    const chain_op: LogicalOp = if (saw_or) .@"or" else .@"and";
    for (clauses.items) |*clause| {
        clause.logical_op = chain_op;
    }

    return .{
        .remaining = trimmed,
        .value = clauses.toOwnedSlice(allocator) catch return ParseError.InvalidSyntax,
    };
}

/// Parse a single condition: col = val
fn parseCondition(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult(Condition) {
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

    const val = if (op.value == .in or op.value == .not_in)
        try parseInValue(allocator, remaining)
    else
        try parseValue(remaining);

    return .{
        .remaining = val.remaining,
        .value = Condition.init(col.value, op.value, val.value),
    };
}

fn parseInValue(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult(Value) {
    var trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return ParseError.UnexpectedEnd;

    if (trimmed[0] != '(') {
        return parseValue(trimmed);
    }

    trimmed = skipWhitespace(trimmed[1..]);
    if (trimmed.len == 0 or trimmed[0] == ')') return ParseError.InvalidSyntax;

    var values: std.ArrayList(Value) = .empty;
    errdefer values.deinit(allocator);

    while (true) {
        const value = try parseValue(trimmed);
        values.append(allocator, value.value) catch return ParseError.InvalidSyntax;
        trimmed = skipWhitespace(value.remaining);

        if (trimmed.len == 0) return ParseError.InvalidSyntax;

        if (trimmed[0] == ',') {
            trimmed = skipWhitespace(trimmed[1..]);
            if (trimmed.len == 0 or trimmed[0] == ')') return ParseError.InvalidSyntax;
            continue;
        }

        if (trimmed[0] != ')') return ParseError.InvalidSyntax;

        const owned_values = values.toOwnedSlice(allocator) catch return ParseError.InvalidSyntax;
        return .{
            .remaining = trimmed[1..],
            .value = .{ .array = owned_values },
        };
    }
}

pub fn freeWhereClauseAllocations(allocator: std.mem.Allocator, where_clauses: []const WhereClause) void {
    for (where_clauses) |*where_clause| {
        freeConditionValueAllocations(allocator, &where_clause.condition);
    }
}

fn freeConditionValueAllocations(allocator: std.mem.Allocator, condition: *const Condition) void {
    freeValueAllocations(allocator, condition.value);
}

fn freeValueAllocations(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .array => |values| {
            for (values) |item| freeValueAllocations(allocator, item);
            if (values.len > 0) allocator.free(values);
        },
        else => {},
    }
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
        .param => return .{ .remaining = val.remaining, .value = null }, // Dynamic limit
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
        .param => return .{ .remaining = val.remaining, .value = null },
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
    try std.testing.expectEqual(LogicalOp.@"and", result.value[0].logical_op);
    try std.testing.expectEqual(LogicalOp.@"and", result.value[1].logical_op);
}

test "parseWhereClause pure or chain marks all conditions as or" {
    const allocator = std.testing.allocator;

    const result = try parseWhereClause(allocator, "where topic ilike '%test%' or question ilike '%test%'");
    defer allocator.free(result.value);

    try std.testing.expectEqual(@as(usize, 2), result.value.len);
    try std.testing.expectEqual(LogicalOp.@"or", result.value[0].logical_op);
    try std.testing.expectEqual(LogicalOp.@"or", result.value[1].logical_op);
}

test "parseWhereClause rejects mixed and/or chains" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        ParseError.InvalidSyntax,
        parseWhereClause(allocator, "where active = true and role = 'admin' or email = 'a@b.c'"),
    );
}

test "parseWhereClause parses in lists and named parameters" {
    const allocator = std.testing.allocator;

    const list_result = try parseWhereClause(allocator, "where id in (1, 2, 3)");
    defer allocator.free(list_result.value);
    defer freeWhereClauseAllocations(allocator, list_result.value);

    try std.testing.expectEqual(@as(usize, 1), list_result.value.len);
    try std.testing.expectEqual(Operator.in, list_result.value[0].condition.op);
    try std.testing.expect(list_result.value[0].condition.value == .array);
    try std.testing.expectEqual(@as(usize, 3), list_result.value[0].condition.value.array.len);
    try std.testing.expectEqual(Value{ .int = 1 }, list_result.value[0].condition.value.array[0]);
    try std.testing.expectEqual(Value{ .int = 2 }, list_result.value[0].condition.value.array[1]);
    try std.testing.expectEqual(Value{ .int = 3 }, list_result.value[0].condition.value.array[2]);

    const param_result = try parseWhereClause(allocator, "where id not in :ids");
    defer allocator.free(param_result.value);
    defer freeWhereClauseAllocations(allocator, param_result.value);

    try std.testing.expectEqual(@as(usize, 1), param_result.value.len);
    try std.testing.expectEqual(Operator.not_in, param_result.value[0].condition.op);
    try std.testing.expect(param_result.value[0].condition.value == .named_param);
    try std.testing.expectEqualStrings("ids", param_result.value[0].condition.value.named_param);
}

test "parseWhereClause rejects empty in lists" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(ParseError.InvalidSyntax, parseWhereClause(allocator, "where id in ()"));
    try std.testing.expectError(ParseError.InvalidSyntax, parseWhereClause(allocator, "where id in (1,)"));
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
