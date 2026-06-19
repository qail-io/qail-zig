const std = @import("std");

const ast = struct {
    pub const cmd = @import("../../ast/cmd.zig");
    pub const expr = @import("../../ast/expr.zig");
    pub const values = @import("../../ast/values.zig");
};

const Expr = ast.expr.Expr;
const Value = ast.values.Value;
const WindowExpr = @TypeOf(@as(Expr, undefined).window);

const INVALID_EXISTS_CONDITION =
    "FALSE /* ERROR: EXISTS condition requires subquery value */";
const INVALID_IN_CONDITION =
    "FALSE /* ERROR: IN condition requires a non-empty array, subquery, or array parameter */";
const INVALID_BETWEEN_CONDITION =
    "FALSE /* ERROR: BETWEEN condition requires exactly two array values */";
const INVALID_FUNCTION_NAME = "/* ERROR: Invalid function name */";
const INVALID_WINDOW_FUNCTION_NAME = "/* ERROR: Invalid window function name */";
const INVALID_CAST_TARGET = "/* ERROR: Invalid cast target type */";
const INVALID_IDENTIFIER = "/* ERROR: Invalid identifier */";
const INVALID_INSERT_COLUMN = "/* ERROR: Invalid insert column */";

pub fn writeWhereClauses(writer: anytype, clauses: []const ast.cmd.WhereClause) !void {
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
            try writeCondition(writer, &clause.condition);
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
            try writeCondition(writer, &clause.condition);
        }
        try writer.writeAll(")");
    }
}

pub fn writeCondition(writer: anytype, condition: *const ast.expr.Condition) anyerror!void {
    switch (condition.op) {
        .in, .not_in => return writeInCondition(writer, condition),
        .between, .not_between => return writeBetweenCondition(writer, condition),
        .exists, .not_exists => return writer.writeAll(INVALID_EXISTS_CONDITION),
        else => {},
    }

    try writeConditionLeft(writer, condition);

    switch (condition.op) {
        .is_null, .is_not_null => try writer.print(" {s}", .{condition.op.toSql()}),
        else => {
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &condition.value);
        },
    }
}

fn writeConditionLeft(writer: anytype, condition: *const ast.expr.Condition) anyerror!void {
    if (condition.column.len != 0) {
        try writer.writeAll(condition.column);
    } else {
        var left = condition.left;
        try writeExpr(writer, &left);
    }
}

fn writeInCondition(writer: anytype, condition: *const ast.expr.Condition) !void {
    switch (condition.value) {
        .array => |values| {
            if (values.len == 0) return writer.writeAll(INVALID_IN_CONDITION);

            try writeConditionLeft(writer, condition);
            try writer.print(" {s} (", .{condition.op.toSql()});
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(writer, &value);
            }
            try writer.writeByte(')');
        },
        .param, .named_param => {
            try writeConditionLeft(writer, condition);
            try writer.writeAll(if (condition.op == .in) " = ANY(" else " != ALL(");
            try writeValue(writer, &condition.value);
            try writer.writeByte(')');
        },
        else => try writer.writeAll(INVALID_IN_CONDITION),
    }
}

fn writeBetweenCondition(writer: anytype, condition: *const ast.expr.Condition) !void {
    switch (condition.value) {
        .range => |range| {
            try writeConditionLeft(writer, condition);
            try writer.print(" {s} {d} AND {d}", .{ condition.op.toSql(), range.low, range.high });
        },
        .array => |values| {
            if (values.len != 2) return writer.writeAll(INVALID_BETWEEN_CONDITION);

            try writeConditionLeft(writer, condition);
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &values[0]);
            try writer.writeAll(" AND ");
            try writeValue(writer, &values[1]);
        },
        else => try writer.writeAll(INVALID_BETWEEN_CONDITION),
    }
}

