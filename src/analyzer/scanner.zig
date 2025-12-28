// Source code scanner for QAIL and SQL queries.
//
// Scans source files to find references to tables and columns
// used by your application, for migration impact analysis.

const std = @import("std");

/// Type of query found in source code
pub const QueryType = enum {
    /// Native QAIL query (get::, set::, del::, add::)
    qail,
    /// Raw SQL query (SELECT, INSERT, UPDATE, DELETE)
    raw_sql,
};

/// A reference to a query found in source code
pub const CodeReference = struct {
    /// File path where reference was found
    file: []const u8,
    /// Line number (1-indexed)
    line: usize,
    /// Table name referenced
    table: []const u8,
    /// Column names referenced (if any)
    columns: std.ArrayList([]const u8),
    /// Type of query
    query_type: QueryType,
    /// Code snippet containing the reference
    snippet: []const u8,
    /// Allocator for owned memory
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CodeReference) void {
        // Free all allocator.dupe'd strings
        self.allocator.free(self.file);
        self.allocator.free(self.table);
        self.allocator.free(self.snippet);
        self.columns.deinit(self.allocator);
    }
};

/// Scanner for finding QAIL and SQL references in source code
pub const CodebaseScanner = struct {
    allocator: std.mem.Allocator,
    /// Collected references
    refs: std.ArrayList(CodeReference),

    pub fn init(allocator: std.mem.Allocator) CodebaseScanner {
        return .{
            .allocator = allocator,
            .refs = .empty,
        };
    }

    pub fn deinit(self: *CodebaseScanner) void {
        for (self.refs.items) |*ref| {
            ref.deinit();
        }
        self.refs.deinit(self.allocator);
    }

    /// Scan a directory or file for QAIL/SQL references
    pub fn scan(self: *CodebaseScanner, path: []const u8) !void {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            if (err == error.IsDir) {
                try self.scanDir(path);
                return;
            }
            return err;
        };
        _ = stat;
        try self.scanFile(path);
    }

    /// Scan a directory recursively
    pub fn scanDir(self: *CodebaseScanner, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Skip common non-source directories
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, "target") or
                    std.mem.eql(u8, entry.name, "node_modules") or
                    std.mem.eql(u8, entry.name, ".git") or
                    std.mem.eql(u8, entry.name, "zig-cache") or
                    std.mem.eql(u8, entry.name, "zig-out") or
                    std.mem.eql(u8, entry.name, "__pycache__"))
                {
                    continue;
                }
                // Recursively scan subdirectory
                var sub_path = std.ArrayList(u8).init(self.allocator);
                defer sub_path.deinit();
                try sub_path.appendSlice(dir_path);
                try sub_path.append('/');
                try sub_path.appendSlice(entry.name);
                try self.scanDir(sub_path.items);
            } else if (entry.kind == .file) {
                // Check file extension
                if (isSourceFile(entry.name)) {
                    var file_path = std.ArrayList(u8).init(self.allocator);
                    defer file_path.deinit();
                    try file_path.appendSlice(dir_path);
                    try file_path.append('/');
                    try file_path.appendSlice(entry.name);
                    self.scanFile(file_path.items) catch continue;
                }
            }
        }
    }

    /// Scan a single file for references
    pub fn scanFile(self: *CodebaseScanner, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        var line_num: usize = 1;
        var line_start: usize = 0;

        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line = content[line_start..i];
                try self.scanLine(file_path, line_num, line);
                line_start = i + 1;
                line_num += 1;
            }
        }
        // Handle last line without newline
        if (line_start < content.len) {
            const line = content[line_start..];
            try self.scanLine(file_path, line_num, line);
        }
    }

    /// Scan a single line for patterns
    fn scanLine(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        // Check for QAIL patterns: get::table, set::table, del::table, add::table
        try self.findQailPattern(file_path, line_num, line, "get::");
        try self.findQailPattern(file_path, line_num, line, "set::");
        try self.findQailPattern(file_path, line_num, line, "del::");
        try self.findQailPattern(file_path, line_num, line, "add::");

        // Check for SQL patterns
        try self.findSqlSelect(file_path, line_num, line);
        try self.findSqlInsert(file_path, line_num, line);
        try self.findSqlUpdate(file_path, line_num, line);
        try self.findSqlDelete(file_path, line_num, line);
    }

    /// Find QAIL pattern like "get::users"
    fn findQailPattern(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8, pattern: []const u8) !void {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, line, idx, pattern)) |pos| {
            const table_start = pos + pattern.len;
            const table_end = findIdentifierEnd(line, table_start);
            if (table_end > table_start) {
                const table = line[table_start..table_end];

                var columns: std.ArrayList([]const u8) = .empty;
                // Extract column references (single quote prefix: 'column)
                var col_idx = table_end;
                while (std.mem.indexOfPos(u8, line, col_idx, "'")) |col_pos| {
                    const col_start = col_pos + 1;
                    const col_end = findIdentifierEnd(line, col_start);
                    if (col_end > col_start) {
                        try columns.append(self.allocator, line[col_start..col_end]);
                        col_idx = col_end;
                    } else {
                        break;
                    }
                }

                try self.refs.append(self.allocator, .{
                    .file = try self.allocator.dupe(u8, file_path),
                    .line = line_num,
                    .table = try self.allocator.dupe(u8, table),
                    .columns = columns,
                    .query_type = .qail,
                    .snippet = try self.allocator.dupe(u8, trimSnippet(line)),
                    .allocator = self.allocator,
                });
            }
            idx = pos + pattern.len;
        }
    }

    /// Find SQL SELECT pattern
    fn findSqlSelect(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        // Case-insensitive search for "SELECT ... FROM table"
        const lower = try toLowerAlloc(self.allocator, line);
        defer self.allocator.free(lower);

        if (std.mem.indexOf(u8, lower, "select")) |_| {
            if (std.mem.indexOf(u8, lower, " from ")) |from_pos| {
                const table_start = from_pos + 6;
                const table_end = findIdentifierEnd(lower, table_start);
                if (table_end > table_start) {
                    try self.refs.append(self.allocator, .{
                        .file = try self.allocator.dupe(u8, file_path),
                        .line = line_num,
                        .table = try self.allocator.dupe(u8, line[table_start..table_end]),
                        .columns = .empty,
                        .query_type = .raw_sql,
                        .snippet = try self.allocator.dupe(u8, trimSnippet(line)),
                        .allocator = self.allocator,
                    });
                }
            }
        }
    }

    /// Find SQL INSERT pattern
    fn findSqlInsert(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const lower = try toLowerAlloc(self.allocator, line);
        defer self.allocator.free(lower);

        if (std.mem.indexOf(u8, lower, "insert into ")) |pos| {
            const table_start = pos + 12;
            const table_end = findIdentifierEnd(lower, table_start);
            if (table_end > table_start) {
                try self.refs.append(self.allocator, .{
                    .file = try self.allocator.dupe(u8, file_path),
                    .line = line_num,
                    .table = try self.allocator.dupe(u8, line[table_start..table_end]),
                    .columns = .empty,
                    .query_type = .raw_sql,
                    .snippet = try self.allocator.dupe(u8, trimSnippet(line)),
                    .allocator = self.allocator,
                });
            }
        }
    }

    /// Find SQL UPDATE pattern
    fn findSqlUpdate(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const lower = try toLowerAlloc(self.allocator, line);
        defer self.allocator.free(lower);

        if (std.mem.indexOf(u8, lower, "update ")) |pos| {
            if (std.mem.indexOf(u8, lower, " set ")) |_| {
                const table_start = pos + 7;
                const table_end = findIdentifierEnd(lower, table_start);
                if (table_end > table_start) {
                    try self.refs.append(self.allocator, .{
                        .file = try self.allocator.dupe(u8, file_path),
                        .line = line_num,
                        .table = try self.allocator.dupe(u8, line[table_start..table_end]),
                        .columns = .empty,
                        .query_type = .raw_sql,
                        .snippet = try self.allocator.dupe(u8, trimSnippet(line)),
                        .allocator = self.allocator,
                    });
                }
            }
        }
    }

    /// Find SQL DELETE pattern
    fn findSqlDelete(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const lower = try toLowerAlloc(self.allocator, line);
        defer self.allocator.free(lower);

        if (std.mem.indexOf(u8, lower, "delete from ")) |pos| {
            const table_start = pos + 12;
            const table_end = findIdentifierEnd(lower, table_start);
            if (table_end > table_start) {
                try self.refs.append(self.allocator, .{
                    .file = try self.allocator.dupe(u8, file_path),
                    .line = line_num,
                    .table = try self.allocator.dupe(u8, line[table_start..table_end]),
                    .columns = .empty,
                    .query_type = .raw_sql,
                    .snippet = try self.allocator.dupe(u8, trimSnippet(line)),
                    .allocator = self.allocator,
                });
            }
        }
    }

    /// Get collected references
    pub fn getReferences(self: *const CodebaseScanner) []const CodeReference {
        return self.refs.items;
    }
};

// ==================== Helper Functions ====================

/// Check if file is a source file worth scanning
fn isSourceFile(name: []const u8) bool {
    const extensions = [_][]const u8{ ".rs", ".ts", ".js", ".py", ".zig", ".go", ".rb", ".php" };
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Find end of identifier (alphanumeric + underscore)
fn findIdentifierEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    }
    return i;
}

/// Trim snippet to max 60 chars
fn trimSnippet(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len <= 60) return trimmed;
    return trimmed[0..60];
}

/// Convert to lowercase (allocates)
fn toLowerAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

// ==================== Tests ====================

test "find qail pattern" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "let result = qail!(\"get::users:'name'email\");");

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqual(QueryType.qail, scanner.refs.items[0].query_type);
}

test "find sql select pattern" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"SELECT name FROM users WHERE id = $1\")");

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqual(QueryType.raw_sql, scanner.refs.items[0].query_type);
}

test "isSourceFile" {
    try std.testing.expect(isSourceFile("main.rs"));
    try std.testing.expect(isSourceFile("app.ts"));
    try std.testing.expect(isSourceFile("server.zig"));
    try std.testing.expect(!isSourceFile("readme.md"));
    try std.testing.expect(!isSourceFile("config.json"));
}
