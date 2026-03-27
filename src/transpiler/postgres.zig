// PostgreSQL Transpiler
//
// Converts QAIL AST to PostgreSQL SQL strings.
// Used for debugging, logging, and EXPLAIN analysis.
//
// NOTE: This is NOT the primary execution path!
// The primary path is AST → Wire Protocol via ast_encoder.zig

const std = @import("std");
const io = @import("../compat/io.zig");
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
pub fn toSql(allocator: std.mem.Allocator, cmd: *const QailCmd) ![]const u8 {
    var writer = io.AllocatingWriter.init(allocator);
    defer writer.deinit();

    try writeCmd(writer.writer(), cmd);

    return try writer.toOwnedSlice();
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
        .create_database => {
            try writer.writeAll("CREATE DATABASE ");
            try writer.writeAll(cmd.table);
        },
        .drop_database => {
            try writer.writeAll("DROP DATABASE IF EXISTS ");
            try writer.writeAll(cmd.table);
        },
        .grant => {
            const role = cmd.payload orelse return error.MissingGrantRole;
            if (cmd.privileges.len == 0) return error.MissingGrantPrivileges;
            if (cmd.table.len == 0) return error.MissingGrantObject;

            try writer.writeAll("GRANT ");
            for (cmd.privileges, 0..) |privilege, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(privilege);
            }
            try writer.writeAll(" ON ");
            try writer.writeAll(cmd.table);
            try writer.writeAll(" TO ");
            try writer.writeAll(role);
        },
        .revoke => {
            const role = cmd.payload orelse return error.MissingRevokeRole;
            if (cmd.privileges.len == 0) return error.MissingRevokePrivileges;
            if (cmd.table.len == 0) return error.MissingRevokeObject;

            try writer.writeAll("REVOKE ");
            for (cmd.privileges, 0..) |privilege, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(privilege);
            }
            try writer.writeAll(" ON ");
            try writer.writeAll(cmd.table);
            try writer.writeAll(" FROM ");
            try writer.writeAll(role);
        },
        .create_policy => {
            const policy = cmd.policy_def orelse return error.MissingPolicyDefinition;
            if (policy.name.len == 0) return error.MissingPolicyName;
            if (policy.table.len == 0) return error.MissingPolicyTable;

            try writer.writeAll("CREATE POLICY ");
            try writer.writeAll(policy.name);
            try writer.writeAll(" ON ");
            try writer.writeAll(policy.table);
            if (policy.permissiveness == .restrictive) {
                try writer.writeAll(" AS RESTRICTIVE");
            }
            try writer.writeAll(" FOR ");
            try writer.writeAll(policy.target.toSql());
            if (policy.role) |role| {
                try writer.writeAll(" TO ");
                try writer.writeAll(role);
            }
            if (policy.using_sql) |using_sql| {
                try writer.writeAll(" USING (");
                try writer.writeAll(using_sql);
                try writer.writeByte(')');
            }
            if (policy.with_check_sql) |with_check_sql| {
                try writer.writeAll(" WITH CHECK (");
                try writer.writeAll(with_check_sql);
                try writer.writeByte(')');
            }
        },
        .drop_policy => {
            const policy_name = if (cmd.policy_def) |policy|
                policy.name
            else
                cmd.payload orelse return error.MissingPolicyName;
            const policy_table = if (cmd.policy_def) |policy|
                policy.table
            else if (cmd.table.len > 0)
                cmd.table
            else
                return error.MissingPolicyTable;

            try writer.writeAll("DROP POLICY IF EXISTS ");
            try writer.writeAll(policy_name);
            try writer.writeAll(" ON ");
            try writer.writeAll(policy_table);
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

    // FROM with optional ONLY (inheritance control)
    if (cmd.only_table) {
        try writer.writeAll(" FROM ONLY ");
    } else {
        try writer.writeAll(" FROM ");
    }
    try writer.writeAll(cmd.table);

    // TABLESAMPLE
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
    try writeWhereClauses(writer, cmd.where_clauses);

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

    // FETCH (SQL standard alternative to LIMIT)
    if (cmd.fetch_count) |count| {
        if (cmd.fetch_with_ties) {
            try writer.print(" FETCH FIRST {d} ROWS WITH TIES", .{count});
        } else {
            try writer.print(" FETCH FIRST {d} ROWS ONLY", .{count});
        }
    }

    // FOR UPDATE/SHARE (row locking)
    if (cmd.lock_mode) |lock| {
        try writer.print(" {s}", .{lock.toSql()});
    }
}

