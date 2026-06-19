// PostgreSQL Transpiler
//
// Converts QAIL AST to PostgreSQL SQL strings.
// Used for debugging, logging, and EXPLAIN analysis.
//
// NOTE: This is NOT the primary execution path!
// The primary path is AST → Wire Protocol via ast_encoder.zig

const std = @import("std");
const io = @import("../runtime/io.zig");
const sanitize = @import("../sanitize.zig");
const commands = @import("postgres/commands.zig");
const render = @import("postgres/render.zig");
const ast = struct {
    pub const cmd = @import("../ast/cmd.zig");
    pub const expr = @import("../ast/expr.zig");
    pub const policy = @import("../ast/policy.zig");
    pub const trusted_policy_sql = @import("../ast/trusted_policy_sql.zig");
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

/// Convert a QAIL AST command to PostgreSQL SQL string
pub fn toSql(allocator: std.mem.Allocator, cmd: *const QailCmd) ![]const u8 {
    if (sanitize.validateCmd(cmd)) |_| return error.UnsafeAst;
    return toSqlTrusted(allocator, cmd);
}

fn toSqlTrusted(allocator: std.mem.Allocator, cmd: *const QailCmd) ![]const u8 {
    var writer = io.AllocatingWriter.init(allocator);
    defer writer.deinit();

    try writeCmd(writer.writer(), cmd);

    return try writer.toOwnedSlice();
}

fn writeCmd(writer: anytype, cmd: *const QailCmd) !void {
    switch (cmd.kind) {
        .get => try commands.writeSelect(writer, cmd),
        .set => try commands.writeUpdate(writer, cmd),
        .del => try commands.writeDelete(writer, cmd),
        .add => try commands.writeInsert(writer, cmd),
        .merge => try commands.writeMerge(writer, cmd),
        .truncate => try commands.writeTruncate(writer, cmd),
        .alter_add_constraint => {
            const name = cmd.channel orelse return error.MissingConstraintName;
            const expr = cmd.payload orelse return error.MissingConstraintExpression;
            if (!isSafeSqlExprFragment(expr)) return error.UnsafeSqlFragment;

            try writer.writeAll("ALTER TABLE ");
            try render.writeIdentifierOrError(writer, cmd.table);
            try writer.writeAll(" ADD CONSTRAINT ");
            try render.writeIdentifierOrError(writer, name);
            try writer.writeAll(" CHECK (");
            try writer.writeAll(std.mem.trim(u8, expr, " \t\r\n"));
            try writer.writeByte(')');
        },
        .alter_drop_constraint => {
            const name = cmd.channel orelse return error.MissingConstraintName;
            try writer.writeAll("ALTER TABLE ");
            try render.writeIdentifierOrError(writer, cmd.table);
            try writer.writeAll(" DROP CONSTRAINT ");
            try render.writeIdentifierOrError(writer, name);
        },
        .listen => {
            try writer.writeAll("LISTEN ");
            if (cmd.channel) |ch| try render.writeSingleIdentifierOrError(writer, ch);
        },
        .notify => {
            try writer.writeAll("NOTIFY ");
            if (cmd.channel) |ch| try render.writeSingleIdentifierOrError(writer, ch);
            if (cmd.payload) |p| {
                try writer.writeAll(", '");
                try writeEscapedSqlString(writer, p);
                try writer.writeByte('\'');
            }
        },
        .unlisten => {
            try writer.writeAll("UNLISTEN ");
            if (cmd.channel) |ch| {
                try render.writeSingleIdentifierOrError(writer, ch);
            } else {
                try writer.writeByte('*');
            }
        },
        .begin => try writer.writeAll("BEGIN"),
        .commit => try writer.writeAll("COMMIT"),
        .rollback => try writer.writeAll("ROLLBACK"),
        .savepoint => {
            try writer.writeAll("SAVEPOINT ");
            if (cmd.savepoint_name) |name| try render.writeSingleIdentifierOrError(writer, name);
        },
        .release => {
            try writer.writeAll("RELEASE SAVEPOINT ");
            if (cmd.savepoint_name) |name| try render.writeSingleIdentifierOrError(writer, name);
        },
        .rollback_to => {
            try writer.writeAll("ROLLBACK TO SAVEPOINT ");
            if (cmd.savepoint_name) |name| try render.writeSingleIdentifierOrError(writer, name);
        },
        .create_database => {
            try writer.writeAll("CREATE DATABASE ");
            try render.writeSingleIdentifierOrError(writer, cmd.table);
        },
        .drop_database => {
            try writer.writeAll("DROP DATABASE IF EXISTS ");
            try render.writeSingleIdentifierOrError(writer, cmd.table);
        },
        .grant => {
            const role = cmd.payload orelse return error.MissingGrantRole;
            if (cmd.privileges.len == 0) return error.MissingGrantPrivileges;
            if (cmd.table.len == 0) return error.MissingGrantObject;

            try writer.writeAll("GRANT ");
            for (cmd.privileges, 0..) |privilege, i| {
                const canonical = checkedPrivilege(privilege) orelse return error.InvalidGrantPrivilege;
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(canonical);
            }
            try writer.writeAll(" ON ");
            try render.writeIdentifierOrError(writer, cmd.table);
            try writer.writeAll(" TO ");
            try render.writeSingleIdentifierOrError(writer, role);
        },
        .revoke => {
            const role = cmd.payload orelse return error.MissingRevokeRole;
            if (cmd.privileges.len == 0) return error.MissingRevokePrivileges;
            if (cmd.table.len == 0) return error.MissingRevokeObject;

            try writer.writeAll("REVOKE ");
            for (cmd.privileges, 0..) |privilege, i| {
                const canonical = checkedPrivilege(privilege) orelse return error.InvalidGrantPrivilege;
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(canonical);
            }
            try writer.writeAll(" ON ");
            try render.writeIdentifierOrError(writer, cmd.table);
            try writer.writeAll(" FROM ");
            try render.writeSingleIdentifierOrError(writer, role);
        },
        .create_policy => {
            const policy = cmd.policy_def orelse return error.MissingPolicyDefinition;
            if (policy.name.len == 0) return error.MissingPolicyName;
            if (policy.table.len == 0) return error.MissingPolicyTable;

            try writer.writeAll("CREATE POLICY ");
            try render.writeSingleIdentifierOrError(writer, policy.name);
            try writer.writeAll(" ON ");
            try render.writeIdentifierOrError(writer, policy.table);
            if (policy.permissiveness == .restrictive) {
                try writer.writeAll(" AS RESTRICTIVE");
            }
            try writer.writeAll(" FOR ");
            try writer.writeAll(policy.target.toSql());
            if (policy.role) |role| {
                try writer.writeAll(" TO ");
                try render.writeSingleIdentifierOrError(writer, role);
            }
            if (policy.using_expr) |using_expr| {
                try writer.writeAll(" USING (");
                var expr = using_expr;
                try render.writeExpr(writer, &expr);
                try writer.writeByte(')');
            }
            if (policy.with_check_expr) |with_check_expr| {
                try writer.writeAll(" WITH CHECK (");
                var expr = with_check_expr;
                try render.writeExpr(writer, &expr);
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
            try render.writeSingleIdentifierOrError(writer, policy_name);
            try writer.writeAll(" ON ");
            try render.writeIdentifierOrError(writer, policy_table);
        },
        else => {},
    }
}

fn writeIdentifierMaybeQuoted(writer: anytype, ident: []const u8) !void {
    const needs_quotes = blk: {
        if (ident.len == 0) break :blk true;
        if (std.ascii.isDigit(ident[0])) break :blk true;
        for (ident) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk true;
        }
        break :blk false;
    };

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

fn isSafeSqlExprFragment(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len != 0 and !containsUnquotedStatementDelimiter(trimmed);
}

fn checkedPrivilege(privilege: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, privilege, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "SELECT")) return "SELECT";
    if (std.ascii.eqlIgnoreCase(trimmed, "INSERT")) return "INSERT";
    if (std.ascii.eqlIgnoreCase(trimmed, "UPDATE")) return "UPDATE";
    if (std.ascii.eqlIgnoreCase(trimmed, "DELETE")) return "DELETE";
    if (std.ascii.eqlIgnoreCase(trimmed, "TRUNCATE")) return "TRUNCATE";
    if (std.ascii.eqlIgnoreCase(trimmed, "REFERENCES")) return "REFERENCES";
    if (std.ascii.eqlIgnoreCase(trimmed, "TRIGGER")) return "TRIGGER";
    if (std.ascii.eqlIgnoreCase(trimmed, "USAGE")) return "USAGE";
    if (std.ascii.eqlIgnoreCase(trimmed, "CREATE")) return "CREATE";
    if (std.ascii.eqlIgnoreCase(trimmed, "CONNECT")) return "CONNECT";
    if (std.ascii.eqlIgnoreCase(trimmed, "TEMP") or
        std.ascii.eqlIgnoreCase(trimmed, "TEMPORARY")) return "TEMPORARY";
    if (std.ascii.eqlIgnoreCase(trimmed, "EXECUTE")) return "EXECUTE";
    if (std.ascii.eqlIgnoreCase(trimmed, "ALL") or
        std.ascii.eqlIgnoreCase(trimmed, "ALL PRIVILEGES")) return "ALL PRIVILEGES";
    return null;
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

test "transpile select skip locked requires row lock" {
    const invalid = QailCmd.get("jobs").skipLocked();
    try std.testing.expectError(error.SkipLockedRequiresLockMode, toSql(std.testing.allocator, &invalid));

    const valid = QailCmd.get("jobs").forUpdate().skipLocked();
    const sql = try toSql(std.testing.allocator, &valid);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM jobs FOR UPDATE SKIP LOCKED", sql);
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

    const sql = try toSqlTrusted(std.testing.allocator, &cmd);
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

test "transpile create and drop database quote hyphenated names" {
    const create_cmd = QailCmd.createDatabase("qail-engine-db_shadow");
    const create_sql = try toSqlTrusted(std.testing.allocator, &create_cmd);
    defer std.testing.allocator.free(create_sql);
    try std.testing.expectEqualStrings("CREATE DATABASE \"qail-engine-db_shadow\"", create_sql);

    const drop_cmd = QailCmd.dropDatabase("qail-engine-db_shadow");
    const drop_sql = try toSqlTrusted(std.testing.allocator, &drop_cmd);
    defer std.testing.allocator.free(drop_sql);
    try std.testing.expectEqualStrings("DROP DATABASE IF EXISTS \"qail-engine-db_shadow\"", drop_sql);
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

    const notify_payload_cmd = QailCmd.notifyChannel("order_created", "x'); DROP TABLE users; --");
    const sql3 = try toSql(std.testing.allocator, &notify_payload_cmd);
    defer std.testing.allocator.free(sql3);
    try std.testing.expectEqualStrings("NOTIFY order_created, 'x''); DROP TABLE users; --'", sql3);
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

test "transpile condition shape operators" {
    const roles = [_]ast.Value{ .{ .string = "admin" }, .{ .string = "user" } };
    const wheres = [_]ast.cmd.WhereClause{
        .{
            .condition = .{
                .column = "role",
                .op = .in,
                .value = .{ .array = &roles },
            },
        },
        .{
            .condition = .{
                .column = "age",
                .op = .between,
                .value = .{ .range = .{ .low = 18, .high = 65 } },
            },
        },
    };
    const cmd = QailCmd.get("users").where(&wheres);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE role IN ('admin', 'user') AND age BETWEEN 18 AND 65",
        sql,
    );
}

test "transpile in parameter uses array operator" {
    const wheres = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .in,
            .value = .{ .param = 1 },
        },
    }};
    const cmd = QailCmd.get("users").where(&wheres);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = ANY($1)", sql);
}

