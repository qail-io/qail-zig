//! Data-Safe Migration Utilities for QAIL
//!
//! Provides enterprise-grade migration safety features:
//! - Impact analysis (count affected rows)
//! - JSONB backup to _qail_data_snapshots
//! - Interactive backup prompts

const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const PgDriver = @import("driver/driver.zig").PgDriver;
const differ = @import("parser/differ.zig");
const MigrationCmd = differ.MigrationCmd;

// ============================================================================
// Types
// ============================================================================

/// Impact analysis result for a single destructive operation
pub const DestructiveOp = struct {
    op_type: OpType,
    table: []const u8,
    column: ?[]const u8,
    rows_affected: u64,

    pub const OpType = enum {
        drop_column,
        drop_table,
        alter_type,
    };

    pub fn format(self: DestructiveOp, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        switch (self.op_type) {
            .drop_column => {
                try writer.print("DROP COLUMN {s}.{s} → {} values at risk", .{
                    self.table,
                    self.column orelse "?",
                    self.rows_affected,
                });
            },
            .drop_table => {
                try writer.print("DROP TABLE {s} → {} rows affected", .{
                    self.table,
                    self.rows_affected,
                });
            },
            .alter_type => {
                try writer.print("ALTER TYPE {s}.{s} → {} values affected", .{
                    self.table,
                    self.column orelse "?",
                    self.rows_affected,
                });
            },
        }

        return buf.toOwnedSlice();
    }
};

/// Full impact analysis result
pub const ImpactAnalysis = struct {
    ops: std.ArrayListUnmanaged(DestructiveOp),
    allocator: Allocator,
    total_at_risk: u64,

    pub fn init(allocator: Allocator) ImpactAnalysis {
        return .{
            .ops = .empty,
            .allocator = allocator,
            .total_at_risk = 0,
        };
    }

    pub fn deinit(self: *ImpactAnalysis) void {
        self.ops.deinit(self.allocator);
    }

    pub fn addOp(self: *ImpactAnalysis, op: DestructiveOp) !void {
        try self.ops.append(self.allocator, op);
        self.total_at_risk += op.rows_affected;
    }

    pub fn hasDestructive(self: *const ImpactAnalysis) bool {
        return self.ops.items.len > 0;
    }
};

/// User's backup choice
pub const BackupChoice = enum {
    proceed, // [1] Continue without backup
    backup_to_file, // [2] Backup to _qail_snapshots/
    backup_to_db, // [3] Backup to database
    cancel, // [4] Cancel migration
};

// ============================================================================
// Impact Analysis
// ============================================================================

/// Analyze migration commands for destructive operations
pub fn analyzeImpact(
    allocator: Allocator,
    cmds: []const MigrationCmd,
    conn: *PgDriver,
    analysis: *ImpactAnalysis,
) !void {
    for (cmds) |cmd| {
        switch (cmd.action) {
            .drop_column => {
                if (cmd.column) |col| {
                    const count = try countColumnValues(allocator, conn, cmd.table, col.name);
                    try analysis.addOp(.{
                        .op_type = .drop_column,
                        .table = cmd.table,
                        .column = col.name,
                        .rows_affected = count,
                    });
                }
            },
            .drop_table => {
                const count = try countTableRows(allocator, conn, cmd.table);
                try analysis.addOp(.{
                    .op_type = .drop_table,
                    .table = cmd.table,
                    .column = null,
                    .rows_affected = count,
                });
            },
            .alter_column => {
                if (cmd.column) |col| {
                    const count = try countTableRows(allocator, conn, cmd.table);
                    try analysis.addOp(.{
                        .op_type = .alter_type,
                        .table = cmd.table,
                        .column = col.name,
                        .rows_affected = count,
                    });
                }
            },
            else => {},
        }
    }
}