fn writeUpdate(writer: anytype, cmd: *const QailCmd) !void {
    // UPDATE with optional ONLY
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
        try writeValue(writer, &assign.value);
    }

    try writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col);
        }
    }
}

fn writeDelete(writer: anytype, cmd: *const QailCmd) !void {
    // DELETE with optional ONLY
    if (cmd.only_table) {
        try writer.writeAll("DELETE FROM ONLY ");
    } else {
        try writer.writeAll("DELETE FROM ");
    }
    try writer.writeAll(cmd.table);

    try writeWhereClauses(writer, cmd.where_clauses);

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

    // Column list (if not using DEFAULT VALUES)
    if (!cmd.default_values and cmd.assignments.len > 0) {
        try writer.writeAll(" (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(assign.column);
        }
        try writer.writeAll(")");
    }

    // OVERRIDING clause
    if (cmd.overriding) |ovr| {
        try writer.print(" {s}", .{ovr.toSql()});
    }

    // DEFAULT VALUES or VALUES
    if (cmd.default_values) {
        try writer.writeAll(" DEFAULT VALUES");
    } else if (cmd.assignments.len > 0) {
        try writer.writeAll(" VALUES (");
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

fn writeWhereClauses(writer: anytype, clauses: []const ast.cmd.WhereClause) !void {
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

fn writeExpr(writer: anytype, ex: *const Expr) !void {
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

// ==================== Roundtrip Tests ====================

test "transpile insert with values" {
    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "name", .value = .{ .string = "Alice" } },
        .{ .column = "age", .value = .{ .int = 30 } },
    };
    const cmd = QailCmd.add("users").values(&assigns);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "INSERT INTO users (name, age) VALUES ('Alice', 30)",
        sql,
    );
}

test "transpile insert default values" {
    var cmd = QailCmd.add("events");
    cmd.default_values = true;

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("INSERT INTO events DEFAULT VALUES", sql);
}

test "transpile insert with returning" {
    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "name", .value = .{ .string = "Bob" } },
    };
    const ret = [_]Expr{Expr.col("id")};
    const cmd = QailCmd.add("users").values(&assigns).returningCols(&ret);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "INSERT INTO users (name) VALUES ('Bob') RETURNING id",
        sql,
    );
}

test "transpile update with where" {
    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "status", .value = .{ .string = "active" } },
    };
    const wheres = [_]ast.cmd.WhereClause{
        .{
            .condition = .{ .column = "id", .op = .eq, .value = .{ .int = 42 } },
        },
    };
    const cmd = QailCmd.set("users").values(&assigns).where(&wheres);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "UPDATE users SET status = 'active' WHERE id = 42",
        sql,
    );
}

test "transpile delete with where" {
    const wheres = [_]ast.cmd.WhereClause{
        .{
            .condition = .{ .column = "expired", .op = .eq, .value = .{ .bool = true } },
        },
    };
    const cmd = QailCmd.del("sessions").where(&wheres);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "DELETE FROM sessions WHERE expired = true",
        sql,
    );
}

test "transpile where groups and + or clauses like qail.rs or_filter semantics" {
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("is_active", .eq, .{ .bool = true }),
        ast.cmd.orFilter("topic", .ilike, .{ .string = "%test%" }),
        ast.cmd.orFilter("question", .ilike, .{ .string = "%test%" }),
    };
    const cmd = QailCmd.get("kb").where(&wheres);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT * FROM kb WHERE is_active = true AND (topic ILIKE '%test%' OR question ILIKE '%test%')",
        sql,
    );
}

test "transpile where supports pure or-filter groups" {
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.orFilter("name", .ilike, .{ .string = "%coffee%" }),
        ast.cmd.orFilter("description", .ilike, .{ .string = "%coffee%" }),
    };
    const cmd = QailCmd.get("products").where(&wheres);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT * FROM products WHERE (name ILIKE '%coffee%' OR description ILIKE '%coffee%')",
        sql,
    );
}

test "transpile select with join" {
    const cols = [_]Expr{ Expr.col("u.id"), Expr.col("o.total") };
    const joins = [_]ast.cmd.Join{
        .{ .kind = .inner, .table = "orders", .alias = "o", .on_left = "u.id", .on_right = "o.user_id" },
    };
    const cmd = QailCmd.get("users").select(&cols).alias("u").join(&joins);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT u.id, o.total FROM users AS u INNER JOIN orders AS o ON u.id = o.user_id",
        sql,
    );
}