test "public transpiler rejects malformed condition shapes" {
    const empty = [_]ast.Value{};
    const empty_in = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "role",
            .op = .not_in,
            .value = .{ .array = &empty },
        },
    }};
    const empty_in_cmd = QailCmd.get("users").where(&empty_in);
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &empty_in_cmd));

    const one = [_]ast.Value{.{ .int = 18 }};
    const bad_between = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "age",
            .op = .between,
            .value = .{ .array = &one },
        },
    }};
    const bad_between_cmd = QailCmd.get("users").where(&bad_between);
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &bad_between_cmd));

    const bad_exists = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .exists,
            .value = .{ .int = 1 },
        },
    }};
    const bad_exists_cmd = QailCmd.get("users").where(&bad_exists);
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &bad_exists_cmd));
}

test "trusted transpiler expression fragments fail closed" {
    const name = Expr.col("name");
    const bad_function_cols = [_]Expr{.{ .func_call = .{
        .name = "lower); DROP TABLE users; --",
        .args = &[_]Expr{name},
    } }};
    const bad_function_cmd = QailCmd.get("users").select(&bad_function_cols);
    const bad_function_sql = try toSqlTrusted(std.testing.allocator, &bad_function_cmd);
    defer std.testing.allocator.free(bad_function_sql);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid function name */ FROM users",
        bad_function_sql,
    );

    const bad_cast_cols = [_]Expr{.{ .cast = .{
        .expr = &name,
        .target_type = "text); DROP TABLE users; --",
    } }};
    const bad_cast_cmd = QailCmd.get("users").select(&bad_cast_cols);
    const bad_cast_sql = try toSqlTrusted(std.testing.allocator, &bad_cast_cmd);
    defer std.testing.allocator.free(bad_cast_sql);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid cast target type */ FROM users",
        bad_cast_sql,
    );

    const raw_cols = [_]Expr{.{ .raw = "pg_sleep(1); DROP TABLE users; --" }};
    const raw_cmd = QailCmd.get("users").select(&raw_cols);
    const raw_sql = try toSqlTrusted(std.testing.allocator, &raw_cmd);
    defer std.testing.allocator.free(raw_sql);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid raw SQL fragment */ FROM users",
        raw_sql,
    );

    const safe_subquery_cols = [_]Expr{.{ .subquery = .{
        .sql = "SELECT count(*) FROM pg_class",
        .alias = "class_count",
    } }};
    const safe_subquery_cmd = QailCmd.get("users").select(&safe_subquery_cols);
    const safe_subquery_sql = try toSqlTrusted(std.testing.allocator, &safe_subquery_cmd);
    defer std.testing.allocator.free(safe_subquery_sql);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT count(*) FROM pg_class) AS class_count FROM users",
        safe_subquery_sql,
    );

    const subquery_cols = [_]Expr{.{ .subquery = .{
        .sql = "SELECT 1; DROP TABLE users; --",
        .alias = "safe_alias",
    } }};
    const subquery_cmd = QailCmd.get("users").select(&subquery_cols);
    const subquery_sql = try toSqlTrusted(std.testing.allocator, &subquery_cmd);
    defer std.testing.allocator.free(subquery_sql);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT NULL WHERE FALSE) AS safe_alias FROM users",
        subquery_sql,
    );

    const mutating_subquery_cols = [_]Expr{.{ .subquery = .{
        .sql = "DELETE FROM users RETURNING id",
        .alias = "deleted_id",
    } }};
    const mutating_subquery_cmd = QailCmd.get("users").select(&mutating_subquery_cols);
    const mutating_subquery_sql = try toSqlTrusted(std.testing.allocator, &mutating_subquery_cmd);
    defer std.testing.allocator.free(mutating_subquery_sql);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT NULL WHERE FALSE) AS deleted_id FROM users",
        mutating_subquery_sql,
    );

    const exists_cols = [_]Expr{.{ .exists_subquery = .{
        .sql = "SELECT 1; DROP TABLE users; --",
        .alias = "safe_exists",
    } }};
    const exists_cmd = QailCmd.get("users").select(&exists_cols);
    const exists_sql = try toSqlTrusted(std.testing.allocator, &exists_cmd);
    defer std.testing.allocator.free(exists_sql);
    try std.testing.expectEqualStrings(
        "SELECT EXISTS (SELECT NULL WHERE FALSE) AS safe_exists FROM users",
        exists_sql,
    );

    const mutating_cte_exists_cols = [_]Expr{.{ .exists_subquery = .{
        .sql = "WITH deleted AS (DELETE FROM users RETURNING id) SELECT id FROM deleted",
        .alias = "safe_cte",
    } }};
    const mutating_cte_exists_cmd = QailCmd.get("users").select(&mutating_cte_exists_cols);
    const mutating_cte_exists_sql = try toSqlTrusted(std.testing.allocator, &mutating_cte_exists_cmd);
    defer std.testing.allocator.free(mutating_cte_exists_sql);
    try std.testing.expectEqualStrings(
        "SELECT EXISTS (SELECT NULL WHERE FALSE) AS safe_cte FROM users",
        mutating_cte_exists_sql,
    );
}

