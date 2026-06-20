const std = @import("std");

const ast = struct {
    pub const cmd = @import("../../ast/cmd.zig");
    pub const expr = @import("../../ast/expr.zig");
    pub const values = @import("../../ast/values.zig");
};

const Expr = ast.expr.Expr;
const Value = ast.values.Value;
const WindowExpr = @TypeOf(@as(Expr, undefined).window);
const QailCmd = ast.cmd.QailCmd;
const MAX_RAW_FUNCTION_VALUE_LEN: usize = 1024;

pub fn writeWhereClauses(writer: anytype, clauses: []const ast.cmd.WhereClause) !void {
    try writeWhereClausesWithContext(writer, clauses, null);
}

pub fn writeWhereClausesWithContext(writer: anytype, clauses: []const ast.cmd.WhereClause, cmd: ?*const QailCmd) !void {
    var has_and = false;
    var has_or = false;

    for (clauses) |clause| {
        switch (clause.logical_op) {
            .@"and" => has_and = true,
            .@"or" => has_or = true,
        }
    }

    if (!has_and and !has_or) {
        return;
    }

    try writer.writeAll(" WHERE ");

    var wrote_clause = false;

    if (has_and) {
        for (clauses) |clause| {
            if (clause.logical_op != .@"and") continue;
            if (wrote_clause) {
                try writer.writeAll(" AND ");
            }
            try writeConditionWithContext(writer, &clause.condition, cmd);
            wrote_clause = true;
        }
    }

    if (has_or) {
        if (wrote_clause) {
            try writer.writeAll(" AND ");
        }
        try writer.writeAll("(");
        var first = true;
        for (clauses) |clause| {
            if (clause.logical_op != .@"or") continue;
            if (!first) {
                try writer.writeAll(" OR ");
            }
            first = false;
            try writeConditionWithContext(writer, &clause.condition, cmd);
        }
        try writer.writeAll(")");
    }
}

pub fn writeCondition(writer: anytype, condition: *const ast.expr.Condition) anyerror!void {
    try writeConditionWithContext(writer, condition, null);
}

pub fn writeConditionWithContext(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) anyerror!void {
    switch (condition.op) {
        .in, .not_in => return writeInCondition(writer, condition, cmd),
        .between, .not_between => return writeBetweenCondition(writer, condition, cmd),
        .exists, .not_exists => return error.InvalidExistsCondition,
        else => {},
    }

    try writeConditionLeft(writer, condition, cmd);

    switch (condition.op) {
        .is_null, .is_not_null => try writer.print(" {s}", .{condition.op.toSql()}),
        else => {
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValueWithContext(writer, &condition.value, cmd);
        },
    }
}

fn writeConditionLeft(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) anyerror!void {
    if (condition.column.len != 0) {
        try writeConditionColumnReference(writer, condition.column, cmd);
    } else {
        var left = condition.left;
        try writeExprWithContext(writer, &left, cmd);
    }
}

fn writeConditionColumnReference(writer: anytype, column: []const u8, cmd: ?*const QailCmd) !void {
    const trimmed = std.mem.trim(u8, column, " \t\r\n");
    if (try writeConditionFunctionReference(writer, trimmed, cmd)) return;
    try writeColumnReference(writer, trimmed, cmd);
}

fn writeConditionFunctionReference(writer: anytype, value: []const u8, cmd: ?*const QailCmd) !bool {
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return false;
    if (!std.mem.endsWith(u8, value, ")")) return false;

    const name = std.mem.trim(u8, value[0..open], " \t\r\n");
    if (!isSafeFunctionName(name)) return false;
    const args = std.mem.trim(u8, value[open + 1 .. value.len - 1], " \t\r\n");
    if (std.mem.indexOfScalar(u8, args, '(') != null or std.mem.indexOfScalar(u8, args, ')') != null) {
        return false;
    }

    var validate_parts = std.mem.splitScalar(u8, args, ',');
    while (validate_parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (args.len != 0 and part.len == 0) return false;
    }

    try writer.writeAll(name);
    try writer.writeByte('(');
    if (args.len != 0) {
        var parts = std.mem.splitScalar(u8, args, ',');
        var first = true;
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\r\n");
            if (part.len == 0) return false;
            if (!first) try writer.writeAll(", ");
            first = false;
            try writeIdentifierOrStarWithContext(writer, part, cmd);
        }
    }
    try writer.writeByte(')');
    return true;
}

