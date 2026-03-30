const std = @import("std");

/// DDL for `_qail_data_snapshots` table.
pub const SNAPSHOT_TABLE_DDL =
    \\CREATE TABLE IF NOT EXISTS _qail_data_snapshots (
    \\    id SERIAL PRIMARY KEY,
    \\    migration_version VARCHAR(255) NOT NULL,
    \\    table_name VARCHAR(255) NOT NULL,
    \\    column_name VARCHAR(255),
    \\    row_id TEXT NOT NULL,
    \\    value_json JSONB NOT NULL,
    \\    snapshot_type VARCHAR(50) NOT NULL,
    \\    created_at TIMESTAMPTZ DEFAULT NOW()
    \\)
;

/// Build `INSERT ... SELECT` SQL that snapshots one column.
pub fn buildSnapshotColumnInsertSql(
    allocator: std.mem.Allocator,
    version: []const u8,
    table: []const u8,
    column: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\INSERT INTO _qail_data_snapshots 
        \\(migration_version, table_name, column_name, row_id, value_json, snapshot_type)
        \\SELECT '{s}', '{s}', '{s}', id::text, to_jsonb({s}), 'DROP_COLUMN'
        \\FROM {s} WHERE {s} IS NOT NULL
    ,
        .{ version, table, column, column, table, column },
    );
}

/// Build `INSERT ... SELECT` SQL that snapshots an entire table.
pub fn buildSnapshotTableInsertSql(
    allocator: std.mem.Allocator,
    version: []const u8,
    table: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\INSERT INTO _qail_data_snapshots 
        \\(migration_version, table_name, column_name, row_id, value_json, snapshot_type)
        \\SELECT '{s}', '{s}', NULL, id::text, to_jsonb(t.*), 'DROP_TABLE'
        \\FROM {s} t
    ,
        .{ version, table, table },
    );
}

test "build snapshot column insert sql" {
    const sql = try buildSnapshotColumnInsertSql(std.testing.allocator, "v1", "users", "email");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO _qail_data_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'v1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "to_jsonb(email)") != null);
}

test "build snapshot table insert sql" {
    const sql = try buildSnapshotTableInsertSql(std.testing.allocator, "v2", "users");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO _qail_data_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'DROP_TABLE'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM users t") != null);
}
