const std = @import("std");
const QailCmd = @import("../ast/mod.zig").QailCmd;

/// Returns true when a command uses the raw-SQL runtime escape hatch.
pub fn isRawRuntimeCommand(cmd: *const QailCmd) bool {
    return cmd.kind == .raw or cmd.raw_sql != null;
}

/// Reject raw runtime commands from the public execution path.
pub fn rejectPublicRuntimeCmd(cmd: *const QailCmd) !void {
    if (isRawRuntimeCommand(cmd)) return error.RawSqlForbidden;
}

/// Reject raw runtime commands from public batched execution paths.
pub fn rejectPublicRuntimeCmds(cmds: []const *const QailCmd) !void {
    for (cmds) |cmd| try rejectPublicRuntimeCmd(cmd);
}

test "raw policy allows regular ast commands" {
    const cmd = @import("../ast/mod.zig").QailCmd.get("users");
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy rejects raw command helper" {
    const raw_cmd = @import("../ast/raw_cmd.zig").command("SELECT 1");
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&raw_cmd));
}

test "raw policy rejects command slices containing raw sql" {
    const good = @import("../ast/mod.zig").QailCmd.get("users");
    const bad = @import("../ast/raw_cmd.zig").command("SELECT 1");
    const cmds = [_]*const QailCmd{ &good, &bad };
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmds(&cmds));
}

test "source: public driver raw runtime api is not re-exported" {
    const allocator = std.testing.allocator;

    const ast_mod = try std.fs.cwd().readFileAlloc(allocator, "src/ast/mod.zig", 32 * 1024);
    defer allocator.free(ast_mod);
    try std.testing.expect(std.mem.indexOf(u8, ast_mod, "pub const raw_cmd =") == null);

    const driver_mod = try std.fs.cwd().readFileAlloc(allocator, "src/driver/mod.zig", 32 * 1024);
    defer allocator.free(driver_mod);
    try std.testing.expect(std.mem.indexOf(u8, driver_mod, "pub const raw_sql =") == null);
    try std.testing.expect(std.mem.indexOf(u8, driver_mod, "pub const raw_cmd =") == null);

    const driver_src = try std.fs.cwd().readFileAlloc(allocator, "src/driver/driver.zig", 96 * 1024);
    defer allocator.free(driver_src);
    try std.testing.expect(std.mem.indexOf(u8, driver_src, "pub fn executeRaw(") == null);
}