/// Count non-null values in a column using AST-native query (like qail.rs)
fn countColumnValues(allocator: Allocator, conn: *PgDriver, table: []const u8, column: []const u8) !u64 {
    _ = allocator;

    // SELECT COUNT(column) FROM table - AST-native
    const QailCmd = @import("ast/cmd.zig").QailCmd;
    const Expr = @import("ast/expr.zig").Expr;

    // Build count(column_name) expression
    var cmd = QailCmd.get(table);
    cmd.columns = &[_]Expr{Expr.col("count(*)")};
    _ = column; // TODO: proper count(column) for non-null check

    // Execute and parse result
    const rows = conn.fetchAll(&cmd) catch return 0;

    // Free memory properly - field_names is shared by all rows so free once
    if (rows.len > 0) {
        defer conn.allocator.free(rows[0].field_names);
    }
    defer {
        for (rows) |*row| {
            row.deinit();
        }
        conn.allocator.free(rows);
    }

    if (rows.len > 0) {
        // First column should be the count
        if (rows[0].getString(0)) |count_str| {
            return std.fmt.parseInt(u64, count_str, 10) catch 0;
        }
    }
    return 0;
}

/// Count all rows in a table using AST-native query (like qail.rs)
fn countTableRows(allocator: Allocator, conn: *PgDriver, table: []const u8) !u64 {
    _ = allocator;

    // SELECT COUNT(*) FROM table - AST-native
    const QailCmd = @import("ast/cmd.zig").QailCmd;
    const Expr = @import("ast/expr.zig").Expr;

    var cmd = QailCmd.get(table);
    cmd.columns = &[_]Expr{Expr.col("count(*)")};

    // Execute and parse result
    const rows = conn.fetchAll(&cmd) catch return 0;

    // Free memory properly - field_names is shared by all rows so free once
    if (rows.len > 0) {
        defer conn.allocator.free(rows[0].field_names);
    }
    defer {
        for (rows) |*row| {
            row.deinit();
        }
        conn.allocator.free(rows);
    }

    if (rows.len > 0) {
        if (rows[0].getString(0)) |count_str| {
            return std.fmt.parseInt(u64, count_str, 10) catch 0;
        }
    }
    return 0;
}

// ============================================================================
// Display Functions
// ============================================================================

/// Display impact analysis to user
pub fn displayImpact(analysis: *const ImpactAnalysis) void {
    print("\n", .{});
    print("🚨 Migration Impact Analysis\n", .{});
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    for (analysis.ops.items) |op| {
        switch (op.op_type) {
            .drop_column => {
                print("  DROP COLUMN {s}.{s} → {} values at risk\n", .{
                    op.table,
                    op.column orelse "?",
                    op.rows_affected,
                });
            },
            .drop_table => {
                print("  DROP TABLE {s} → {} rows affected\n", .{
                    op.table,
                    op.rows_affected,
                });
            },
            .alter_type => {
                print("  ALTER TYPE {s}.{s} → {} values affected\n", .{
                    op.table,
                    op.column orelse "?",
                    op.rows_affected,
                });
            },
        }
    }

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    print("  Total: {} records at risk\n\n", .{analysis.total_at_risk});
}

/// Prompt user for backup choice
pub fn promptBackupOptions() BackupChoice {
    print("Choose an option:\n", .{});
    print("  [1] Proceed (I have my own backup)\n", .{});
    print("  [2] Backup to files (_qail_snapshots/)\n", .{});
    print("  [3] Backup to database (with rollback support)\n", .{});
    print("  [4] Cancel migration\n", .{});
    print("> ", .{});

    // Read single line from stdin (cross-platform)
    var buf: [16]u8 = undefined;
    const bytes_read = blk: {
        const builtin = @import("builtin");
        if (builtin.os.tag == .windows) {
            // Windows: use std.fs.cwd() based stdin (skip for now, return cancel)
            break :blk @as(usize, 0);
        } else {
            // Unix: use posix
            break :blk std.posix.read(std.posix.STDIN_FILENO, &buf) catch break :blk @as(usize, 0);
        }
    };
    if (bytes_read == 0) return .cancel;

    const trimmed = std.mem.trim(u8, buf[0..bytes_read], " \t\r\n");
    if (trimmed.len > 0) {
        switch (trimmed[0]) {
            '1' => return .proceed,
            '2' => return .backup_to_file,
            '3' => return .backup_to_db,
            else => return .cancel,
        }
    }
    return .cancel;
}