test "trusted transpiler hardens mutation target identifiers" {
    const assignments = [_]ast.cmd.Assignment{.{
        .column = "name; DROP TABLE users; --",
        .value = .{ .string = "Alice" },
    }};

    const update_cmd = QailCmd.set("users").values(&assignments);
    const update_sql = try toSqlTrusted(std.testing.allocator, &update_cmd);
    defer std.testing.allocator.free(update_sql);
    try std.testing.expectEqualStrings(
        "UPDATE users SET \"name; DROP TABLE users; --\" = 'Alice'",
        update_sql,
    );

    const insert_cmd = QailCmd.add("users").values(&assignments);
    const insert_sql = try toSqlTrusted(std.testing.allocator, &insert_cmd);
    defer std.testing.allocator.free(insert_sql);
    try std.testing.expectEqualStrings(
        "INSERT INTO users (\"name; DROP TABLE users; --\") VALUES ('Alice')",
        insert_sql,
    );
}

test "trusted transpiler quotes expression identifiers and escapes json paths" {
    const name = Expr.col("name");
    const profile = Expr.col("profile");
    const cols = [_]Expr{
        Expr.col("name; DROP TABLE users; --"),
        Expr.colAs("email; DROP TABLE users; --", "safe_alias"),
        .{ .aggregate = .{ .func = .sum, .column = "amount; DROP TABLE users; --" } },
        .{ .json_access = .{
            .column = "data; DROP TABLE users; --",
            .path = &[_]ast.expr.JsonPathSegment{.{ .key = "a' || pg_sleep(1) --", .as_text = true }},
        } },
        .{ .collate = .{
            .expr = &name,
            .collation = "C\"; DROP TABLE users; --",
        } },
        .{ .field_access = .{
            .expr = &profile,
            .field = "field; DROP TABLE users; --",
        } },
    };
    const cmd = QailCmd.get("users").select(&cols);
    const sql = try toSqlTrusted(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "\"name; DROP TABLE users; --\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"email; DROP TABLE users; --\" AS safe_alias") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SUM(\"amount; DROP TABLE users; --\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"data; DROP TABLE users; --\"->>'a'' || pg_sleep(1) --'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "COLLATE \"C\"\"; DROP TABLE users; --\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, ").\"field; DROP TABLE users; --\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT name; DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SUM(amount; DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "COLLATE \"C\"; DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, ").field; DROP") == null);
}