test "transpile select with group by and having" {
    const cols = [_]Expr{ Expr.col("status"), Expr.count() };
    const groups = [_][]const u8{"status"};
    const having = [_]ast.cmd.WhereClause{
        .{ .condition = .{ .column = "COUNT(*)", .op = .gt, .value = .{ .int = 5 } } },
    };
    const cmd = QailCmd.get("orders").select(&cols).groupBy(&groups).havingClauses(&having);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT status, COUNT(*) FROM orders GROUP BY status HAVING COUNT(*) > 5",
        sql,
    );
}

test "transpile select with order by and offset" {
    const cols = [_]Expr{Expr.col("name")};
    const orders = [_]ast.cmd.OrderBy{
        .{ .column = "name", .order = .asc },
    };
    const cmd = QailCmd.get("users").select(&cols).orderBy(&orders).limit(20).offset(40);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT name FROM users ORDER BY name ASC LIMIT 20 OFFSET 40",
        sql,
    );
}

test "transpile transaction commands" {
    const begin = try toSql(std.testing.allocator, &QailCmd.beginTx());
    defer std.testing.allocator.free(begin);
    try std.testing.expectEqualStrings("BEGIN", begin);

    const commit = try toSql(std.testing.allocator, &QailCmd.commitTx());
    defer std.testing.allocator.free(commit);
    try std.testing.expectEqualStrings("COMMIT", commit);

    const rollback = try toSql(std.testing.allocator, &QailCmd.rollbackTx());
    defer std.testing.allocator.free(rollback);
    try std.testing.expectEqualStrings("ROLLBACK", rollback);
}

test "transpile listen notify" {
    const listen_cmd = QailCmd.listen("order_created");
    const sql = try toSql(std.testing.allocator, &listen_cmd);
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("LISTEN order_created", sql);

    const notify_cmd = QailCmd.notifyChannel("order_created", null);
    const sql2 = try toSql(std.testing.allocator, &notify_cmd);
    defer std.testing.allocator.free(sql2);
    try std.testing.expectEqualStrings("NOTIFY order_created", sql2);
}

test "transpile select with cast expression" {
    const inner = Expr.col("amount");
    const cols = [_]Expr{Expr{ .cast = .{ .expr = &inner, .target_type = "float8" } }};
    const cmd = QailCmd.get("orders").select(&cols);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT amount::float8 FROM orders", sql);
}

test "transpile string escaping" {
    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "name", .value = .{ .string = "O'Brien" } },
    };
    const cmd = QailCmd.add("users").values(&assigns);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "INSERT INTO users (name) VALUES ('O''Brien')",
        sql,
    );
}

test "transpile grant revoke and policy commands" {
    const privs = [_][]const u8{ "SELECT", "INSERT" };

    const grant_cmd = QailCmd.grant("users", &privs, "app_role");
    const grant_sql = try toSql(std.testing.allocator, &grant_cmd);
    defer std.testing.allocator.free(grant_sql);
    try std.testing.expectEqualStrings("GRANT SELECT, INSERT ON users TO app_role", grant_sql);

    const revoke_cmd = QailCmd.revoke("users", &privs, "app_role");
    const revoke_sql = try toSql(std.testing.allocator, &revoke_cmd);
    defer std.testing.allocator.free(revoke_sql);
    try std.testing.expectEqualStrings("REVOKE SELECT, INSERT ON users FROM app_role", revoke_sql);

    const policy = ast.cmd.PolicyDef{
        .name = "orders_tenant_isolation",
        .table = "orders",
        .target = .all,
        .permissiveness = .restrictive,
        .role = "app_user",
        .using_sql = "tenant_id = current_setting('app.tenant_id')::uuid",
        .with_check_sql = "tenant_id = current_setting('app.tenant_id')::uuid",
    };
    const create_policy_cmd = QailCmd.createPolicy(policy);
    const create_policy_sql = try toSql(std.testing.allocator, &create_policy_cmd);
    defer std.testing.allocator.free(create_policy_sql);
    try std.testing.expectEqualStrings(
        "CREATE POLICY orders_tenant_isolation ON orders AS RESTRICTIVE FOR ALL TO app_user USING (tenant_id = current_setting('app.tenant_id')::uuid) WITH CHECK (tenant_id = current_setting('app.tenant_id')::uuid)",
        create_policy_sql,
    );

    const drop_policy_cmd = QailCmd.dropPolicy("orders_tenant_isolation", "orders");
    const drop_policy_sql = try toSql(std.testing.allocator, &drop_policy_cmd);
    defer std.testing.allocator.free(drop_policy_sql);
    try std.testing.expectEqualStrings("DROP POLICY IF EXISTS orders_tenant_isolation ON orders", drop_policy_sql);
}
