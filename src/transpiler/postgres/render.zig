const std = @import("std");

const ast = struct {
    pub const cmd = @import("../../ast/cmd.zig");
    pub const expr = @import("../../ast/expr.zig");
    pub const values = @import("../../ast/values.zig");
};

const Expr = ast.expr.Expr;
const Value = ast.values.Value;

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
            try writeWhereCondition(writer, clause);
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
            try writeWhereCondition(writer, clause);
        }
        try writer.writeAll(")");
    }
}

fn writeWhereCondition(writer: anytype, clause: ast.cmd.WhereClause) !void {
    try writer.writeAll(clause.condition.column);
    try writer.print(" {s} ", .{clause.condition.op.toSql()});
    try writeValue(writer, &clause.condition.value);
}

pub fn writeExpr(writer: anytype, ex: *const Expr) !void {
    switch (ex.*) {
        .star => try writer.writeAll("*"),
        .named => |name| try writer.writeAll(name),
        .aliased => |a| {
            try writer.writeAll(a.name);
            try writer.writeAll(" AS ");
            try writer.writeAll(a.alias);
        },
        .aggregate => |agg| {
            try writer.writeAll(agg.func.toSql());
            try writer.writeAll("(");
            if (agg.distinct) try writer.writeAll("DISTINCT ");
            try writer.writeAll(agg.column);
            try writer.writeAll(")");
            if (agg.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        .literal => |val| try writeValue(writer, &val),
        .func_call => |fc| {
            try writer.writeAll(fc.name);
            try writer.writeAll("(");
            for (fc.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &arg);
            }
            try writer.writeAll(")");
            if (fc.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
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
                try writer.writeAll(alias);
            }
        },
        .cast => |c| {
            try writeExpr(writer, c.expr);
            try writer.writeAll("::");
            try writer.writeAll(c.target_type);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
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
                try writer.writeAll(seg.key);
                try writer.writeAll("'");
            }
            if (ja.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        else => {},
    }
}

pub fn writeValue(writer: anytype, val: *const Value) !void {
    switch (val.*) {
        .null => try writer.writeAll("NULL"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('\'');
            for (s) |c| {
                if (c == '\'') {
                    try writer.writeAll("''");
                } else {
                    try writer.writeByte(c);
                }
            }
            try writer.writeByte('\'');
        },
        .param => |p| try writer.print("${d}", .{p}),
        else => {},
    }
}
