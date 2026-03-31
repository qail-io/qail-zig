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
