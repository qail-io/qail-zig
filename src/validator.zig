//! Schema validator and fuzzy matching suggestions.
//!
//! Provides compile-time-like validation for QailCmd against a known schema.
//! Catches errors before they hit the wire protocol.

const std = @import("std");
const ast = @import("ast/mod.zig");

const Expr = ast.Expr;
const QailCmd = ast.QailCmd;

/// Validation error with structured information
pub const ValidationError = union(enum) {
    /// Table not found in schema
    table_not_found: struct {
        table: []const u8,
        suggestion: ?[]const u8,
    },
    /// Column not found in table
    column_not_found: struct {
        table: []const u8,
        column: []const u8,
        suggestion: ?[]const u8,
    },
    /// Type mismatch
    type_mismatch: struct {
        table: []const u8,
        column: []const u8,
        expected: []const u8,
        got: []const u8,
    },
    /// Invalid operator for column type
    invalid_operator: struct {
        column: []const u8,
        operator: []const u8,
        reason: []const u8,
    },

    /// Format error message
    pub fn format(self: ValidationError, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        switch (self) {
            .table_not_found => |e| {
                if (e.suggestion) |s| {
                    try writer.print("Table '{s}' not found. Did you mean '{s}'?", .{ e.table, s });
                } else {
                    try writer.print("Table '{s}' not found.", .{e.table});
                }
            },
            .column_not_found => |e| {
                if (e.suggestion) |s| {
                    try writer.print("Column '{s}' not found in table '{s}'. Did you mean '{s}'?", .{ e.column, e.table, s });
                } else {
                    try writer.print("Column '{s}' not found in table '{s}'.", .{ e.column, e.table });
                }
            },
            .type_mismatch => |e| {
                try writer.print("Type mismatch for '{s}.{s}': expected {s}, got {s}", .{ e.table, e.column, e.expected, e.got });
            },
            .invalid_operator => |e| {
                try writer.print("Invalid operator '{s}' for column '{s}': {s}", .{ e.operator, e.column, e.reason });
            },
        }

        return try buf.toOwnedSlice();
    }
};

/// Validates query elements against known schema
pub const Validator = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList([]const u8),
    columns: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: std.mem.Allocator) Validator {
        return .{
            .allocator = allocator,
            .tables = .empty,
            .columns = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *Validator) void {
        var iter = self.columns.valueIterator();
        while (iter.next()) |cols| {
            cols.deinit(self.allocator);
        }
        self.columns.deinit();
        self.tables.deinit(self.allocator);
    }

    /// Register a table and its columns
    pub fn addTable(self: *Validator, table: []const u8, cols: []const []const u8) !void {
        try self.tables.append(self.allocator, table);
        var col_list: std.ArrayList([]const u8) = .empty;
        for (cols) |col| {
            try col_list.append(self.allocator, col);
        }
        try self.columns.put(table, col_list);
    }

    /// Check if a table exists
    pub fn tableExists(self: *const Validator, table: []const u8) bool {
        for (self.tables.items) |t| {
            if (std.mem.eql(u8, t, table)) return true;
        }
        return false;
    }

    /// Get column names for a table
    pub fn columnNames(self: *const Validator, table: []const u8) ?[]const []const u8 {
        if (self.columns.get(table)) |cols| {
            return cols.items;
        }
        return null;
    }

    /// Validate table exists, returns error with suggestion if not
    pub fn validateTable(self: *const Validator, table: []const u8) ?ValidationError {
        if (self.tableExists(table)) return null;

        const suggestion = self.didYouMean(table, self.tables.items);
        return .{
            .table_not_found = .{
                .table = table,
                .suggestion = suggestion,
            },
        };
    }

    /// Validate column exists in table, returns error with suggestion if not
    pub fn validateColumn(self: *const Validator, table: []const u8, column: []const u8) ?ValidationError {
        // Skip validation if table doesn't exist
        if (!self.tableExists(table)) return null;

        // Always allow * and qualified names
        if (std.mem.eql(u8, column, "*") or std.mem.indexOf(u8, column, ".") != null) {
            return null;
        }

        if (self.columns.get(table)) |cols| {
            for (cols.items) |c| {
                if (std.mem.eql(u8, c, column)) return null;
            }
            // Column not found
            const suggestion = self.didYouMean(column, cols.items);
            return .{
                .column_not_found = .{
                    .table = table,
                    .column = column,
                    .suggestion = suggestion,
                },
            };
        }
        return null;
    }

    /// Validate an entire QailCmd against the schema
    pub fn validateCommand(self: *const Validator, cmd: *const QailCmd, allocator: std.mem.Allocator) !std.ArrayList(ValidationError) {
        var errors = std.ArrayList(ValidationError).init(allocator);

        // Check main table
        if (self.validateTable(cmd.table)) |err| {
            try errors.append(err);
        }

        // Check SELECT columns
        if (cmd.columns) |cols| {
            for (cols) |col| {
                if (extractColumnName(&col)) |name| {
                    if (self.validateColumn(cmd.table, name)) |err| {
                        try errors.append(err);
                    }
                }
            }
        }

        // Check WHERE clause columns
        if (cmd.where_clauses) |clauses| {
            for (clauses) |clause| {
                if (self.validateColumn(cmd.table, clause.column)) |err| {
                    try errors.append(err);
                }
            }
        }

        // Check JOIN tables
        if (cmd.joins) |joins| {
            for (joins) |join| {
                if (self.validateTable(join.table)) |err| {
                    try errors.append(err);
                }
            }
        }

        return errors;
    }

    /// Levenshtein distance-based fuzzy match
    fn didYouMean(self: *const Validator, input: []const u8, candidates: []const []const u8) ?[]const u8 {
        _ = self;
        var best_match: ?[]const u8 = null;
        var min_dist: usize = std.math.maxInt(usize);

        for (candidates) |cand| {
            const dist = levenshtein(input, cand);

            // Dynamic threshold based on length
            const threshold: usize = switch (input.len) {
                0...2 => 0, // Precise match only for very short strings
                3...5 => 2, // Allow 2 char diff
                else => 3, // Allow 3 char diff for longer strings
            };

            if (dist <= threshold and dist < min_dist) {
                min_dist = dist;
                best_match = cand;
            }
        }

        return best_match;
    }
};

