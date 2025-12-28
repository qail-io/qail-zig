//! Transaction control for PostgreSQL connections.
//!
//! AST-native transaction methods using QailCmd.
//! Port of qail.rs/qail-pg/src/driver/transaction.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const QailCmd = ast.QailCmd;

/// Transaction controller for a connection.
///
/// Example (AST-native):
/// ```zig
/// const tx = Transaction.init(&conn);
/// try tx.begin();
/// // ... execute queries ...
/// try tx.commit();
/// ```
pub const Transaction = struct {
    conn: *anyopaque, // Type-erased connection pointer
    executeFn: *const fn (*anyopaque, *const QailCmd) anyerror!void,

    /// Initialize transaction controller with a connection.
    pub fn init(conn: anytype) Transaction {
        const Conn = @TypeOf(conn);
        return .{
            .conn = @ptrCast(conn),
            .executeFn = struct {
                fn execute(ptr: *anyopaque, cmd: *const QailCmd) anyerror!void {
                    const c: Conn = @ptrCast(@alignCast(ptr));
                    _ = try c.execute(cmd);
                }
            }.execute,
        };
    }

    /// Begin a new transaction.
    pub fn begin(self: *const Transaction) !void {
        const cmd = QailCmd.beginTx();
        try self.executeFn(self.conn, &cmd);
    }

    /// Commit the current transaction.
    pub fn commit(self: *const Transaction) !void {
        const cmd = QailCmd.commitTx();
        try self.executeFn(self.conn, &cmd);
    }

    /// Rollback the current transaction.
    pub fn rollback(self: *const Transaction) !void {
        const cmd = QailCmd.rollbackTx();
        try self.executeFn(self.conn, &cmd);
    }

    /// Create a savepoint within the current transaction.
    pub fn savepoint(self: *const Transaction, name: []const u8) !void {
        const cmd = QailCmd.savepoint(name);
        try self.executeFn(self.conn, &cmd);
    }

    /// Rollback to a previously created savepoint.
    pub fn rollbackTo(self: *const Transaction, name: []const u8) !void {
        const cmd = QailCmd.rollbackTo(name);
        try self.executeFn(self.conn, &cmd);
    }

    /// Release a savepoint (free resources).
    pub fn releaseSavepoint(self: *const Transaction, name: []const u8) !void {
        const cmd = QailCmd.releaseSavepoint(name);
        try self.executeFn(self.conn, &cmd);
    }
};

// ==================== Tests ====================

test "QailCmd transaction commands" {
    const begin = QailCmd.beginTx();
    try std.testing.expectEqual(ast.CmdKind.begin, begin.kind);

    const commit = QailCmd.commitTx();
    try std.testing.expectEqual(ast.CmdKind.commit, commit.kind);

    const rollback = QailCmd.rollbackTx();
    try std.testing.expectEqual(ast.CmdKind.rollback, rollback.kind);

    const sp = QailCmd.savepoint("my_savepoint");
    try std.testing.expectEqual(ast.CmdKind.savepoint, sp.kind);
}
