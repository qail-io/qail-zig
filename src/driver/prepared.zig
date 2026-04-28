//! High-performance prepared statement handling.
//!
//! Zero-allocation prepared statement caching using hash-based naming.
//! Port of qail.rs/qail-pg/src/driver/prepared.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const protocol = @import("../protocol/mod.zig");
const raw_policy = @import("raw_policy.zig");

const QailCmd = ast.QailCmd;
const AstEncoder = protocol.AstEncoder;

/// A prepared statement handle with pre-computed statement name.
///
/// Create once from a QAIL AST, execute many times for best performance.
///
/// Example (AST-native):
/// ```zig
/// // Prepare once (compute hash)
/// const stmt = try PreparedStatement.fromCmd(allocator, &cmd);
///
/// // Execute many times (no hash, no lookup!)
/// for (1..1000) |id| {
///     _ = try conn.executePrepared(&stmt, &[_]?[]const u8{idStr});
/// }
/// ```
pub const PreparedStatement = struct {
    /// Pre-computed statement name (e.g., "s1234567890abcdef")
    name: [17]u8, // "s" + 16 hex chars
    /// Number of parameters
    param_count: usize,

    /// Create a new prepared statement handle from a QAIL AST command.
    pub fn fromCmd(allocator: std.mem.Allocator, cmd: *const QailCmd) !PreparedStatement {
        try raw_policy.rejectPublicRuntimeCmd(cmd);

        var encoder = AstEncoder.init(allocator);
        defer encoder.deinit();
        const sql = try encoder.toSqlOwned(allocator, cmd);
        defer allocator.free(sql);

        var name: [17]u8 = undefined;
        name[0] = 's';
        const hash = hashSql(sql);
        _ = std.fmt.bufPrint(name[1..], "{x:0>16}", .{hash}) catch unreachable;

        return .{
            .name = name,
            .param_count = countParams(sql),
        };
    }

    /// Get the statement name as a slice.
    pub fn getName(self: *const PreparedStatement) []const u8 {
        return &self.name;
    }
};

/// Hash SQL bytes using SipHash for statement naming.
fn hashSql(sql: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(sql);
    return hasher.final();
}

fn countParams(sql: []const u8) usize {
    if (sql.len < 2) return 0;

    var param_count: usize = 0;
    var i: usize = 0;
    while (i < sql.len - 1) : (i += 1) {
        if (sql[i] == '$' and std.ascii.isDigit(sql[i + 1])) {
            param_count += 1;
        }
    }
    return param_count;
}

// ==================== Tests ====================

test "PreparedStatement.fromCmd" {
    const cmd = QailCmd.get("users")
        .select(&.{ ast.Expr.col("id"), ast.Expr.col("name") })
        .where(&.{.{ .condition = .{ .column = "id", .op = .eq, .value = .{ .param = 1 } } }});
    const stmt = try PreparedStatement.fromCmd(std.testing.allocator, &cmd);

    // Name should start with 's' and be 17 chars
    try std.testing.expectEqual(@as(u8, 's'), stmt.name[0]);
    try std.testing.expectEqual(@as(usize, 17), stmt.name.len);

    // Param count should be 1
    try std.testing.expectEqual(@as(usize, 1), stmt.param_count);
}

test "PreparedStatement deterministic hash" {
    const cmd = QailCmd.get("users").where(&.{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .param = 1 } } },
        .{ .condition = .{ .column = "name", .op = .eq, .value = .{ .param = 2 } } },
    });
    const stmt1 = try PreparedStatement.fromCmd(std.testing.allocator, &cmd);
    const stmt2 = try PreparedStatement.fromCmd(std.testing.allocator, &cmd);

    // Same SQL should produce same name
    try std.testing.expectEqualStrings(&stmt1.name, &stmt2.name);

    // Should have 2 params
    try std.testing.expectEqual(@as(usize, 2), stmt1.param_count);
}

test "PreparedStatement different commands different name" {
    const cmd1 = QailCmd.get("users");
    const cmd2 = QailCmd.get("orders");
    const stmt1 = try PreparedStatement.fromCmd(std.testing.allocator, &cmd1);
    const stmt2 = try PreparedStatement.fromCmd(std.testing.allocator, &cmd2);

    // Different SQL should produce different names
    try std.testing.expect(!std.mem.eql(u8, &stmt1.name, &stmt2.name));
}
