const ast = struct {
    pub const cmd = @import("../../ast/cmd.zig");
    pub const QailCmd = cmd.QailCmd;
};

const QailCmd = ast.QailCmd;
const render = @import("render.zig");

pub fn writeSelect(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("SELECT ");

    if (cmd.distinct) {
        try writer.writeAll("DISTINCT ");
    }

    if (cmd.columns.len == 0) {
        try writer.writeAll("*");
    } else {
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }

    if (cmd.only_table) {
        try writer.writeAll(" FROM ONLY ");
    } else {
        try writer.writeAll(" FROM ");
    }
    try writer.writeAll(cmd.table);

    if (cmd.sample_method) |method| {
        try writer.print(" TABLESAMPLE {s}(", .{method.toSql()});
        if (cmd.sample_percent) |pct| {
            try writer.print("{d}", .{pct});
        }
        try writer.writeAll(")");
        if (cmd.sample_seed) |seed| {
            try writer.print(" REPEATABLE({d})", .{seed});
        }
    }

    if (cmd.table_alias) |alias| {
        try writer.writeAll(" AS ");
        try writer.writeAll(alias);
    }

    for (cmd.joins) |join| {
        try writer.print(" {s} ", .{join.kind.toSql()});
        try writer.writeAll(join.table);
        if (join.alias) |alias| {
            try writer.writeAll(" AS ");
            try writer.writeAll(alias);
        }
        try writer.writeAll(" ON ");
        try writer.writeAll(join.on_left);
        try writer.writeAll(" = ");
        try writer.writeAll(join.on_right);
    }

    try render.writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.group_by.len > 0) {
        try writer.writeAll(" GROUP BY ");
        for (cmd.group_by, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(col);
        }
    }

    if (cmd.having_clauses.len > 0) {
        try writer.writeAll(" HAVING ");
        for (cmd.having_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writer.writeAll(clause.condition.column);
            try writer.print(" {s} ", .{clause.condition.op.toSql()});
            try render.writeValue(writer, &clause.condition.value);
        }
    }

    if (cmd.order_by.len > 0) {
        try writer.writeAll(" ORDER BY ");
        for (cmd.order_by, 0..) |order, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(order.column);
            try writer.print(" {s}", .{order.order.toSql()});
        }
    }

    if (cmd.limit_val) |limit| {
        try writer.print(" LIMIT {d}", .{limit});
    }

    if (cmd.offset_val) |offset| {
        try writer.print(" OFFSET {d}", .{offset});
    }

    if (cmd.fetch_count) |count| {
        if (cmd.fetch_with_ties) {
            try writer.print(" FETCH FIRST {d} ROWS WITH TIES", .{count});
        } else {
            try writer.print(" FETCH FIRST {d} ROWS ONLY", .{count});
        }
    }

    if (cmd.lock_mode) |lock| {
        try writer.print(" {s}", .{lock.toSql()});
    }
}

pub fn writeUpdate(writer: anytype, cmd: *const QailCmd) !void {
    if (cmd.only_table) {
        try writer.writeAll("UPDATE ONLY ");
    } else {
        try writer.writeAll("UPDATE ");
    }
    try writer.writeAll(cmd.table);
    try writer.writeAll(" SET ");

    for (cmd.assignments, 0..) |assign, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(assign.column);
        try writer.writeAll(" = ");
        try render.writeValue(writer, &assign.value);
    }

    try render.writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

pub fn writeDelete(writer: anytype, cmd: *const QailCmd) !void {
    if (cmd.only_table) {
        try writer.writeAll("DELETE FROM ONLY ");
    } else {
        try writer.writeAll("DELETE FROM ");
    }
    try writer.writeAll(cmd.table);

    try render.writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

pub fn writeInsert(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("INSERT INTO ");
    try writer.writeAll(cmd.table);

    if (!cmd.default_values and cmd.assignments.len > 0) {
        try writer.writeAll(" (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(assign.column);
        }
        try writer.writeAll(")");
    }

    if (cmd.overriding) |ovr| {
        try writer.print(" {s}", .{ovr.toSql()});
    }

    if (cmd.default_values) {
        try writer.writeAll(" DEFAULT VALUES");
    } else if (cmd.assignments.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeValue(writer, &assign.value);
        }
        try writer.writeAll(")");
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

pub fn writeTruncate(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("TRUNCATE ");
    try writer.writeAll(cmd.table);
}
