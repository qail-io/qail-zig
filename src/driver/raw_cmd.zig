const ast_raw_cmd = @import("../ast/raw_cmd.zig");
const ast = @import("../ast/mod.zig");
const QailCmd = ast.QailCmd;

/// Wrap a raw SQL string as a QAIL command.
pub fn command(sql: []const u8) QailCmd {
    return ast_raw_cmd.command(sql);
}