test "trusted transpiler hardens window expressions" {
    const bad_window_cols = [_]Expr{.{ .window = .{
        .name = "rn",
        .func = "row_number); DROP TABLE users; --",
    } }};
    const bad_window_cmd = QailCmd.get("users").select(&bad_window_cols);
    const bad_window_sql = try toSqlTrusted(std.testing.allocator, &bad_window_cmd);
    defer std.testing.allocator.free(bad_window_sql);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid window function name */ FROM users",
        bad_window_sql,
    );

    const window_cols = [_]Expr{.{ .window = .{
        .name = "rn",
        .func = "row_number",
        .partition = &.{"tenant.id"},
        .order = &[_]ast.expr.OrderByExpr{.{ .column = "name\"; DROP TABLE users; --" }},
    } }};
    const window_cmd = QailCmd.get("users").select(&window_cols);
    const window_sql = try toSqlTrusted(std.testing.allocator, &window_cmd);
    defer std.testing.allocator.free(window_sql);
    try std.testing.expectEqualStrings(
        "SELECT row_number() OVER (PARTITION BY tenant.id ORDER BY \"name\"\"; DROP TABLE users; --\" ASC) AS rn FROM users",
        window_sql,
    );
}

test "public transpiler rejects unsafe ast" {
    const unsafe_table = QailCmd.get("users; DROP TABLE users");
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &unsafe_table));

    var raw_default = QailCmd{
        .kind = .alter_set_default,
        .table = "users",
        .columns = &.{Expr.col("role")},
        .payload = "current_user; DROP TABLE users",
    };
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &raw_default));

    const policy = ast.trusted_policy_sql.usingSql(
        ast.cmd.PolicyDef.create("tenant_only", "users"),
        "tenant_id = current_setting('app.tenant_id')::uuid",
    );
    const trusted_policy = QailCmd.createPolicy(policy);
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &trusted_policy));
}

