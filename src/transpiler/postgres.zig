// PostgreSQL Transpiler
//
// Converts QAIL AST to PostgreSQL SQL strings.
// Used for debugging, logging, and EXPLAIN analysis.
//
// NOTE: This is NOT the primary execution path!
// The primary path is AST → Wire Protocol via ast_encoder.zig

const std = @import("std");
const ast = struct {
    pub const cmd = @import("../ast/cmd.zig");
    pub const expr = @import("../ast/expr.zig");
    pub const values = @import("../ast/values.zig");
    pub const operators = @import("../ast/operators.zig");
    pub const QailCmd = cmd.QailCmd;
    pub const CmdKind = cmd.CmdKind;
    pub const Expr = expr.Expr;
    pub const Value = values.Value;
    pub const Operator = operators.Operator;
};

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Value = ast.Value;

/// Convert a QAIL AST command to PostgreSQL SQL string
/// NOTE: This is for debugging ONLY. Actual execution uses AST → Wire Protocol directly.
pub fn toSql(allocator: std.mem.Allocator, cmd: *const QailCmd) ![]const u8 {
    _ = cmd;
    // Zig 0.16 removed ArrayList.writer() - stub for now since this is debug-only
    const result = try allocator.dupe(u8, "-- SQL transpilation disabled in Zig 0.16");
    return result;
}

fn writeCmd(writer: anytype, cmd: *const QailCmd) !void {
    switch (cmd.kind) {
        .get => try writeSelect(writer, cmd),
        .set => try writeUpdate(writer, cmd),
        .del => try writeDelete(writer, cmd),
        .add => try writeInsert(writer, cmd),
        .truncate => try writeTruncate(writer, cmd),
        .listen => {
            try writer.writeAll("LISTEN ");
            if (cmd.channel) |ch| try writer.writeAll(ch);
        },
        .notify => {
            try writer.writeAll("NOTIFY ");
            if (cmd.channel) |ch| try writer.writeAll(ch);
            if (cmd.payload) |p| {
                try writer.writeAll(", '");
                try writer.writeAll(p);
                try writer.writeByte('\'');
            }
        },
        .unlisten => {
            try writer.writeAll("UNLISTEN ");
            if (cmd.channel) |ch| {
                try writer.writeAll(ch);
            } else {
                try writer.writeByte('*');
            }
        },
        .begin => try writer.writeAll("BEGIN"),
        .commit => try writer.writeAll("COMMIT"),
        .rollback => try writer.writeAll("ROLLBACK"),
        .savepoint => {
            try writer.writeAll("SAVEPOINT ");
            if (cmd.savepoint_name) |name| try writer.writeAll(name);
        },
        .release => {
            try writer.writeAll("RELEASE SAVEPOINT ");
            if (cmd.savepoint_name) |name| try writer.writeAll(name);
        },
        .rollback_to => {
            try writer.writeAll("ROLLBACK TO SAVEPOINT ");
            if (cmd.savepoint_name) |name| try writer.writeAll(name);
        },
        else => {},
    }
}

fn writeSelect(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("SELECT ");

    if (cmd.distinct) {
        try writer.writeAll("DISTINCT ");
    }

    // Columns
    if (cmd.columns.len == 0) {
        try writer.writeAll("*");
    } else {
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col);
        }
    }

    try writer.writeAll(" FROM ");
    try writer.writeAll(cmd.table);

    if (cmd.table_alias) |alias| {
        try writer.writeAll(" AS ");
        try writer.writeAll(alias);
    }

    // JOINs
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

    // WHERE
    if (cmd.where_clauses.len > 0) {
        try writer.writeAll(" WHERE ");
        for (cmd.where_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writer.writeAll(clause.condition.column);
            try writer.print(" {s} ", .{clause.condition.op.toSql()});
            try writeValue(writer, &clause.condition.value);
        }
    }

    // GROUP BY
    if (cmd.group_by.len > 0) {
        try writer.writeAll(" GROUP BY ");
        for (cmd.group_by, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(col);
        }
    }

    // HAVING
    if (cmd.having_clauses.len > 0) {
        try writer.writeAll(" HAVING ");
        for (cmd.having_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writer.writeAll(clause.condition.column);
            try writer.print(" {s} ", .{clause.condition.op.toSql()});
            try writeValue(writer, &clause.condition.value);
        }
    }

    // ORDER BY
    if (cmd.order_by.len > 0) {
        try writer.writeAll(" ORDER BY ");
        for (cmd.order_by, 0..) |order, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(order.column);
            try writer.print(" {s}", .{order.order.toSql()});
        }
    }

    // LIMIT
    if (cmd.limit_val) |limit| {
        try writer.print(" LIMIT {d}", .{limit});
    }

    // OFFSET
    if (cmd.offset_val) |offset| {
        try writer.print(" OFFSET {d}", .{offset});
    }

    // FOR UPDATE
    if (cmd.for_update) {
        try writer.writeAll(" FOR UPDATE");
    }
}

fn writeUpdate(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("UPDATE ");
    try writer.writeAll(cmd.table);
    try writer.writeAll(" SET ");

    for (cmd.assignments, 0..) |assign, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(assign.column);
        try writer.writeAll(" = ");
        try writeValue(writer, &assign.value);
    }

    if (cmd.where_clauses.len > 0) {
        try writer.writeAll(" WHERE ");
        for (cmd.where_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writer.writeAll(clause.condition.column);
            try writer.print(" {s} ", .{clause.condition.op.toSql()});
            try writeValue(writer, &clause.condition.value);
        }
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col);
        }
    }
}

fn writeDelete(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("DELETE FROM ");
    try writer.writeAll(cmd.table);

    if (cmd.where_clauses.len > 0) {
        try writer.writeAll(" WHERE ");
        for (cmd.where_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writer.writeAll(clause.condition.column);
            try writer.print(" {s} ", .{clause.condition.op.toSql()});
            try writeValue(writer, &clause.condition.value);
        }
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col);
        }
    }
}

fn writeInsert(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("INSERT INTO ");
    try writer.writeAll(cmd.table);

    if (cmd.assignments.len > 0) {
        try writer.writeAll(" (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(assign.column);
        }
        try writer.writeAll(") VALUES (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeValue(writer, &assign.value);
        }
        try writer.writeAll(")");
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col);
        }
    }
}

fn writeTruncate(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("TRUNCATE ");
    try writer.writeAll(cmd.table);
}

fn writeExpr(writer: anytype, expr: *const Expr) !void {
    switch (expr.*) {
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
        else => {},
    }
}

fn writeValue(writer: anytype, val: *const Value) !void {
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

// ==================== Tests ====================

test "transpile simple select" {
    const cols = [_]Expr{ Expr.col("id"), Expr.col("name") };
    const cmd = QailCmd.get("users").select(&cols).limit(10);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT id, name FROM users LIMIT 10", sql);
}

test "transpile select all" {
    const cmd = QailCmd.get("users");

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "transpile select distinct" {
    const cols = [_]Expr{Expr.col("status")};
    const cmd = QailCmd.get("orders").select(&cols).distinct_();

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT DISTINCT status FROM orders", sql);
}

test "transpile with aggregates" {
    const cols = [_]Expr{ Expr.count(), Expr.sum("amount") };
    const cmd = QailCmd.get("orders").select(&cols);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT COUNT(*), SUM(amount) FROM orders", sql);
}

test "transpile truncate" {
    const cmd = QailCmd.truncate("temp_data");

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("TRUNCATE temp_data", sql);
}