/// Extract column name from Expr
fn extractColumnName(expr: *const Expr) ?[]const u8 {
    switch (expr.*) {
        .named => |n| return n,
        .aliased => |a| return a.name,
        .aggregate => |agg| return agg.column,
        else => return null,
    }
}

/// Calculate Levenshtein edit distance between two strings
fn levenshtein(a: []const u8, b: []const u8) usize {
    const m = a.len;
    const n = b.len;

    if (m == 0) return n;
    if (n == 0) return m;

    // Use a single row buffer (space optimization)
    var prev_row: [256]usize = undefined;
    var curr_row: [256]usize = undefined;

    // Initialize first row
    for (0..n + 1) |j| {
        prev_row[j] = j;
    }

    for (a, 0..) |char_a, i| {
        curr_row[0] = i + 1;

        for (b, 0..) |char_b, j| {
            const cost: usize = if (char_a == char_b) 0 else 1;
            curr_row[j + 1] = @min(
                curr_row[j] + 1, // insertion
                @min(
                    prev_row[j + 1] + 1, // deletion
                    prev_row[j] + cost, // substitution
                ),
            );
        }

        // Swap rows
        @memcpy(&prev_row, &curr_row);
    }

    return prev_row[n];
}

// ==================== Tests ====================

test "levenshtein distance" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("hello", "hello"));
    try std.testing.expectEqual(@as(usize, 1), levenshtein("hello", "hallo"));
    try std.testing.expectEqual(@as(usize, 2), levenshtein("users", "usr"));
    try std.testing.expectEqual(@as(usize, 1), levenshtein("users", "usrs"));
}

test "validator did you mean table" {
    const allocator = std.testing.allocator;
    var v = Validator.init(allocator);
    defer v.deinit();

    try v.addTable("users", &.{ "id", "name" });
    try v.addTable("orders", &.{ "id", "total" });

    // Valid table
    try std.testing.expect(v.validateTable("users") == null);

    // Typo - should suggest "users"
    const err = v.validateTable("usrs").?;
    try std.testing.expect(err.table_not_found.suggestion != null);
    try std.testing.expectEqualStrings("users", err.table_not_found.suggestion.?);
}

test "validator did you mean column" {
    const allocator = std.testing.allocator;
    var v = Validator.init(allocator);
    defer v.deinit();

    try v.addTable("users", &.{ "email", "password" });

    // Valid column
    try std.testing.expect(v.validateColumn("users", "email") == null);

    // Typo - should suggest "email"
    const err = v.validateColumn("users", "emial").?;
    try std.testing.expect(err.column_not_found.suggestion != null);
    try std.testing.expectEqualStrings("email", err.column_not_found.suggestion.?);
}

test "validator allows star and qualified" {
    const allocator = std.testing.allocator;
    var v = Validator.init(allocator);
    defer v.deinit();

    try v.addTable("users", &.{ "id", "name" });

    try std.testing.expect(v.validateColumn("users", "*") == null);
    try std.testing.expect(v.validateColumn("users", "users.id") == null);
}
