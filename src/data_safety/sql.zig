const std = @import("std");
const copy_helpers = @import("../driver/copy/helpers.zig");

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
    const version_lit = try quoteSqlStringLiteralAlloc(allocator, version);
    defer allocator.free(version_lit);
    const table_lit = try quoteSqlStringLiteralAlloc(allocator, table);
    defer allocator.free(table_lit);
    const column_lit = try quoteSqlStringLiteralAlloc(allocator, column);
    defer allocator.free(column_lit);
    const table_ident = try copy_helpers.quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(table_ident);
    const column_ident = try copy_helpers.quoteQualifiedIdentifierAlloc(allocator, column);
    defer allocator.free(column_ident);

    return std.fmt.allocPrint(
        allocator,
        \\INSERT INTO _qail_data_snapshots 
        \\(migration_version, table_name, column_name, row_id, value_json, snapshot_type)
        \\SELECT {s}, {s}, {s}, id::text, to_jsonb({s}), 'DROP_COLUMN'
        \\FROM {s} WHERE {s} IS NOT NULL
    ,
        .{ version_lit, table_lit, column_lit, column_ident, table_ident, column_ident },
    );
}

/// Build `INSERT ... SELECT` SQL that snapshots an entire table.
pub fn buildSnapshotTableInsertSql(
    allocator: std.mem.Allocator,
    version: []const u8,
    table: []const u8,
) ![]u8 {
    const version_lit = try quoteSqlStringLiteralAlloc(allocator, version);
    defer allocator.free(version_lit);
    const table_lit = try quoteSqlStringLiteralAlloc(allocator, table);
    defer allocator.free(table_lit);
    const table_ident = try copy_helpers.quoteQualifiedIdentifierAlloc(allocator, table);
    defer allocator.free(table_ident);

    return std.fmt.allocPrint(
        allocator,
        \\INSERT INTO _qail_data_snapshots 
        \\(migration_version, table_name, column_name, row_id, value_json, snapshot_type)
        \\SELECT {s}, {s}, NULL, id::text, to_jsonb(t.*), 'DROP_TABLE'
        \\FROM {s} t
    ,
        .{ version_lit, table_lit, table_ident },
    );
}

fn quoteSqlStringLiteralAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidStringLiteral;
    if (std.mem.indexOfScalar(u8, value, '\\') != null) {
        return try quoteDollarStringLiteralAlloc(allocator, value, "qail_lit");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn quoteDollarStringLiteralAlloc(
    allocator: std.mem.Allocator,
    value: []const u8,
    base_tag: []const u8,
) ![]u8 {
    var idx: usize = 0;
    while (idx <= value.len) : (idx += 1) {
        const tag = if (idx == 0)
            try allocator.dupe(u8, base_tag)
        else
            try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base_tag, idx });
        defer allocator.free(tag);

        const delimiter = try std.fmt.allocPrint(allocator, "${s}$", .{tag});
        defer allocator.free(delimiter);

        if (std.mem.indexOf(u8, value, delimiter) != null) continue;
        return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ delimiter, value, delimiter });
    }

    return error.InvalidStringLiteral;
}

test "build snapshot column insert sql" {
    const sql = try buildSnapshotColumnInsertSql(std.testing.allocator, "v1", "users", "email");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO _qail_data_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'v1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "to_jsonb(\"email\")") != null);
}

test "build snapshot table insert sql" {
    const sql = try buildSnapshotTableInsertSql(std.testing.allocator, "v2", "users");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO _qail_data_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'DROP_TABLE'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM \"users\" t") != null);
}

test "snapshot sql quotes values and rejects unsafe identifiers" {
    const sql = try buildSnapshotColumnInsertSql(std.testing.allocator, "v'1", "tenant.users", "email");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "'v''1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'tenant.users'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM \"tenant\".\"users\"") != null);

    try std.testing.expectError(
        error.InvalidIdentifier,
        buildSnapshotColumnInsertSql(std.testing.allocator, "v1", "users; DROP TABLE users", "email"),
    );
    try std.testing.expectError(
        error.InvalidIdentifier,
        buildSnapshotColumnInsertSql(std.testing.allocator, "v1", "users", "email; DROP TABLE users"),
    );
    try std.testing.expectError(
        error.InvalidStringLiteral,
        buildSnapshotTableInsertSql(std.testing.allocator, "v\x001", "users"),
    );
}

test "snapshot sql dollar quotes values containing backslashes" {
    const sql = try buildSnapshotTableInsertSql(std.testing.allocator, "v\\1", "users");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "$qail_lit$v\\1$qail_lit$") != null);
}

test "snapshot sql avoids dollar quote delimiter collisions" {
    const sql = try buildSnapshotTableInsertSql(std.testing.allocator, "v $qail_lit$ \\ 1", "users");
    defer std.testing.allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "$qail_lit_1$v $qail_lit$ \\ 1$qail_lit_1$") != null);
}
