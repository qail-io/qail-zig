// Migration impact analysis.
//
// Detects breaking changes before migrations are applied
// by comparing migration commands against codebase references.

const std = @import("std");
const scanner = @import("scanner.zig");
const differ = @import("../parser/differ.zig");

const CodeReference = scanner.CodeReference;
const MigrationCmd = differ.MigrationCmd;

/// Types of breaking changes
pub const BreakingChange = union(enum) {
    /// A column is being dropped that is still referenced in code
    dropped_column: struct {
        table: []const u8,
        column: []const u8,
        reference_count: usize,
    },
    /// A table is being dropped that is still referenced in code
    dropped_table: struct {
        table: []const u8,
        reference_count: usize,
    },
    /// A column is being renamed (requires code update)
    renamed_column: struct {
        table: []const u8,
        old_name: []const u8,
        new_name: []const u8,
        reference_count: usize,
    },
    /// A column type is changing (may cause runtime errors)
    type_changed: struct {
        table: []const u8,
        column: []const u8,
        old_type: []const u8,
        new_type: []const u8,
        reference_count: usize,
    },
};

/// Warning about the migration
pub const Warning = union(enum) {
    /// Table is referenced but not in new schema
    orphaned_reference: struct {
        table: []const u8,
        reference_count: usize,
    },
};

/// Result of analyzing migration impact
pub const MigrationImpact = struct {
    /// Breaking changes that will cause runtime errors
    breaking_changes: std.ArrayList(BreakingChange),
    /// Warnings that may cause issues
    warnings: std.ArrayList(Warning),
    /// Whether it's safe to run the migration
    safe_to_run: bool,
    /// Total affected files
    affected_files: usize,
    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MigrationImpact {
        return .{
            .breaking_changes = .empty,
            .warnings = .empty,
            .safe_to_run = true,
            .affected_files = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MigrationImpact) void {
        self.breaking_changes.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    /// Analyze migration commands against codebase references
    pub fn analyze(
        allocator: std.mem.Allocator,
        commands: []const MigrationCmd,
        code_refs: []const CodeReference,
    ) !MigrationImpact {
        var impact = MigrationImpact.init(allocator);

        // Build lookup maps
        var table_ref_counts = std.StringHashMap(usize).init(allocator);
        defer table_ref_counts.deinit();

        var column_ref_counts = std.StringHashMap(usize).init(allocator);
        defer column_ref_counts.deinit();

        // Count references per table and column
        for (code_refs) |ref| {
            const current = table_ref_counts.get(ref.table) orelse 0;
            try table_ref_counts.put(ref.table, current + 1);

            for (ref.columns.items) |col| {
                var key_buf: [256]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ ref.table, col });
                const col_current = column_ref_counts.get(key) orelse 0;
                try column_ref_counts.put(key, col_current + 1);
            }
        }

        // Track affected files
        var affected_set = std.StringHashMap(void).init(allocator);
        defer affected_set.deinit();

        // Analyze each migration command
        for (commands) |cmd| {
            switch (cmd.action) {
                .drop_table => {
                    // Table being dropped
                    if (table_ref_counts.get(cmd.table)) |count| {
                        if (count > 0) {
                            try impact.breaking_changes.append(allocator, .{
                                .dropped_table = .{
                                    .table = cmd.table,
                                    .reference_count = count,
                                },
                            });
                            impact.safe_to_run = false;

                            // Mark affected files
                            for (code_refs) |ref| {
                                if (std.mem.eql(u8, ref.table, cmd.table)) {
                                    try affected_set.put(ref.file, {});
                                }
                            }
                        }
                    }
                },
                .drop_column => {
                    // Column being dropped
                    if (cmd.column) |col_def| {
                        var key_buf: [256]u8 = undefined;
                        const key = try std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ cmd.table, col_def.name });
                        if (column_ref_counts.get(key)) |count| {
                            if (count > 0) {
                                try impact.breaking_changes.append(allocator, .{
                                    .dropped_column = .{
                                        .table = cmd.table,
                                        .column = col_def.name,
                                        .reference_count = count,
                                    },
                                });
                                impact.safe_to_run = false;
                            }
                        }
                    }
                },
                .alter_column => {
                    // Column being altered (type change, rename, etc.)
                    if (cmd.column) |col_def| {
                        var key_buf: [256]u8 = undefined;
                        const key = try std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ cmd.table, col_def.name });
                        if (column_ref_counts.get(key)) |count| {
                            if (count > 0) {
                                try impact.warnings.append(allocator, .{
                                    .orphaned_reference = .{
                                        .table = cmd.table,
                                        .reference_count = count,
                                    },
                                });
                            }
                        }
                    }
                },
                else => {},
            }
        }

        impact.affected_files = affected_set.count();
        return impact;
    }

    /// Generate human-readable report
    pub fn report(self: *const MigrationImpact, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();

        if (self.safe_to_run) {
            try writer.writeAll("✓ Migration is safe to run\n");
            return try output.toOwnedSlice();
        }

        try writer.writeAll("⚠️  BREAKING CHANGES DETECTED\n\n");
        try writer.print("Affected files: {d}\n\n", .{self.affected_files});

        for (self.breaking_changes.items) |change| {
            switch (change) {
                .dropped_column => |dc| {
                    try writer.print("DROP COLUMN {s}.{s} ({d} references)\n", .{
                        dc.table,
                        dc.column,
                        dc.reference_count,
                    });
                },
                .dropped_table => |dt| {
                    try writer.print("DROP TABLE {s} ({d} references)\n", .{
                        dt.table,
                        dt.reference_count,
                    });
                },
                .renamed_column => |rc| {
                    try writer.print("RENAME {s}.{s} → {s} ({d} references)\n", .{
                        rc.table,
                        rc.old_name,
                        rc.new_name,
                        rc.reference_count,
                    });
                },
                .type_changed => |tc| {
                    try writer.print("TYPE CHANGE {s}.{s}: {s} → {s} ({d} references)\n", .{
                        tc.table,
                        tc.column,
                        tc.old_type,
                        tc.new_type,
                        tc.reference_count,
                    });
                },
            }
        }

        return try output.toOwnedSlice();
    }
};

// ==================== Tests ====================

test "impact analyze detects dropped table" {
    const allocator = std.testing.allocator;

    // Create a mock migration command
    var commands = [_]MigrationCmd{.{
        .table = "users",
        .action = .drop_table,
    }};

    // Create mock code references
    var cols: std.ArrayList([]const u8) = .empty;
    defer cols.deinit(allocator);

    var refs = [_]CodeReference{.{
        .file = "src/handlers.rs",
        .line = 42,
        .table = "users",
        .columns = cols,
        .query_type = .qail,
        .snippet = "get::users",
        .allocator = allocator,
    }};

    var impact = try MigrationImpact.analyze(allocator, &commands, &refs);
    defer impact.deinit();

    try std.testing.expect(!impact.safe_to_run);
    try std.testing.expectEqual(@as(usize, 1), impact.breaking_changes.items.len);
}

test "impact safe when no references" {
    const allocator = std.testing.allocator;

    var commands = [_]MigrationCmd{.{
        .table = "users",
        .action = .drop_table,
    }};

    var refs: [0]CodeReference = undefined;

    var impact = try MigrationImpact.analyze(allocator, &commands, &refs);
    defer impact.deinit();

    try std.testing.expect(impact.safe_to_run);
    try std.testing.expectEqual(@as(usize, 0), impact.breaking_changes.items.len);
}
