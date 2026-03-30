const std = @import("std");

const Allocator = std.mem.Allocator;
const PgDriver = @import("../driver/driver.zig").PgDriver;
const raw_cmd = @import("../ast/raw_cmd.zig");
const snapshot_sql = @import("sql.zig");

pub const SNAPSHOT_TABLE_DDL = snapshot_sql.SNAPSHOT_TABLE_DDL;

/// Ensure snapshot table exists (uses AST-tracked raw helper for DDL).
pub fn ensureSnapshotTable(conn: *PgDriver) !void {
    const create_cmd = raw_cmd.command(SNAPSHOT_TABLE_DDL);
    _ = try conn.execute(&create_cmd);
}

/// Backup a column before dropping.
/// Uses raw SQL via AST-tracked raw command helper for complex INSERT...SELECT.
pub fn snapshotColumnToDb(
    allocator: Allocator,
    conn: *PgDriver,
    version: []const u8,
    table: []const u8,
    column: []const u8,
) !u64 {
    const sql = try snapshot_sql.buildSnapshotColumnInsertSql(allocator, version, table, column);
    defer allocator.free(sql);

    const insert_cmd = raw_cmd.command(sql);
    _ = try conn.execute(&insert_cmd);
    return 0; // TODO: Get affected row count
}

/// Backup a table before dropping.
/// Uses raw SQL via AST-tracked raw command helper for complex INSERT...SELECT.
pub fn snapshotTableToDb(
    allocator: Allocator,
    conn: *PgDriver,
    version: []const u8,
    table: []const u8,
) !u64 {
    const sql = try snapshot_sql.buildSnapshotTableInsertSql(allocator, version, table);
    defer allocator.free(sql);

    const insert_cmd = raw_cmd.command(sql);
    _ = try conn.execute(&insert_cmd);
    return 0; // TODO: Get affected row count
}