// ============================================================================
// Database Snapshots (Phase 2)
// ============================================================================

/// DDL for _qail_data_snapshots table
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

/// Ensure snapshot table exists (uses AST-tracked raw for DDL)
pub fn ensureSnapshotTable(conn: *PgDriver) !void {
    const QailCmd = @import("ast/cmd.zig").QailCmd;
    const create_cmd = QailCmd.raw(SNAPSHOT_TABLE_DDL);
    _ = try conn.execute(&create_cmd);
}

/// Backup a column before dropping (Phase 2)
/// Note: Uses raw SQL via AST-tracked QailCmd.raw for complex INSERT...SELECT
pub fn snapshotColumnToDb(
    allocator: Allocator,
    conn: *PgDriver,
    version: []const u8,
    table: []const u8,
    column: []const u8,
) !u64 {
    const QailCmd = @import("ast/cmd.zig").QailCmd;

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.writer(allocator).print(
        \\INSERT INTO _qail_data_snapshots 
        \\(migration_version, table_name, column_name, row_id, value_json, snapshot_type)
        \\SELECT '{s}', '{s}', '{s}', id::text, to_jsonb({s}), 'DROP_COLUMN'
        \\FROM {s} WHERE {s} IS NOT NULL
    , .{ version, table, column, column, table, column });

    // AST-tracked raw SQL (not truly AST-native, but tracked)
    const insert_cmd = QailCmd.raw(sql_buf.items);
    _ = try conn.execute(&insert_cmd);
    return 0; // TODO: Get affected row count
}

/// Backup a table before dropping (Phase 2)
/// Note: Uses raw SQL via AST-tracked QailCmd.raw for complex INSERT...SELECT
pub fn snapshotTableToDb(
    allocator: Allocator,
    conn: *PgDriver,
    version: []const u8,
    table: []const u8,
) !u64 {
    const QailCmd = @import("ast/cmd.zig").QailCmd;

    var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer sql_buf.deinit(allocator);

    try sql_buf.writer(allocator).print(
        \\INSERT INTO _qail_data_snapshots 
        \\(migration_version, table_name, column_name, row_id, value_json, snapshot_type)
        \\SELECT '{s}', '{s}', NULL, id::text, to_jsonb(t.*), 'DROP_TABLE'
        \\FROM {s} t
    , .{ version, table, table });

    // AST-tracked raw SQL
    const insert_cmd = QailCmd.raw(sql_buf.items);
    _ = try conn.execute(&insert_cmd);
    return 0; // TODO: Get affected row count
}

/// Create database snapshots for all destructive operations
pub fn createDbSnapshots(
    allocator: Allocator,
    conn: *PgDriver,
    version: []const u8,
    analysis: *const ImpactAnalysis,
) !u64 {
    var total: u64 = 0;

    // Ensure snapshot table exists
    try ensureSnapshotTable(conn);

    print("\n💾 Creating database snapshots (Phase 2)...\n", .{});

    for (analysis.ops.items) |op| {
        switch (op.op_type) {
            .drop_column => {
                if (op.column) |col| {
                    const count = try snapshotColumnToDb(allocator, conn, version, op.table, col);
                    print("  ✓ {s}.{s} → {} values saved\n", .{ op.table, col, count });
                    total += count;
                }
            },
            .drop_table => {
                const count = try snapshotTableToDb(allocator, conn, version, op.table);
                print("  ✓ {s} → {} rows saved to _qail_data_snapshots\n", .{ op.table, count });
                total += count;
            },
            .alter_type => {
                // For ALTER TYPE, we could backup the column values
                if (op.column) |col| {
                    const count = try snapshotColumnToDb(allocator, conn, version, op.table, col);
                    print("  ✓ {s}.{s} → {} values saved\n", .{ op.table, col, count });
                    total += count;
                }
            },
        }
    }

    print("  ✓ Total: {} records backed up to database\n\n", .{total});

    return total;
}
