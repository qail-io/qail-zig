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
