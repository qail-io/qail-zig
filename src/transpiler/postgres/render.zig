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

pub fn writeCondition(writer: anytype, condition: *const ast.expr.Condition) !void {
    if (condition.column.len != 0) {
        try writer.writeAll(condition.column);
    } else {
        var left = condition.left;
        try writeExpr(writer, &left);
    }

    switch (condition.op) {
        .is_null, .is_not_null => try writer.print(" {s}", .{condition.op.toSql()}),
        else => {
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &condition.value);
        },
    }
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
                try writer.writeAll(alias);
            }
        },
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
        .case_expr => |c| {
            try writer.writeAll("CASE");
            for (c.when_clauses) |when_clause| {
                try writer.writeAll(" WHEN ");
                if (when_clause.condition.column.len != 0) {
                    try writer.writeAll(when_clause.condition.column);
                } else {
                    try writeExpr(writer, &when_clause.condition.left);
                }
                switch (when_clause.condition.op) {
                    .is_null, .is_not_null => try writer.print(" {s}", .{when_clause.condition.op.toSql()}),
                    else => {
                        try writer.print(" {s} ", .{when_clause.condition.op.toSql()});
                        try writeValue(writer, &when_clause.condition.value);
                    },
                }
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
                try writer.writeAll(alias);
            }
        },
        .subquery => |sq| {
            try writer.writeByte('(');
            try writer.writeAll(sq.sql);
            try writer.writeByte(')');
            if (sq.alias) |alias| {
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
        .array_constructor => |a| {
            try writer.writeAll("ARRAY[");
            for (a.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &elem);
            }
            try writer.writeByte(']');
            if (a.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
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
                try writer.writeAll(alias);
            }
        },
        .subscript => |s| {
            try writeExpr(writer, s.base);
            try writer.writeByte('[');
            try writeExpr(writer, s.index);
            try writer.writeByte(']');
            if (s.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        .collate => |c| {
            try writeExpr(writer, c.expr);
            try writer.writeAll(" COLLATE ");
            try writer.writeAll(c.collation);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        .field_access => |f| {
            try writer.writeByte('(');
            try writeExpr(writer, f.expr);
            try writer.writeAll(").");
            try writer.writeAll(f.field);
            if (f.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
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
                try writer.writeAll(alias);
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

pub fn writeValue(writer: anytype, val: *const Value) !void {
    try val.format(writer);
}