fn writeInCondition(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) !void {
    switch (condition.value) {
        .array => |values| {
            if (values.len == 0) return error.InvalidInCondition;

            try writeConditionLeft(writer, condition, cmd);
            try writer.print(" {s} (", .{condition.op.toSql()});
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValueWithContext(writer, &value, cmd);
            }
            try writer.writeByte(')');
        },
        .param, .named_param => {
            try writeConditionLeft(writer, condition, cmd);
            try writer.writeAll(if (condition.op == .in) " = ANY(" else " != ALL(");
            try writeValueWithContext(writer, &condition.value, cmd);
            try writer.writeByte(')');
        },
        else => return error.InvalidInCondition,
    }
}

fn writeBetweenCondition(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) !void {
    switch (condition.value) {
        .range => |range| {
            try writeConditionLeft(writer, condition, cmd);
            try writer.print(" {s} {d} AND {d}", .{ condition.op.toSql(), range.low, range.high });
        },
        .array => |values| {
            if (values.len != 2) return error.InvalidBetweenCondition;

            try writeConditionLeft(writer, condition, cmd);
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValueWithContext(writer, &values[0], cmd);
            try writer.writeAll(" AND ");
            try writeValueWithContext(writer, &values[1], cmd);
        },
        else => return error.InvalidBetweenCondition,
    }
}

pub fn writeExpr(writer: anytype, ex: *const Expr) anyerror!void {
    try writeExprWithContext(writer, ex, null);
}

