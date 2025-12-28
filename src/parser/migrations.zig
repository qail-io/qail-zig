// Migration Table Management
//
// Manages the _qail_migrations table that tracks applied migrations.
// Follows qail.rs pattern: AST-native table DDL and recording.

const std = @import("std");
const Allocator = std.mem.Allocator;

const QailCmd = @import("../ast/cmd.zig").QailCmd;
const Expr = @import("../ast/expr.zig").Expr;
const Constraint = @import("../ast/expr.zig").Constraint;

// ============================================================================
// Migration Table Schema
// ============================================================================

/// Migration table schema in QAIL format.
/// Matches qail.rs _qail_migrations structure.
pub const MIGRATION_TABLE_SCHEMA =
    \\table _qail_migrations {
    \\  id serial primary_key
    \\  version varchar(255) not_null unique
    \\  name varchar(255)
    \\  applied_at timestamptz default NOW()
    \\  checksum varchar(64) not_null
    \\  sql_up text not_null
    \\  sql_down text
    \\}
;

/// Generate DDL for the migration table
pub fn getMigrationTableDdl() []const u8 {
    return 
    \\CREATE TABLE IF NOT EXISTS _qail_migrations (
    \\  id serial PRIMARY KEY,
    \\  version varchar(255) NOT NULL UNIQUE,
    \\  name varchar(255),
    \\  applied_at timestamptz DEFAULT NOW(),
    \\  checksum varchar(64) NOT NULL,
    \\  sql_up text NOT NULL,
    \\  sql_down text
    \\)
    ;
}

/// Create a QailCmd to create the migration table (AST-native)
pub fn getMigrationTableCmd() QailCmd {
    const pk_constraint = [_]Constraint{.primary_key};
    const not_null_unique = [_]Constraint{ .not_null, .unique };
    const not_null = [_]Constraint{.not_null};

    return QailCmd{
        .kind = .make,
        .table = "_qail_migrations",
        .columns = &[_]Expr{
            Expr.defWithConstraints("id", "serial", &pk_constraint),
            Expr.defWithConstraints("version", "varchar(255)", &not_null_unique),
            Expr.defWithConstraints("name", "varchar(255)", &.{}),
            Expr{
                .column_def = .{
                    .name = "applied_at",
                    .data_type = "timestamptz",
                    .constraints = &.{}, // Has DEFAULT but we'll handle that separately
                },
            },
            Expr.defWithConstraints("checksum", "varchar(64)", &not_null),
            Expr.defWithConstraints("sql_up", "text", &not_null),
            Expr.defWithConstraints("sql_down", "text", &.{}),
        },
    };
}

/// Create a QailCmd to query migration history (AST-native)
pub fn getMigrationStatusCmd() QailCmd {
    return QailCmd.get("_qail_migrations");
}

/// Generate a migration version string (timestamp-based)
pub fn generateVersion() [14]u8 {
    const timestamp = std.time.timestamp();
    const secs = @as(u64, @intCast(timestamp));

    // Convert to datetime components
    const epoch_day = secs / 86400;
    const day_seconds = secs % 86400;

    // Simplified calculation (not accounting for leap years precisely)
    const years_since_epoch = epoch_day / 365;
    const year = 1970 + years_since_epoch;
    const day_of_year = epoch_day % 365;
    const month = @min(12, (day_of_year / 30) + 1);
    const day = @min(28, (day_of_year % 30) + 1);

    const hour = day_seconds / 3600;
    const minute = (day_seconds % 3600) / 60;
    const second = day_seconds % 60;

    var buf: [14]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{ year, month, day, hour, minute, second }) catch unreachable;

    return buf;
}

/// Simple MD5-like checksum for migration content
/// (Using FNV hash for simplicity - can be replaced with proper MD5)
pub fn computeChecksum(content: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(content);
}

// ============================================================================
// Tests
// ============================================================================

test "generate version" {
    const version = generateVersion();
    try std.testing.expectEqual(@as(usize, 14), version.len);
    // Should start with 20xx (year)
    try std.testing.expect(version[0] == '2' and version[1] == '0');
}

test "compute checksum" {
    const checksum1 = computeChecksum("CREATE TABLE users");
    const checksum2 = computeChecksum("CREATE TABLE users");
    const checksum3 = computeChecksum("CREATE TABLE posts");

    try std.testing.expectEqual(checksum1, checksum2);
    try std.testing.expect(checksum1 != checksum3);
}
