// PostgreSQL Transpiler
//
// Converts QAIL AST to PostgreSQL SQL strings.
// Used for debugging, logging, and EXPLAIN analysis.
//
// NOTE: This is NOT the primary execution path!
// The primary path is AST → Wire Protocol via ast_encoder.zig

const std = @import("std");
const io = @import("../compat/io.zig");
const commands = @import("postgres/commands.zig");
const render = @import("postgres/render.zig");
const ast = struct {
    pub const cmd = @import("../ast/cmd.zig");
    pub const expr = @import("../ast/expr.zig");
    pub const policy = @import("../ast/policy.zig");
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
        .truncate => try commands.writeTruncate(writer, cmd),
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
            if (policy.using_expr) |using_expr| {
                try writer.writeAll(" USING (");
                var expr = using_expr;
                try render.writeExpr(writer, &expr);
                try writer.writeByte(')');
            } else if (policy.using_sql) |using_sql| {
                try writer.writeAll(" USING (");
                try writer.writeAll(using_sql);
                try writer.writeByte(')');
            }
            if (policy.with_check_expr) |with_check_expr| {
                try writer.writeAll(" WITH CHECK (");
                var expr = with_check_expr;
                try render.writeExpr(writer, &expr);
                try writer.writeByte(')');
            } else if (policy.with_check_sql) |with_check_sql| {
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