pub fn writeExprWithContext(writer: anytype, ex: *const Expr, cmd: ?*const QailCmd) anyerror!void {
    switch (ex.*) {
        .star => try writer.writeAll("*"),
        .named => |name| try writeColumnReference(writer, name, cmd),
        .aliased => |a| {
            try writeColumnReference(writer, a.name, cmd);
            try writer.writeAll(" AS ");
            try writeIdentifierMaybeQuoted(writer, a.alias);
        },
        .aggregate => |agg| {
            try writer.writeAll(agg.func.toSql());
            try writer.writeAll("(");
            if (agg.distinct) try writer.writeAll("DISTINCT ");
            try writeIdentifierOrStarWithContext(writer, agg.column, cmd);
            try writer.writeAll(")");
            if (agg.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .literal => |val| try writeValueWithContext(writer, &val, cmd),
        .binary => |b| {
            try writeExprWithContext(writer, b.left, cmd);
            switch (b.op) {
                .is_null, .is_not_null => try writer.print(" {s}", .{b.op.toSql()}),
                else => {
                    try writer.print(" {s} ", .{b.op.toSql()});
                    try writeExprWithContext(writer, b.right, cmd);
                },
            }
            if (b.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .func_call => |fc| {
            if (!isSafeFunctionName(fc.name)) return error.InvalidFunctionName;
            try writer.writeAll(fc.name);
            try writer.writeAll("(");
            for (fc.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExprWithContext(writer, &arg, cmd);
            }
            try writer.writeAll(")");
            if (fc.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .case_expr => |c| {
            try writer.writeAll("CASE");
            for (c.when_clauses) |when_clause| {
                try writer.writeAll(" WHEN ");
                try writeConditionWithContext(writer, &when_clause.condition, cmd);
                try writer.writeAll(" THEN ");
                try writeExprWithContext(writer, &when_clause.result, cmd);
            }
            if (c.else_value) |else_expr| {
                try writer.writeAll(" ELSE ");
                try writeExprWithContext(writer, else_expr, cmd);
            }
            try writer.writeAll(" END");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subquery => |sq| {
            try writer.writeByte('(');
            try writeCheckedSubquerySql(writer, sq.sql);
            try writer.writeByte(')');
            if (sq.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .coalesce => |c| {
            try writer.writeAll("COALESCE(");
            for (c.exprs, 0..) |ex_inner, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExprWithContext(writer, &ex_inner, cmd);
            }
            try writer.writeAll(")");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .cast => |c| {
            const target_type = checkedSqlTypeFragment(c.target_type) orelse return error.InvalidCastTarget;
            try writeExprWithContext(writer, c.expr, cmd);
            try writer.writeAll("::");
            try writer.writeAll(target_type);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .json_access => |ja| {
            try writeColumnReference(writer, ja.column, cmd);
            for (ja.path) |seg| {
                if (seg.as_text) {
                    try writer.writeAll("->>'");
                } else {
                    try writer.writeAll("->'");
                }
                try writeEscapedSqlString(writer, seg.key);
                try writer.writeByte('\'');
            }
            if (ja.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .array_constructor => |a| {
            try writer.writeAll("ARRAY[");
            for (a.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExprWithContext(writer, &elem, cmd);
            }
            try writer.writeByte(']');
            if (a.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .row_constructor => |r| {
            try writer.writeAll("ROW(");
            for (r.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExprWithContext(writer, &elem, cmd);
            }
            try writer.writeByte(')');
            if (r.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subscript => |s| {
            try writeExprWithContext(writer, s.base, cmd);
            try writer.writeByte('[');
            try writeExprWithContext(writer, s.index, cmd);
            try writer.writeByte(']');
            if (s.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .collate => |c| {
            try writeExprWithContext(writer, c.expr, cmd);
            try writer.writeAll(" COLLATE ");
            try writeIdentifierOrError(writer, c.collation);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .field_access => |f| {
            try writer.writeByte('(');
            try writeExprWithContext(writer, f.expr, cmd);
            try writer.writeAll(").");
            try writeIdentifierOrError(writer, f.field);
            if (f.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .window => |w| try writeWindowExpr(writer, w, cmd),
        .exists_subquery => |sq| {
            if (sq.negated) {
                try writer.writeAll("NOT EXISTS (");
            } else {
                try writer.writeAll("EXISTS (");
            }
            try writeCheckedSubquerySql(writer, sq.sql);
            try writer.writeByte(')');
            if (sq.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .unary => |u| {
            switch (u.op) {
                .not => try writer.writeAll("NOT "),
                else => try writer.writeAll(u.op.toSql()),
            }
            try writeExprWithContext(writer, u.operand, cmd);
        },
        .raw => |raw| try writeCheckedRawExpression(writer, raw),
        else => {},
    }
}

fn isSafeFunctionName(name: []const u8) bool {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return false;

    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }

    return true;
}

fn isSafeRawFunctionValue(value: []const u8) bool {
    return value.len <= MAX_RAW_FUNCTION_VALUE_LEN and
        std.mem.indexOfScalar(u8, value, 0) == null and
        std.mem.indexOfScalar(u8, value, ';') == null and
        std.mem.indexOf(u8, value, "--") == null and
        std.mem.indexOf(u8, value, "/*") == null and
        std.mem.indexOf(u8, value, "*/") == null;
}

fn checkedSqlTypeFragment(fragment: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, fragment, " \t\r\n");
    if (trimmed.len == 0 or
        std.mem.indexOfScalar(u8, trimmed, 0) != null or
        std.mem.indexOfScalar(u8, trimmed, ';') != null or
        std.mem.indexOfScalar(u8, trimmed, '\'') != null or
        std.mem.indexOfScalar(u8, trimmed, '"') != null or
        std.mem.indexOf(u8, trimmed, "--") != null or
        std.mem.indexOf(u8, trimmed, "/*") != null or
        std.mem.indexOf(u8, trimmed, "*/") != null)
    {
        return null;
    }

    for (trimmed) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == '_' or c == '.' or c == ' ' or c == '(' or c == ')' or
            c == ',' or c == '[' or c == ']' or c == '%' or c == '+' or c == '-';
        if (!ok) return null;
    }
    return trimmed;
}

fn containsUnquotedStatementDelimiter(value: []const u8) bool {
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

    return false;
}

fn checkedSqlExprFragment(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or containsUnquotedStatementDelimiter(trimmed)) return null;
    return trimmed;
}

pub fn checkedReadOnlySubquerySql(value: []const u8) ?[]const u8 {
    const checked = checkedSqlExprFragment(value) orelse return null;
    if (!startsWithReadOnlySubqueryKeyword(checked)) return null;
    return checked;
}

fn startsWithReadOnlySubqueryKeyword(value: []const u8) bool {
    return startsWithSqlKeyword(value, "SELECT") or
        startsWithSqlKeyword(value, "VALUES") or
        startsWithSqlKeyword(value, "TABLE");
}

fn startsWithSqlKeyword(value: []const u8, keyword: []const u8) bool {
    if (value.len < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(value[0..keyword.len], keyword)) return false;
    if (value.len == keyword.len) return true;
    const next = value[keyword.len];
    return std.ascii.isWhitespace(next) or next == '(';
}

fn writeCheckedRawExpression(writer: anytype, fragment: []const u8) !void {
    const checked = checkedSqlExprFragment(fragment) orelse return error.UnsafeSqlFragment;
    try writer.writeAll(checked);
}

fn writeCheckedSubquerySql(writer: anytype, sql: []const u8) !void {
    const checked = checkedReadOnlySubquerySql(sql) orelse return error.InvalidReadOnlySubquery;
    try writer.writeAll(checked);
}

fn isValidQualifiedIdentifier(value: []const u8) bool {
    return value.len != 0 and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !std.mem.startsWith(u8, value, ".") and
        !std.mem.endsWith(u8, value, ".") and
        std.mem.indexOf(u8, value, "..") == null;
}

pub fn writeIdentifierOrError(writer: anytype, value: []const u8) !void {
    if (!isValidQualifiedIdentifier(value)) return error.InvalidIdentifier;

    var parts = std.mem.splitScalar(u8, value, '.');
    var first = true;
    while (parts.next()) |part| {
        if (!first) try writer.writeByte('.');
        first = false;
        try writeIdentifierMaybeQuoted(writer, part);
    }
}

pub fn writeSingleIdentifierOrError(writer: anytype, value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidIdentifier;
    try writeIdentifierMaybeQuoted(writer, value);
}

const TableReference = struct {
    table: []const u8,
    alias: ?[]const u8 = null,
    explicit_as: bool = false,
};

const ColumnResolution = struct {
    qualifier: []const u8,
    tail: []const u8,
};

fn splitTableReference(value: []const u8) ?TableReference {
    var parts = std.mem.tokenizeAny(u8, value, " \t\r\n");
    const table = parts.next() orelse return null;
    const second = parts.next();
    const third = parts.next();
    if (parts.next() != null) return null;

    if (second == null) {
        return .{ .table = table };
    }

    if (third == null) {
        if (std.ascii.eqlIgnoreCase(second.?, "as")) return null;
        return .{ .table = table, .alias = second.? };
    }

    if (!std.ascii.eqlIgnoreCase(second.?, "as")) return null;
    return .{ .table = table, .alias = third.?, .explicit_as = true };
}

fn firstPart(value: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, value, '.')) |dot| {
        if (dot == 0 or dot + 1 >= value.len) return null;
        return value[0..dot];
    }
    return value;
}

fn tailAfterFirstPart(value: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse return null;
    if (dot == 0 or dot + 1 >= value.len) return null;
    return value[dot + 1 ..];
}

fn lastPart(value: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, value, '.')) |dot| {
        return value[dot + 1 ..];
    }
    return value;
}

fn identEq(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, left, "\""),
        std.mem.trim(u8, right, "\""),
    );
}

fn resolveAgainstTableReference(value: []const u8, table_value: []const u8, explicit_alias: ?[]const u8) ?ColumnResolution {
    const parsed = splitTableReference(table_value) orelse TableReference{ .table = table_value };
    const alias = explicit_alias orelse parsed.alias;
    const alias_name = alias orelse return null;
    const first = firstPart(value) orelse return null;

    if (identEq(first, alias_name)) {
        return .{ .qualifier = alias_name, .tail = tailAfterFirstPart(value) orelse "" };
    }

    if (value.len > parsed.table.len and
        value[parsed.table.len] == '.' and
        std.ascii.eqlIgnoreCase(value[0..parsed.table.len], parsed.table))
    {
        return .{ .qualifier = alias_name, .tail = value[parsed.table.len + 1 ..] };
    }

    if (identEq(first, lastPart(parsed.table))) {
        return .{ .qualifier = alias_name, .tail = tailAfterFirstPart(value) orelse "" };
    }

    return null;
}

fn resolveKnownColumnReference(value: []const u8, cmd: ?*const QailCmd) ?ColumnResolution {
    const current = cmd orelse return null;
    const first = firstPart(value) orelse return null;

    if (current.table.len > 0) {
        if (resolveAgainstTableReference(value, current.table, current.table_alias)) |resolved| {
            return resolved;
        }
    }

    if (current.merge) |merge| {
        if (merge.target_alias) |alias| {
            if (resolveAgainstTableReference(value, current.table, alias)) |resolved| {
                return resolved;
            }
        }

        switch (merge.source) {
            .table => |table| {
                if (resolveAgainstTableReference(value, table.name, table.alias)) |resolved| {
                    return resolved;
                }
            },
            .query => |query| {
                if (query.alias) |alias| {
                    if (identEq(first, alias)) {
                        return .{ .qualifier = alias, .tail = tailAfterFirstPart(value) orelse "" };
                    }
                }
            },
        }
    }

    for (current.joins) |join| {
        if (resolveAgainstTableReference(value, join.table, join.alias)) |resolved| {
            return resolved;
        }
    }

    for (current.from_tables) |table| {
        if (resolveAgainstTableReference(value, table, null)) |resolved| {
            return resolved;
        }
    }

    for (current.using_tables) |table| {
        if (resolveAgainstTableReference(value, table, null)) |resolved| {
            return resolved;
        }
    }

    return null;
}

pub fn writeTableReferenceOrError(writer: anytype, value: []const u8) !void {
    const ref = splitTableReference(value) orelse {
        try writeIdentifierOrError(writer, value);
        return;
    };

    try writeIdentifierOrError(writer, ref.table);
    if (ref.alias) |alias| {
        if (ref.explicit_as) {
            try writer.writeAll(" AS ");
        } else {
            try writer.writeByte(' ');
        }
        try writeIdentifierOrError(writer, alias);
    }
}

pub fn writeColumnReference(writer: anytype, value: []const u8, cmd: ?*const QailCmd) !void {
    if (resolveKnownColumnReference(value, cmd)) |resolved| {
        try writeIdentifierOrError(writer, resolved.qualifier);
        if (resolved.tail.len > 0) {
            try writer.writeByte('.');
            try writeIdentifierOrError(writer, resolved.tail);
        }
        return;
    }

    try writeIdentifierOrError(writer, value);
}

pub fn writeInsertTargetColumn(writer: anytype, ex: *const Expr) !void {
    switch (ex.*) {
        .named => |name| try writeIdentifierOrError(writer, name),
        else => return error.InvalidInsertColumn,
    }
}

fn writeIdentifierOrStar(writer: anytype, value: []const u8) !void {
    if (std.mem.eql(u8, value, "*")) {
        try writer.writeByte('*');
    } else {
        try writeIdentifierOrError(writer, value);
    }
}

fn writeIdentifierOrStarWithContext(writer: anytype, value: []const u8, cmd: ?*const QailCmd) !void {
    if (std.mem.eql(u8, value, "*")) {
        try writer.writeByte('*');
    } else {
        try writeColumnReference(writer, value, cmd);
    }
}

fn writeIdentifierMaybeQuoted(writer: anytype, ident: []const u8) !void {
    var needs_quotes = ident.len == 0 or std.ascii.isDigit(ident[0]);
    if (!needs_quotes) {
        for (ident) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                needs_quotes = true;
                break;
            }
        }
    }

    if (!needs_quotes) {
        try writer.writeAll(ident);
        return;
    }

    try writer.writeByte('"');
    for (ident) |c| {
        if (c == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('"');
}

fn writeEscapedSqlString(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        if (c == '\'') {
            try writer.writeAll("''");
        } else {
            try writer.writeByte(c);
        }
    }
}

fn writeWindowExpr(writer: anytype, w: WindowExpr, cmd: ?*const QailCmd) !void {
    if (!isSafeFunctionName(w.func)) return error.InvalidWindowFunctionName;

    try writer.writeAll(w.func);
    try writer.writeAll("() OVER (");
    if (w.partition.len > 0) {
        try writer.writeAll("PARTITION BY ");
        for (w.partition, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeColumnReference(writer, col, cmd);
        }
    }
    if (w.order.len > 0) {
        if (w.partition.len > 0) try writer.writeByte(' ');
        try writer.writeAll("ORDER BY ");
        for (w.order, 0..) |o, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeColumnReference(writer, o.column, cmd);
            try writer.writeAll(if (o.direction == .asc) " ASC" else " DESC");
        }
    }
    if (w.frame) |frame| {
        if (w.partition.len > 0 or w.order.len > 0) try writer.writeByte(' ');
        try writer.writeAll(if (frame.kind == .rows) "ROWS" else "RANGE");
        try writer.writeAll(" BETWEEN ");
        try writeFrameBound(writer, frame.start_bound);
        if (frame.end_bound) |end| {
            try writer.writeAll(" AND ");
            try writeFrameBound(writer, end);
        }
    }
    try writer.writeByte(')');
    const alias_opt: ?[]const u8 = if (w.alias) |alias| alias else if (w.name.len > 0) w.name else null;
    if (alias_opt) |alias| {
        try writer.writeAll(" AS ");
        try writeIdentifierMaybeQuoted(writer, alias);
    }
}

fn writeFrameBound(writer: anytype, bound: ast.expr.FrameBound) !void {
    switch (bound) {
        .unbounded_preceding => try writer.writeAll("UNBOUNDED PRECEDING"),
        .unbounded_following => try writer.writeAll("UNBOUNDED FOLLOWING"),
        .current_row => try writer.writeAll("CURRENT ROW"),
        .preceding => |n| try writer.print("{d} PRECEDING", .{n}),
        .following => |n| try writer.print("{d} FOLLOWING", .{n}),
    }
}

pub fn writeValue(writer: anytype, val: *const Value) !void {
    try writeValueWithContext(writer, val, null);
}

pub fn writeValueWithContext(writer: anytype, val: *const Value, cmd: ?*const QailCmd) !void {
    try val.validateFinite();
    switch (val.*) {
        .column => |column| try writeColumnReference(writer, column, cmd),
        .named_param => return error.UnresolvedNamedParameter,
        .function => |function| {
            if (!isSafeRawFunctionValue(function)) return error.UnsafeSqlFragment;
            try writer.writeAll(function);
        },
        .string, .uuid, .timestamp, .json => |text| {
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NullByte;
            try val.format(writer);
        },
        .array => |values| {
            try writer.writeAll("ARRAY[");
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValueWithContext(writer, &value, cmd);
            }
            try writer.writeByte(']');
        },
        else => try val.format(writer),
    }
}