test "trusted transpiler quotes command identifiers defensively" {
    const select_cmd = QailCmd.get("users; DROP TABLE users; --");
    const select_sql = try toSqlTrusted(std.testing.allocator, &select_cmd);
    defer std.testing.allocator.free(select_sql);
    try std.testing.expectEqualStrings(
        "SELECT * FROM \"users; DROP TABLE users; --\"",
        select_sql,
    );

    const notify_cmd = QailCmd.notifyChannel("events; DROP TABLE users; --", "ok");
    const notify_sql = try toSqlTrusted(std.testing.allocator, &notify_cmd);
    defer std.testing.allocator.free(notify_sql);
    try std.testing.expectEqualStrings(
        "NOTIFY \"events; DROP TABLE users; --\", 'ok'",
        notify_sql,
    );

    const savepoint_cmd = QailCmd.savepoint("sp; DROP TABLE users; --");
    const savepoint_sql = try toSqlTrusted(std.testing.allocator, &savepoint_cmd);
    defer std.testing.allocator.free(savepoint_sql);
    try std.testing.expectEqualStrings(
        "SAVEPOINT \"sp; DROP TABLE users; --\"",
        savepoint_sql,
    );

    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = ast.cmd.PolicyDef.create(
        "tenant; DROP TABLE users; --",
        "orders; DROP TABLE orders; --",
    )
        .toRole("app; DROP ROLE app; --")
        .usingExpr(predicate);
    const policy_cmd = QailCmd.createPolicy(policy);
    const policy_sql = try toSqlTrusted(std.testing.allocator, &policy_cmd);
    defer std.testing.allocator.free(policy_sql);
    try std.testing.expectEqualStrings(
        "CREATE POLICY \"tenant; DROP TABLE users; --\" ON \"orders; DROP TABLE orders; --\" FOR ALL TO \"app; DROP ROLE app; --\" USING (tenant_id = 42)",
        policy_sql,
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

    const canonical_privs = [_][]const u8{ "select", "all privileges", "temp" };
    const canonical_grant = QailCmd.grant("users", &canonical_privs, "app_role");
    const canonical_sql = try toSql(std.testing.allocator, &canonical_grant);
    defer std.testing.allocator.free(canonical_sql);
    try std.testing.expectEqualStrings("GRANT SELECT, ALL PRIVILEGES, TEMPORARY ON users TO app_role", canonical_sql);

    const qualified_grant = QailCmd.grant("public.users", &privs, "app_role");
    const qualified_sql = try toSql(std.testing.allocator, &qualified_grant);
    defer std.testing.allocator.free(qualified_sql);
    try std.testing.expectEqualStrings("GRANT SELECT, INSERT ON public.users TO app_role", qualified_sql);

    const bad_privs = [_][]const u8{"SELECT; DROP TABLE users; --"};
    const bad_grant = QailCmd.grant("users", &bad_privs, "app_role");
    try std.testing.expectError(error.UnsafeAst, toSql(std.testing.allocator, &bad_grant));

    const policy = ast.trusted_policy_sql.usingAndCheckSql(
        ast.cmd.PolicyDef.create("orders_tenant_isolation", "orders")
            .restrictive()
            .toRole("app_user"),
        "tenant_id = current_setting('app.tenant_id')::uuid",
        "tenant_id = current_setting('app.tenant_id')::uuid",
    );
    const create_policy_cmd = QailCmd.createPolicy(policy);
    const create_policy_sql = try toSqlTrusted(std.testing.allocator, &create_policy_cmd);
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

test "transpile typed policy predicates" {
    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = ast.cmd.PolicyDef.create("orders_tenant_isolation", "orders")
        .restrictive()
        .toRole("app_user")
        .usingExpr(predicate)
        .withCheckExpr(predicate);
    const cmd = QailCmd.createPolicy(policy);

    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "CREATE POLICY orders_tenant_isolation ON orders AS RESTRICTIVE FOR ALL TO app_user USING (tenant_id = 42) WITH CHECK (tenant_id = 42)",
        sql,
    );
}

test "transpile owned policy definition helpers" {
    var policy = try ast.policy.OwnedPolicyDef.create(std.testing.allocator, "orders_tenant_isolation", "orders");
    defer policy.deinit();

    _ = try policy
        .restrictive()
        .toRole("app_user");
    _ = try policy.usingTenantCheck("tenant_id", "app.current_tenant_id", "uuid");
    _ = try policy.withCheckTenantCheck("tenant_id", "app.current_tenant_id", "uuid");

    const cmd = policy.cmd();
    const sql = try toSql(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "CREATE POLICY orders_tenant_isolation ON orders AS RESTRICTIVE FOR ALL TO app_user USING (tenant_id = current_setting('app.current_tenant_id')::uuid) WITH CHECK (tenant_id = current_setting('app.current_tenant_id')::uuid)",
        sql,
    );
}
