const std = @import("std");
const sanitize = @import("../sanitize.zig");
const ast = @import("../ast/mod.zig");
const raw_cmd = @import("../ast/raw_cmd.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const validateCmd = sanitize.validateCmd;

test "sanitize: valid simple query passes" {
    const cmd = QailCmd.get("users").select(&.{ Expr.col("id"), Expr.col("name") });
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: table injection rejected" {
    const cmd = QailCmd.get("users; DROP TABLE users");
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("table", err.field);
}

test "sanitize: column injection rejected" {
    const cmd = QailCmd.get("users").select(&.{Expr.col("name; DROP TABLE x")});
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("columns", err.field);
}

test "sanitize: raw sql rejected" {
    const cmd = raw_cmd.command("SELECT 1");
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("command", err.field);
}

test "sanitize: session set rejected" {
    var cmd = QailCmd.get("users");
    cmd.kind = .session_set;
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("command", err.field);
}

test "sanitize: long identifier rejected" {
    var name_buf: [64]u8 = undefined;
    @memset(name_buf[0..], 'a');
    const cmd = QailCmd.get(name_buf[0..]);
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("table", err.field);
}

test "sanitize: typed source query passes" {
    const source = QailCmd.get("users").select(&.{Expr.col("id")});
    const cmd = QailCmd.createViewFromQuery("user_ids", &source);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed cte query passes" {
    const source = QailCmd.get("orders").select(&.{Expr.col("user_id")});
    const ctes = [_]ast.CTEDef{ast.CTEDef.fromQuery("active_orders", &source)};
    const cmd = QailCmd.get("active_orders").withCtes(&ctes);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed recursive cte query passes" {
    const base = QailCmd.get("users").select(&.{Expr.col("id")});
    const recursive = QailCmd.get("active_users").select(&.{Expr.col("id")});
    const ctes = [_]ast.CTEDef{
        ast.CTEDef.fromQuery("active_users", &base).recursiveUnionAll(&recursive).fromSourceTable("users"),
    };
    const cmd = QailCmd.get("active_users").withCtes(&ctes);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed set op query passes" {
    const rhs = QailCmd.get("admins").select(&.{Expr.col("id")});
    const set_ops = [_]ast.SetOpDef{ast.SetOpDef.fromQuery(.union_all, &rhs)};
    const cmd = QailCmd.get("users").withSetOps(&set_ops);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed policy predicates pass" {
    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = ast.PolicyDef.create("tenant_only", "orders")
        .restrictive()
        .toRole("app_user")
        .usingExpr(predicate)
        .withCheckExpr(predicate);
    const cmd = QailCmd.createPolicy(policy);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: notify payload is data" {
    const cmd = QailCmd.notifyChannel("events", "x'); DROP TABLE users; --");
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: grant role payload is an identifier" {
    const privs = [_][]const u8{"SELECT"};
    const cmd = QailCmd.grant("users", &privs, "app_role; DROP ROLE app_role");
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("role", err.field);
}

test "sanitize: raw default payload rejected" {
    var cmd = QailCmd{
        .kind = .alter_set_default,
        .table = "users",
        .columns = &.{Expr.col("role")},
        .payload = "current_user; DROP TABLE users",
    };
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("payload", err.field);
}

test "sanitize: unsafe named parameter rejected" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .eq,
            .value = .{ .named_param = "1bad" },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("value.named_param", err.field);
}

test "sanitize: unsafe raw function value rejected" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "updated_at",
            .op = .lt,
            .value = .{ .function = "now(); DROP TABLE users; --" },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("value.function", err.field);
}

test "sanitize: safe raw function value passes" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "updated_at",
            .op = .lt,
            .value = .{ .function = "now()" },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: alter add constraint checks payload fragment" {
    const safe = QailCmd.alterAddConstraint("events", "events_kind_check", "kind <> 'semi;inside'");
    try std.testing.expect(validateCmd(&safe) == null);

    const unsafe = QailCmd.alterAddConstraint("users", "users_active_check", "active); DROP TABLE users; --");
    const err = validateCmd(&unsafe).?;
    try std.testing.expectEqualStrings("payload", err.field);
}

test "sanitize: merge validates source and action expressions" {
    const on = [_]ast.Condition{.{
        .left = Expr.col("users.id"),
        .op = .eq,
        .value = ast.Value.fromColumn("s.id"),
    }};
    const assignments = [_]ast.MergeAssignment{.{
        .column = "name",
        .expr = Expr.col("s.name"),
    }};
    const clauses = [_]ast.MergeClause{.{
        .match_kind = .matched,
        .action = .{ .update = &assignments },
    }};
    const merge = ast.Merge{
        .source = ast.MergeSource.fromTableAs("staging_users", "s"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("users").withMerge(merge);
    try std.testing.expect(validateCmd(&cmd) == null);

    const bad_assignments = [_]ast.MergeAssignment{.{
        .column = "name",
        .expr = .{ .raw = "pg_sleep(1)" },
    }};
    const bad_clauses = [_]ast.MergeClause{.{
        .match_kind = .matched,
        .action = .{ .update = &bad_assignments },
    }};
    const bad_merge = ast.Merge{
        .source = ast.MergeSource.fromTableAs("staging_users", "s"),
        .on = &on,
        .clauses = &bad_clauses,
    };
    const bad_cmd = QailCmd.mergeInto("users").withMerge(bad_merge);
    const err = validateCmd(&bad_cmd).?;
    try std.testing.expectEqualStrings("expr.raw", err.field);
}
