const QailCmd = @import("cmd.zig").QailCmd;

/// Wrap raw SQL into a QAIL command.
///
/// Keeping this in one helper makes raw-call removal incremental and auditable.
pub fn command(sql: []const u8) QailCmd {
    return .{
        .kind = .raw,
        .raw_sql = sql,
    };
}

test "raw command helper wraps sql" {
    const std = @import("std");
    const cmd = command("SELECT 1");

    try std.testing.expectEqual(@import("cmd.zig").CmdKind.raw, cmd.kind);
    try std.testing.expect(cmd.raw_sql != null);
    try std.testing.expectEqualStrings("SELECT 1", cmd.raw_sql.?);
}
