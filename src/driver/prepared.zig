//! High-performance prepared statement handling.
//!
//! Zero-allocation prepared statement caching using hash-based naming.
//! Port of qail.rs/qail-pg/src/driver/prepared.rs

const std = @import("std");

/// A prepared statement handle with pre-computed statement name.
///
/// Create once, execute many times for best performance.
///
/// Example (AST-native):
/// ```zig
/// // Prepare once (compute hash)
/// const stmt = PreparedStatement.fromSql("SELECT id, name FROM users WHERE id = $1");
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

    /// Create a new prepared statement handle from SQL string.
    pub fn fromSql(sql: []const u8) PreparedStatement {
        var name: [17]u8 = undefined;
        name[0] = 's';
        const hash = hashSql(sql);
        _ = std.fmt.bufPrint(name[1..], "{x:0>16}", .{hash}) catch unreachable;

        // Count $N placeholders
        var param_count: usize = 0;
        var i: usize = 0;
        while (i < sql.len - 1) : (i += 1) {
            if (sql[i] == '$' and std.ascii.isDigit(sql[i + 1])) {
                param_count += 1;
            }
        }

        return .{
            .name = name,
            .param_count = param_count,
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

// ==================== Tests ====================

test "PreparedStatement.fromSql" {
    const stmt = PreparedStatement.fromSql("SELECT id, name FROM users WHERE id = $1");

    // Name should start with 's' and be 17 chars
    try std.testing.expectEqual(@as(u8, 's'), stmt.name[0]);
    try std.testing.expectEqual(@as(usize, 17), stmt.name.len);

    // Param count should be 1
    try std.testing.expectEqual(@as(usize, 1), stmt.param_count);
}

test "PreparedStatement deterministic hash" {
    const sql = "SELECT * FROM users WHERE id = $1 AND name = $2";
    const stmt1 = PreparedStatement.fromSql(sql);
    const stmt2 = PreparedStatement.fromSql(sql);

    // Same SQL should produce same name
    try std.testing.expectEqualStrings(&stmt1.name, &stmt2.name);

    // Should have 2 params
    try std.testing.expectEqual(@as(usize, 2), stmt1.param_count);
}

test "PreparedStatement different SQL different name" {
    const stmt1 = PreparedStatement.fromSql("SELECT * FROM users");
    const stmt2 = PreparedStatement.fromSql("SELECT * FROM orders");

    // Different SQL should produce different names
    try std.testing.expect(!std.mem.eql(u8, &stmt1.name, &stmt2.name));
}