pub fn writeExpr(writer: anytype, ex: *const Expr) anyerror!void {
    switch (ex.*) {
        .star => try writer.writeAll("*"),
        .named => |name| try writer.writeAll(name),
        .aliased => |a| {
            try writer.writeAll(a.name);
            try writer.writeAll(" AS ");
            try writeIdentifierMaybeQuoted(writer, a.alias);
        },
        .aggregate => |agg| {
            try writer.writeAll(agg.func.toSql());
            try writer.writeAll("(");
            if (agg.distinct) try writer.writeAll("DISTINCT ");
            try writer.writeAll(agg.column);
            try writer.writeAll(")");
            if (agg.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .literal => |val| try writeValue(writer, &val),
        .binary => |b| {
            try writeExpr(writer, b.left);
            switch (b.op) {
                .is_null, .is_not_null => try writer.print(" {s}", .{b.op.toSql()}),
                else => {
                    try writer.print(" {s} ", .{b.op.toSql()});
                    try writeExpr(writer, b.right);
                },
            }
            if (b.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .func_call => |fc| {
            if (!isSafeFunctionName(fc.name)) {
                try writer.writeAll(INVALID_FUNCTION_NAME);
                return;
            }
            try writer.writeAll(fc.name);
            try writer.writeAll("(");
            for (fc.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &arg);
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
                try writeCondition(writer, &when_clause.condition);
                try writer.writeAll(" THEN ");
                try writeExpr(writer, &when_clause.result);
            }
            if (c.else_value) |else_expr| {
                try writer.writeAll(" ELSE ");
                try writeExpr(writer, else_expr);
            }
            try writer.writeAll(" END");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subquery => |sq| {
            try writer.writeByte('(');
            try writer.writeAll(sq.sql);
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
                try writeExpr(writer, &ex_inner);
            }
            try writer.writeAll(")");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .cast => |c| {
            const target_type = checkedSqlTypeFragment(c.target_type) orelse {
                try writer.writeAll(INVALID_CAST_TARGET);
                return;
            };
            try writeExpr(writer, c.expr);
            try writer.writeAll("::");
            try writer.writeAll(target_type);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .json_access => |ja| {
            try writer.writeAll(ja.column);
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
                try writeExpr(writer, &elem);
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
                try writeExpr(writer, &elem);
            }
            try writer.writeByte(')');
            if (r.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subscript => |s| {
            try writeExpr(writer, s.base);
            try writer.writeByte('[');
            try writeExpr(writer, s.index);
            try writer.writeByte(']');
            if (s.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .collate => |c| {
            try writeExpr(writer, c.expr);
            try writer.writeAll(" COLLATE ");
            try writeIdentifierOrError(writer, c.collation);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .field_access => |f| {
            try writer.writeByte('(');
            try writeExpr(writer, f.expr);
            try writer.writeAll(").");
            try writeIdentifierOrError(writer, f.field);
            if (f.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .window => |w| try writeWindowExpr(writer, w),
        .exists_subquery => |sq| {
            if (sq.negated) {
                try writer.writeAll("NOT EXISTS (");
            } else {
                try writer.writeAll("EXISTS (");
            }
            try writer.writeAll(sq.sql);
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
            try writeExpr(writer, u.operand);
        },
        .raw => |raw| try writer.writeAll(raw),
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

fn isValidQualifiedIdentifier(value: []const u8) bool {
    return value.len != 0 and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !std.mem.startsWith(u8, value, ".") and
        !std.mem.endsWith(u8, value, ".") and
        std.mem.indexOf(u8, value, "..") == null;
}

pub fn writeIdentifierOrError(writer: anytype, value: []const u8) !void {
    if (!isValidQualifiedIdentifier(value)) {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    }

    var parts = std.mem.splitScalar(u8, value, '.');
    var first = true;
    while (parts.next()) |part| {
        if (!first) try writer.writeByte('.');
        first = false;
        try writeIdentifierMaybeQuoted(writer, part);
    }
}

pub fn writeInsertTargetColumn(writer: anytype, ex: *const Expr) !void {
    switch (ex.*) {
        .named => |name| try writeIdentifierOrError(writer, name),
        else => try writer.writeAll(INVALID_INSERT_COLUMN),
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

fn writeWindowExpr(writer: anytype, w: WindowExpr) !void {
    if (!isSafeFunctionName(w.func)) {
        try writer.writeAll(INVALID_WINDOW_FUNCTION_NAME);
        return;
    }

    try writer.writeAll(w.func);
    try writer.writeAll("() OVER (");
    if (w.partition.len > 0) {
        try writer.writeAll("PARTITION BY ");
        for (w.partition, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeIdentifierOrError(writer, col);
        }
    }
    if (w.order.len > 0) {
        if (w.partition.len > 0) try writer.writeByte(' ');
        try writer.writeAll("ORDER BY ");
        for (w.order, 0..) |o, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeIdentifierOrError(writer, o.column);
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
    try val.format(writer);
}
