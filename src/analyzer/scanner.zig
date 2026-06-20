// Source code scanner for QAIL and SQL queries.
//
// Scans source files to find references to tables and columns
// used by your application, for migration impact analysis.

const std = @import("std");
const io_compat = @import("../runtime/io.zig");

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
        for (self.columns.items) |col| self.allocator.free(col);
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
        const stat = try std.Io.Dir.cwd().statFile(io_compat.runtimeIo(), path, .{});
        if (stat.kind == .directory) {
            try self.scanDir(path);
            return;
        }
        try self.scanFile(path);
    }

    /// Scan a directory recursively
    pub fn scanDir(self: *CodebaseScanner, dir_path: []const u8) !void {
        const io_iface = io_compat.runtimeIo();
        var dir = try std.Io.Dir.cwd().openDir(io_iface, dir_path, .{ .iterate = true });
        defer dir.close(io_iface);

        var iter = dir.iterate();
        while (try iter.next(io_iface)) |entry| {
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
                var sub_path: std.ArrayList(u8) = .empty;
                defer sub_path.deinit(self.allocator);
                try sub_path.appendSlice(self.allocator, dir_path);
                try sub_path.append(self.allocator, '/');
                try sub_path.appendSlice(self.allocator, entry.name);
                try self.scanDir(sub_path.items);
            } else if (entry.kind == .file) {
                // Check file extension
                if (isSourceFile(entry.name)) {
                    var file_path: std.ArrayList(u8) = .empty;
                    defer file_path.deinit(self.allocator);
                    try file_path.appendSlice(self.allocator, dir_path);
                    try file_path.append(self.allocator, '/');
                    try file_path.appendSlice(self.allocator, entry.name);
                    self.scanFile(file_path.items) catch continue;
                }
            }
        }
    }

    /// Scan a single file for references
    pub fn scanFile(self: *CodebaseScanner, file_path: []const u8) !void {
        const content = try std.Io.Dir.cwd().readFileAlloc(
            io_compat.runtimeIo(),
            file_path,
            self.allocator,
            std.Io.Limit.limited(1024 * 1024),
        );
        defer self.allocator.free(content);

        var bindings = try LiteralBindings.collect(self.allocator, content);
        defer bindings.deinit();

        var line_num: usize = 1;
        var line_start: usize = 0;
        var in_block_comment = false;

        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line = content[line_start..i];
                const scan_line = try stripBlockCommentsFromLine(self.allocator, line, &in_block_comment);
                defer self.allocator.free(scan_line);
                try self.scanLine(file_path, line_num, scan_line);
                line_start = i + 1;
                line_num += 1;
            }
        }
        // Handle last line without newline
        if (line_start < content.len) {
            const line = content[line_start..];
            const scan_line = try stripBlockCommentsFromLine(self.allocator, line, &in_block_comment);
            defer self.allocator.free(scan_line);
            try self.scanLine(file_path, line_num, scan_line);
        }

        try self.scanQailBuilderChains(file_path, content, &bindings);
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
        try self.findSqlTableCommand(file_path, line_num, line, "create", "table");
        try self.findSqlTableCommand(file_path, line_num, line, "alter", "table");
        try self.findSqlTableCommand(file_path, line_num, line, "drop", "table");
        try self.findSqlTableCommand(file_path, line_num, line, "truncate", "table");
        try self.findSqlPrivilegeCommand(file_path, line_num, line, "grant");
        try self.findSqlPrivilegeCommand(file_path, line_num, line, "revoke");
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
                        try columns.append(self.allocator, try self.allocator.dupe(u8, line[col_start..col_end]));
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

    fn scanQailBuilderChains(
        self: *CodebaseScanner,
        file_path: []const u8,
        content: []const u8,
        bindings: *const LiteralBindings,
    ) !void {
        var line_starts: std.ArrayList(usize) = .empty;
        defer line_starts.deinit(self.allocator);
        try line_starts.append(self.allocator, 0);
        for (content, 0..) |c, i| {
            if (c == '\n') try line_starts.append(self.allocator, i + 1);
        }

        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, content, idx, "Qail::")) |pos| {
            const action_start = pos + "Qail::".len;
            const action_end = findIdentifierEnd(content, action_start);
            if (action_end <= action_start) {
                idx = action_start;
                continue;
            }
            const action = content[action_start..action_end];
            if (!isQailBuilderAction(action)) {
                idx = action_end;
                continue;
            }

            const open_paren = skipWs(content, action_end);
            if (open_paren >= content.len or content[open_paren] != '(') {
                idx = action_end;
                continue;
            }

            const close_paren = findMatchingParen(content, open_paren) orelse {
                idx = open_paren + 1;
                continue;
            };
            const statement_end = findStatementEnd(content, close_paren + 1) orelse {
                idx = close_paren + 1;
                continue;
            };
            const chain = content[pos .. statement_end + 1];
            const first_arg = firstTopLevelArg(content[open_paren + 1 .. close_paren]);

            var tables = try self.resolveBuilderTables(first_arg, bindings);
            defer {
                for (tables.items) |t| self.allocator.free(t);
                tables.deinit(self.allocator);
            }
            if (tables.items.len == 0) {
                idx = statement_end + 1;
                continue;
            }

            var extracted_columns = try extractColumnsFromChain(self.allocator, chain, bindings);
            defer {
                for (extracted_columns.items) |c| self.allocator.free(c);
                extracted_columns.deinit(self.allocator);
            }

            const line_no = offsetToLine(line_starts.items, pos);
            const line_start = line_starts.items[line_no - 1];
            var line_end = content.len;
            if (line_no < line_starts.items.len) line_end = line_starts.items[line_no] - 1;
            const snippet = trimSnippet(content[line_start..line_end]);

            for (tables.items) |table| {
                var columns = std.ArrayList([]const u8).empty;
                for (extracted_columns.items) |col| {
                    try columns.append(self.allocator, try self.allocator.dupe(u8, col));
                }
                try self.refs.append(self.allocator, .{
                    .file = try self.allocator.dupe(u8, file_path),
                    .line = line_no,
                    .table = try self.allocator.dupe(u8, table),
                    .columns = columns,
                    .query_type = .qail,
                    .snippet = try self.allocator.dupe(u8, snippet),
                    .allocator = self.allocator,
                });
            }

            idx = statement_end + 1;
        }
    }

    fn resolveBuilderTables(self: *CodebaseScanner, first_arg: []const u8, bindings: *const LiteralBindings) !std.ArrayList([]const u8) {
        var tables = std.ArrayList([]const u8).empty;

        if (extractStringLiteral(self.allocator, first_arg)) |table| {
            try tables.append(self.allocator, table);
            return tables;
        } else |err| switch (err) {
            error.NotAStringLiteral => {},
            else => return err,
        }

        if (extractLookupIdent(first_arg)) |ident| {
            if (bindings.scalars.get(ident)) |values| {
                for (values.items) |val| {
                    try tables.append(self.allocator, try self.allocator.dupe(u8, val));
                }
            }
        }
        return tables;
    }

    /// Find SQL SELECT pattern
    fn findSqlSelect(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const scan_line = lineBeforeSourceComment(line);
        const sanitized = try sanitizeSqlForReferenceScan(self.allocator, scan_line);
        defer self.allocator.free(sanitized);
        const lower = try toLowerAlloc(self.allocator, sanitized);
        defer self.allocator.free(lower);

        var search_start: usize = 0;
        while (findKeyword(lower, "select", search_start)) |select_pos| {
            const from_pos = findKeyword(lower, "from", select_pos + "select".len) orelse {
                search_start = select_pos + "select".len;
                continue;
            };
            const table_start = skipSqlWs(lower, from_pos + "from".len);
            const table_end = findSqlIdentifierEnd(lower, table_start);
            if (table_end <= table_start) {
                search_start = select_pos + "select".len;
                continue;
            }

            var columns: std.ArrayList([]const u8) = .empty;
            defer freeStringList(self.allocator, &columns);
            try appendSqlProjectionColumns(&columns, self.allocator, sanitized[select_pos + "select".len .. from_pos]);
            try appendSqlJoinPredicateColumns(&columns, self.allocator, sanitized, lower, table_end);
            if (findKeyword(lower, "where", table_end)) |where_pos| {
                try appendSqlPredicateColumns(&columns, self.allocator, sanitized[where_pos + "where".len ..]);
            }
            try appendSqlClauseColumns(&columns, self.allocator, sanitized, lower, table_end, "group", &.{
                "having",
                "order",
                "limit",
                "offset",
                "fetch",
                "union",
                "returning",
            });
            try appendSqlClauseColumns(&columns, self.allocator, sanitized, lower, table_end, "having", &.{
                "order",
                "limit",
                "offset",
                "fetch",
                "union",
                "returning",
            });
            try appendSqlClauseColumns(&columns, self.allocator, sanitized, lower, table_end, "order", &.{
                "limit",
                "offset",
                "fetch",
                "union",
                "returning",
            });
            try appendSqlReturningColumns(&columns, self.allocator, sanitized, lower, table_end);

            try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower, columns.items);
            try self.appendSqlJoinedTableRefs(file_path, line_num, line, lower, table_end, columns.items);
            search_start = select_pos + "select".len;
        }
    }

    /// Find SQL INSERT pattern
    fn findSqlInsert(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const scan_line = lineBeforeSourceComment(line);
        const sanitized = try sanitizeSqlForReferenceScan(self.allocator, scan_line);
        defer self.allocator.free(sanitized);
        const lower = try toLowerAlloc(self.allocator, sanitized);
        defer self.allocator.free(lower);

        const insert_pos = findKeyword(lower, "insert", 0) orelse return;
        const into_pos = findKeyword(lower, "into", insert_pos + "insert".len) orelse return;
        const table_start = skipSqlWs(lower, into_pos + "into".len);
        const table_end = findSqlIdentifierEnd(lower, table_start);
        if (table_end <= table_start) return;

        var columns: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &columns);
        try appendSqlInsertColumns(&columns, self.allocator, sanitized, lower, table_end);
        try appendSqlReturningColumns(&columns, self.allocator, sanitized, lower, table_end);

        try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower, columns.items);
    }

    /// Find SQL UPDATE pattern
    fn findSqlUpdate(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const scan_line = lineBeforeSourceComment(line);
        const sanitized = try sanitizeSqlForReferenceScan(self.allocator, scan_line);
        defer self.allocator.free(sanitized);
        const lower = try toLowerAlloc(self.allocator, sanitized);
        defer self.allocator.free(lower);

        const update_pos = findKeyword(lower, "update", 0) orelse return;
        const set_pos = findKeyword(lower, "set", update_pos + "update".len) orelse return;
        const table_start = skipSqlWs(lower, update_pos + "update".len);
        const table_end = findSqlIdentifierEnd(lower, table_start);
        if (table_end <= table_start) return;

        var columns: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &columns);
        try appendSqlUpdateColumns(&columns, self.allocator, sanitized, lower, set_pos);
        if (findKeyword(lower, "where", set_pos + "set".len)) |where_pos| {
            try appendSqlPredicateColumns(&columns, self.allocator, sanitized[where_pos + "where".len ..]);
        }
        try appendSqlReturningColumns(&columns, self.allocator, sanitized, lower, table_end);

        try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower, columns.items);
        if (findKeyword(lower, "from", set_pos + "set".len)) |from_pos| {
            const from_start = from_pos + "from".len;
            const from_end = minKeywordPos(lower, from_start, &.{ "where", "returning" }) orelse lower.len;
            try self.appendSqlTableListRefs(file_path, line_num, line, lower, from_start, from_end, columns.items);
        }
    }

    /// Find SQL DELETE pattern
    fn findSqlDelete(self: *CodebaseScanner, file_path: []const u8, line_num: usize, line: []const u8) !void {
        const scan_line = lineBeforeSourceComment(line);
        const sanitized = try sanitizeSqlForReferenceScan(self.allocator, scan_line);
        defer self.allocator.free(sanitized);
        const lower = try toLowerAlloc(self.allocator, sanitized);
        defer self.allocator.free(lower);

        const delete_pos = findKeyword(lower, "delete", 0) orelse return;
        const from_pos = findKeyword(lower, "from", delete_pos + "delete".len) orelse return;
        const table_start = skipSqlWs(lower, from_pos + "from".len);
        const table_end = findSqlIdentifierEnd(lower, table_start);
        if (table_end <= table_start) return;

        var columns: std.ArrayList([]const u8) = .empty;
        defer freeStringList(self.allocator, &columns);
        if (findKeyword(lower, "where", table_end)) |where_pos| {
            try appendSqlPredicateColumns(&columns, self.allocator, sanitized[where_pos + "where".len ..]);
        }
        try appendSqlReturningColumns(&columns, self.allocator, sanitized, lower, table_end);

        try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower, columns.items);
        if (findKeyword(lower, "using", table_end)) |using_pos| {
            const using_start = using_pos + "using".len;
            const using_end = minKeywordPos(lower, using_start, &.{ "where", "returning" }) orelse lower.len;
            try self.appendSqlTableListRefs(file_path, line_num, line, lower, using_start, using_end, columns.items);
        }
    }

    fn appendSqlJoinedTableRefs(
        self: *CodebaseScanner,
        file_path: []const u8,
        line_num: usize,
        line: []const u8,
        lower_scan_line: []const u8,
        start: usize,
        raw_columns: []const []const u8,
    ) !void {
        var idx = start;
        while (findKeyword(lower_scan_line, "join", idx)) |join_pos| {
            var table_start = skipSqlWs(lower_scan_line, join_pos + "join".len);
            if (keywordAt(lower_scan_line, "lateral", table_start)) {
                table_start = skipSqlWs(lower_scan_line, table_start + "lateral".len);
            }
            if (table_start >= lower_scan_line.len or lower_scan_line[table_start] == '(') {
                idx = join_pos + "join".len;
                continue;
            }
            const table_end = findSqlIdentifierEnd(lower_scan_line, table_start);
            if (table_end > table_start) {
                try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower_scan_line, raw_columns);
                idx = table_end;
            } else {
                idx = join_pos + "join".len;
            }
        }
    }

    fn appendSqlTableListRefs(
        self: *CodebaseScanner,
        file_path: []const u8,
        line_num: usize,
        line: []const u8,
        lower_scan_line: []const u8,
        list_start: usize,
        list_end: usize,
        raw_columns: []const []const u8,
    ) !void {
        var start = list_start;
        while (start < list_end) {
            const comma = findTopLevelComma(lower_scan_line[0..list_end], start) orelse list_end;
            var table_start = skipSqlWs(lower_scan_line, start);
            if (keywordAt(lower_scan_line, "only", table_start)) {
                table_start = skipSqlWs(lower_scan_line, table_start + "only".len);
            }
            if (table_start < comma and lower_scan_line[table_start] != '(') {
                const table_end = findSqlIdentifierEnd(lower_scan_line, table_start);
                if (table_end > table_start and table_end <= comma) {
                    try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower_scan_line, raw_columns);
                }
            }
            start = comma + 1;
        }
    }

    fn findSqlTableCommand(
        self: *CodebaseScanner,
        file_path: []const u8,
        line_num: usize,
        line: []const u8,
        first_keyword: []const u8,
        second_keyword: []const u8,
    ) !void {
        const scan_line = lineBeforeSourceComment(line);
        const lower = try toLowerAlloc(self.allocator, scan_line);
        defer self.allocator.free(lower);

        const first_pos = findKeyword(lower, first_keyword, 0) orelse return;
        const second_pos = findKeyword(lower, second_keyword, first_pos + first_keyword.len) orelse return;
        var table_start = skipSqlWs(lower, second_pos + second_keyword.len);
        table_start = skipSqlIfExists(lower, table_start);
        if (table_start >= lower.len or lower[table_start] == '(') return;

        try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower, &.{});
    }

    fn findSqlPrivilegeCommand(
        self: *CodebaseScanner,
        file_path: []const u8,
        line_num: usize,
        line: []const u8,
        command_keyword: []const u8,
    ) !void {
        const scan_line = lineBeforeSourceComment(line);
        const lower = try toLowerAlloc(self.allocator, scan_line);
        defer self.allocator.free(lower);

        const command_pos = findKeyword(lower, command_keyword, 0) orelse return;
        const on_pos = findKeyword(lower, "on", command_pos + command_keyword.len) orelse return;
        var table_start = skipSqlWs(lower, on_pos + "on".len);
        const object_type_end = findSqlIdentifierEnd(lower, table_start);
        if (object_type_end <= table_start) return;

        const object_type = lower[table_start..object_type_end];
        if (std.ascii.eqlIgnoreCase(object_type, "table")) {
            table_start = skipSqlWs(lower, object_type_end);
        } else if (isNonTablePrivilegeTarget(object_type)) {
            return;
        }

        if (table_start >= lower.len or lower[table_start] == '(') return;
        try self.appendRawSqlTableRef(file_path, line_num, line, table_start, lower, &.{});
    }

    fn appendRawSqlTableRef(
        self: *CodebaseScanner,
        file_path: []const u8,
        line_num: usize,
        line: []const u8,
        table_start: usize,
        lower_scan_line: []const u8,
        raw_columns: []const []const u8,
    ) !void {
        const table_end = findSqlIdentifierEnd(lower_scan_line, table_start);
        if (table_end <= table_start) return;
        const alias = parseSqlOptionalTableAlias(lower_scan_line, table_end);
        const table = line[table_start..table_end];
        const alias_name = if (alias) |range| line[range.start..range.end] else null;

        var columns: std.ArrayList([]const u8) = .empty;
        errdefer freeStringList(self.allocator, &columns);
        for (raw_columns) |col| {
            try appendRawSqlColumnForTable(&columns, self.allocator, col, table, alias_name);
        }

        try self.refs.append(self.allocator, .{
            .file = try self.allocator.dupe(u8, file_path),
            .line = line_num,
            .table = try self.allocator.dupe(u8, table),
            .columns = columns,
            .query_type = .raw_sql,
            .snippet = try self.allocator.dupe(u8, trimSnippet(line)),
            .allocator = self.allocator,
        });
    }

    /// Get collected references
    pub fn getReferences(self: *const CodebaseScanner) []const CodeReference {
        return self.refs.items;
    }
};

const AliasRange = struct {
    start: usize,
    end: usize,
};

fn parseSqlOptionalTableAlias(lower: []const u8, table_end: usize) ?AliasRange {
    var cursor = skipSqlWs(lower, table_end);
    if (cursor >= lower.len) return null;

    if (keywordAt(lower, "as", cursor)) {
        cursor = skipSqlWs(lower, cursor + "as".len);
    }

    if (cursor >= lower.len or lower[cursor] == ',' or lower[cursor] == ')' or lower[cursor] == ';') return null;
    const alias_end = findSqlIdentifierEnd(lower, cursor);
    if (alias_end <= cursor) return null;
    const alias = lower[cursor..alias_end];
    if (isSqlTableSourceBoundary(alias)) return null;
    return .{ .start = cursor, .end = alias_end };
}

fn isSqlTableSourceBoundary(word: []const u8) bool {
    const words = [_][]const u8{
        "cross",     "do",    "except", "fetch",       "for",       "from",
        "full",      "group", "having", "inner",       "intersect", "join",
        "left",      "limit", "offset", "on",          "order",     "outer",
        "returning", "right", "set",    "tablesample", "to",        "union",
        "using",     "where", "window", "with",
    };
    for (words) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

fn appendRawSqlColumnForTable(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    raw_column: []const u8,
    table: []const u8,
    alias: ?[]const u8,
) !void {
    const normalized = std.mem.trim(u8, raw_column, " \t\r\n");
    if (normalized.len == 0) return;

    const dot = std.mem.lastIndexOfScalar(u8, normalized, '.') orelse {
        try appendUniqueOwned(columns, allocator, normalized);
        return;
    };
    const qualifier = std.mem.trim(u8, normalized[0..dot], " \t\r\n\"`");
    const column = std.mem.trim(u8, normalized[dot + 1 ..], " \t\r\n\"`");
    if (qualifier.len == 0 or column.len == 0) return;

    if (matchesSqlTableQualifier(qualifier, table, alias)) {
        try appendUniqueOwned(columns, allocator, column);
    }
}

fn matchesSqlTableQualifier(qualifier: []const u8, table: []const u8, alias: ?[]const u8) bool {
    if (alias) |alias_name| {
        if (std.ascii.eqlIgnoreCase(qualifier, alias_name)) return true;
    }
    if (std.ascii.eqlIgnoreCase(qualifier, table)) return true;
    if (std.ascii.eqlIgnoreCase(lastSqlPathSegment(qualifier), lastSqlPathSegment(table))) return true;
    return false;
}

fn lastSqlPathSegment(value: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, value, '.')) |dot| return value[dot + 1 ..];
    return value;
}

// ==================== Helper Functions ====================

/// Check if file is a source file worth scanning
fn isSourceFile(name: []const u8) bool {
    const extensions = [_][]const u8{
        ".rs",  ".ts",  ".tsx", ".js",  ".jsx", ".mjs", ".cjs",
        ".mts", ".cts", ".py",  ".sql", ".zig", ".go",  ".rb",
        ".php",
    };
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

fn lineBeforeSourceComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var in_backtick = false;
    var escape = false;

    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (escape) {
            escape = false;
            continue;
        }
        if (in_single or in_double or in_backtick) {
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (in_single and c == '\'') in_single = false;
            if (in_double and c == '"') in_double = false;
            if (in_backtick and c == '`') in_backtick = false;
            continue;
        }

        if (c == '\'') {
            in_single = true;
            continue;
        }
        if (c == '"') {
            in_double = true;
            continue;
        }
        if (c == '`') {
            in_backtick = true;
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return line[0..i];
        if (c == '#' and (i == 0 or std.ascii.isWhitespace(line[i - 1]))) return line[0..i];
        if (c == '/' and i + 1 < line.len and line[i + 1] == '*') return line[0..i];
    }

    return line;
}

fn stripBlockCommentsFromLine(allocator: std.mem.Allocator, line: []const u8, in_block_comment: *bool) ![]u8 {
    const out = try allocator.alloc(u8, line.len);
    errdefer allocator.free(out);

    var in_single = false;
    var in_double = false;
    var in_backtick = false;
    var escape = false;
    var i: usize = 0;

    while (i < line.len) {
        const c = line[i];

        if (in_block_comment.*) {
            out[i] = ' ';
            if (c == '*' and i + 1 < line.len and line[i + 1] == '/') {
                out[i + 1] = ' ';
                in_block_comment.* = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        out[i] = c;
        if (escape) {
            escape = false;
            i += 1;
            continue;
        }

        if (in_single or in_double or in_backtick) {
            if (c == '\\') {
                escape = true;
            } else if (in_single and c == '\'') {
                in_single = false;
            } else if (in_double and c == '"') {
                in_double = false;
            } else if (in_backtick and c == '`') {
                in_backtick = false;
            }
            i += 1;
            continue;
        }

        if (c == '\'') {
            in_single = true;
        } else if (c == '"') {
            in_double = true;
        } else if (c == '`') {
            in_backtick = true;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '*') {
            out[i] = ' ';
            out[i + 1] = ' ';
            in_block_comment.* = true;
            i += 2;
            continue;
        }

        i += 1;
    }

    return out;
}

fn sanitizeSqlForReferenceScan(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    errdefer allocator.free(out);

    var i: usize = 0;
    while (i < input.len) {
        if (startsWithBytes(input, i, "--")) {
            while (i < input.len) : (i += 1) {
                if (input[i] == '\n') {
                    out[i] = '\n';
                    i += 1;
                    break;
                }
                out[i] = ' ';
            }
            continue;
        }

        if (startsWithBytes(input, i, "/*")) {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            while (i < input.len) {
                if (startsWithBytes(input, i, "*/")) {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                    break;
                }
                out[i] = if (input[i] == '\n') '\n' else ' ';
                i += 1;
            }
            continue;
        }

        if (input[i] == '\'') {
            out[i] = ' ';
            i += 1;
            while (i < input.len) {
                out[i] = if (input[i] == '\n') '\n' else ' ';
                if (input[i] == '\'') {
                    i += 1;
                    if (i < input.len and input[i] == '\'') {
                        out[i] = ' ';
                        i += 1;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            continue;
        }

        if (sqlDollarQuoteTag(input, i)) |tag| {
            const tag_len = tag.len;
            var j: usize = 0;
            while (j < tag_len) : (j += 1) out[i + j] = ' ';
            i += tag_len;
            while (i < input.len) {
                if (startsWithBytes(input, i, tag)) {
                    j = 0;
                    while (j < tag_len) : (j += 1) out[i + j] = ' ';
                    i += tag_len;
                    break;
                }
                out[i] = if (input[i] == '\n') '\n' else ' ';
                i += 1;
            }
            continue;
        }

        out[i] = input[i];
        i += 1;
    }

    return out;
}

fn startsWithBytes(haystack: []const u8, idx: usize, needle: []const u8) bool {
    return idx + needle.len <= haystack.len and std.mem.eql(u8, haystack[idx .. idx + needle.len], needle);
}

fn sqlDollarQuoteTag(input: []const u8, start: usize) ?[]const u8 {
    if (start >= input.len or input[start] != '$') return null;
    if (start + 1 < input.len and input[start + 1] == '$') return input[start .. start + 2];

    var cursor = start + 1;
    if (cursor >= input.len) return null;
    const first = input[cursor];
    if (std.ascii.isDigit(first) or (!std.ascii.isAlphabetic(first) and first != '_')) return null;
    cursor += 1;

    while (cursor < input.len and (std.ascii.isAlphanumeric(input[cursor]) or input[cursor] == '_')) : (cursor += 1) {}
    if (cursor >= input.len or input[cursor] != '$') return null;
    return input[start .. cursor + 1];
}

fn isSqlWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn keywordBoundaryAt(s: []const u8, start: usize, len: usize) bool {
    if (start > 0 and isSqlWordByte(s[start - 1])) return false;
    const end = start + len;
    if (end < s.len and isSqlWordByte(s[end])) return false;
    return true;
}

fn findKeyword(s: []const u8, keyword: []const u8, start: usize) ?usize {
    var idx = start;
    while (std.mem.indexOfPos(u8, s, idx, keyword)) |pos| {
        if (keywordBoundaryAt(s, pos, keyword.len)) return pos;
        idx = pos + 1;
    }
    return null;
}

fn skipSqlWs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    return i;
}

fn skipSqlIfExists(s: []const u8, start: usize) usize {
    var idx = skipSqlWs(s, start);
    if (!keywordAt(s, "if", idx)) return idx;
    idx = skipSqlWs(s, idx + "if".len);
    if (keywordAt(s, "not", idx)) {
        idx = skipSqlWs(s, idx + "not".len);
    }
    if (!keywordAt(s, "exists", idx)) return start;
    return skipSqlWs(s, idx + "exists".len);
}

fn isNonTablePrivilegeTarget(target: []const u8) bool {
    return std.ascii.eqlIgnoreCase(target, "database") or
        std.ascii.eqlIgnoreCase(target, "schema") or
        std.ascii.eqlIgnoreCase(target, "sequence") or
        std.ascii.eqlIgnoreCase(target, "function") or
        std.ascii.eqlIgnoreCase(target, "procedure") or
        std.ascii.eqlIgnoreCase(target, "routine") or
        std.ascii.eqlIgnoreCase(target, "type");
}

fn isSqlIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isSqlIdentifierContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn findSqlIdentifierEnd(s: []const u8, start: usize) usize {
    var i = start;
    var part_start = true;
    var saw_part = false;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (part_start) {
            if (!isSqlIdentifierStart(c)) break;
            part_start = false;
            saw_part = true;
            continue;
        }

        if (isSqlIdentifierContinue(c)) continue;
        if (c == '.') {
            if (!saw_part or i + 1 >= s.len or !isSqlIdentifierStart(s[i + 1])) break;
            part_start = true;
            saw_part = false;
            continue;
        }
        break;
    }

    return if (part_start) start else i;
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn appendSqlProjectionColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    projection: []const u8,
) !void {
    var start: usize = 0;
    while (start < projection.len) {
        const comma = findTopLevelComma(projection, start) orelse projection.len;
        try appendSqlProjectionExpr(columns, allocator, projection[start..comma]);
        start = comma + 1;
    }
}

fn appendSqlProjectionExpr(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    expr_raw: []const u8,
) !void {
    var expr = std.mem.trim(u8, expr_raw, " \t\r\n;\"')");
    if (expr.len == 0) return;

    expr = try stripSqlDistinctProjectionPrefix(columns, allocator, expr);
    expr = try stripSqlProjectionAlias(allocator, expr);
    if (expr.len == 0) return;

    if (std.mem.eql(u8, expr, "*") or std.mem.endsWith(u8, expr, ".*")) {
        try appendSqlColumnReference(columns, allocator, expr);
        return;
    }

    if (containsSqlExpressionByte(expr)) {
        try appendSqlExpressionColumns(columns, allocator, expr);
        return;
    }

    try appendSqlColumnReference(columns, allocator, expr);
}

fn stripSqlDistinctProjectionPrefix(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    expr: []const u8,
) ![]const u8 {
    var trimmed = std.mem.trim(u8, expr, " \t\r\n");
    const lower = try toLowerAlloc(allocator, trimmed);
    defer allocator.free(lower);

    if (std.mem.startsWith(u8, lower, "distinct") and keywordBoundaryAt(lower, 0, "distinct".len)) {
        trimmed = std.mem.trim(u8, trimmed["distinct".len..], " \t\r\n");
        const lower_after_distinct = try toLowerAlloc(allocator, trimmed);
        defer allocator.free(lower_after_distinct);
        if (keywordAt(lower_after_distinct, "on", 0)) {
            const open = skipSqlWs(lower_after_distinct, "on".len);
            if (open < lower_after_distinct.len and lower_after_distinct[open] == '(') {
                if (findMatchingParen(lower_after_distinct, open)) |close| {
                    try appendSqlExpressionColumns(columns, allocator, trimmed[open + 1 .. close]);
                    return std.mem.trim(u8, trimmed[close + 1 ..], " \t\r\n");
                }
            }
        }
        return trimmed;
    }

    if (std.mem.startsWith(u8, lower, "all") and keywordBoundaryAt(lower, 0, "all".len)) {
        return std.mem.trim(u8, trimmed["all".len..], " \t\r\n");
    }

    return trimmed;
}

fn stripSqlProjectionAlias(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
    const lower = try toLowerAlloc(allocator, trimmed);
    defer allocator.free(lower);

    if (findKeyword(lower, "as", 0)) |as_pos| {
        return std.mem.trim(u8, trimmed[0..as_pos], " \t\r\n");
    }

    if (sqlTrailingProjectionAliasStart(trimmed, lower)) |alias_start| {
        return std.mem.trim(u8, trimmed[0..alias_start], " \t\r\n");
    }

    return trimmed;
}

fn sqlTrailingProjectionAliasStart(expr: []const u8, lower: []const u8) ?usize {
    const trimmed_end = std.mem.trimEnd(u8, expr, " \t\r\n").len;
    if (trimmed_end == 0) return null;

    var alias_start = trimmed_end;
    while (alias_start > 0 and isSqlIdentifierContinue(lower[alias_start - 1])) : (alias_start -= 1) {}
    if (alias_start == trimmed_end or alias_start == 0) return null;
    if (!isSqlIdentifierStart(lower[alias_start])) return null;
    if (!std.ascii.isWhitespace(lower[alias_start - 1])) return null;

    const base = std.mem.trimEnd(u8, expr[0..alias_start], " \t\r\n");
    if (base.len == 0) return null;
    if (projectionAliasBaseBlocksStrip(base)) return null;
    return alias_start;
}

fn projectionAliasBaseBlocksStrip(base: []const u8) bool {
    var end = base.len;
    while (end > 0 and !isSqlIdentifierContinue(base[end - 1])) : (end -= 1) {}
    if (end == 0) return false;
    var start = end;
    while (start > 0 and isSqlIdentifierContinue(base[start - 1])) : (start -= 1) {}
    const previous = base[start..end];
    return std.ascii.eqlIgnoreCase(previous, "at") or
        std.ascii.eqlIgnoreCase(previous, "collate") or
        std.ascii.eqlIgnoreCase(previous, "time") or
        std.ascii.eqlIgnoreCase(previous, "zone");
}

fn appendSqlClauseColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    sql: []const u8,
    lower: []const u8,
    search_start: usize,
    keyword: []const u8,
    comptime end_keywords: []const []const u8,
) !void {
    const clause_pos = findKeyword(lower, keyword, search_start) orelse return;
    const clause_start = clause_pos + keyword.len;
    const clause_end = minKeywordPos(lower, clause_start, end_keywords) orelse lower.len;
    if (clause_end <= clause_start) return;
    try appendSqlExpressionColumns(columns, allocator, sql[clause_start..clause_end]);
}

fn appendSqlExpressionColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    expr: []const u8,
) !void {
    const lower = try toLowerAlloc(allocator, expr);
    defer allocator.free(lower);

    var i: usize = 0;
    while (i < lower.len) {
        if (!isSqlIdentifierStart(lower[i])) {
            i += 1;
            continue;
        }

        const ident_end = findSqlIdentifierEnd(lower, i);
        if (ident_end <= i) {
            i += 1;
            continue;
        }

        const ident = expr[i..ident_end];
        const next = skipSqlWs(lower, ident_end);
        if (next < lower.len and lower[next] == '(') {
            i = ident_end;
            continue;
        }
        if (previousSqlKeywordIs(lower, i, "over") or previousSqlKeywordIs(lower, i, "collate")) {
            i = ident_end;
            continue;
        }
        if (shouldSkipSqlSyntaxIdentifier(lower, i, ident_end, ident)) {
            i = ident_end;
            continue;
        }

        try appendSqlColumnReference(columns, allocator, ident);
        i = ident_end;
    }
}

fn previousSqlKeywordIs(lower: []const u8, idx: usize, keyword: []const u8) bool {
    var end = idx;
    while (end > 0 and std.ascii.isWhitespace(lower[end - 1])) : (end -= 1) {}
    if (end < keyword.len) return false;
    const start = end - keyword.len;
    if (!std.mem.eql(u8, lower[start..end], keyword)) return false;
    return keywordBoundaryAt(lower, start, keyword.len);
}

fn shouldSkipSqlSyntaxIdentifier(lower: []const u8, start: usize, end: usize, ident: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(ident, "at")) {
        const next = skipSqlWs(lower, end);
        return keywordAt(lower, "time", next);
    }
    if (std.ascii.eqlIgnoreCase(ident, "time")) return previousSqlKeywordIs(lower, start, "at");
    if (std.ascii.eqlIgnoreCase(ident, "zone")) return previousSqlKeywordIs(lower, start, "time");
    if (std.ascii.eqlIgnoreCase(ident, "interval")) return previousSqlNonWsByte(lower, start) != null;
    if (std.ascii.eqlIgnoreCase(ident, "epoch")) {
        const next = skipSqlWs(lower, end);
        return keywordAt(lower, "from", next);
    }
    return false;
}

fn previousSqlNonWsByte(lower: []const u8, idx: usize) ?u8 {
    var cursor = idx;
    while (cursor > 0) {
        cursor -= 1;
        if (!std.ascii.isWhitespace(lower[cursor])) return lower[cursor];
    }
    return null;
}

fn appendSqlInsertColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    lower: []const u8,
    table_end: usize,
) !void {
    const open = skipSqlWs(lower, table_end);
    if (open >= lower.len or lower[open] != '(') return;
    const close = findMatchingParen(lower, open) orelse return;
    try appendSqlColumnList(columns, allocator, line[open + 1 .. close]);
}

fn appendSqlUpdateColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    lower: []const u8,
    set_pos: usize,
) !void {
    const set_start = set_pos + "set".len;
    const set_end = minKeywordPos(lower, set_start, &.{ "from", "where", "returning" }) orelse lower.len;
    var start = set_start;
    while (start < set_end) {
        const comma = findTopLevelComma(line[0..set_end], start) orelse set_end;
        const assignment = line[start..comma];
        if (findTopLevelScalar(assignment, '=')) |eq| {
            try appendSqlColumnReference(columns, allocator, assignment[0..eq]);
        }
        start = comma + 1;
    }
}

fn appendSqlPredicateColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    predicate: []const u8,
) !void {
    const lower = try toLowerAlloc(allocator, predicate);
    defer allocator.free(lower);

    var i: usize = 0;
    while (i < lower.len) {
        if (!isSqlIdentifierStart(lower[i])) {
            i += 1;
            continue;
        }
        const ident_end = findSqlIdentifierEnd(lower, i);
        if (ident_end <= i) {
            i += 1;
            continue;
        }

        const ident = predicate[i..ident_end];
        const next = skipSqlWs(lower, ident_end);
        if ((next < lower.len and isSqlPredicateOperatorAt(lower, next)) or isSqlPredicateOperatorBefore(lower, i)) {
            try appendSqlColumnReference(columns, allocator, ident);
        }
        i = ident_end;
    }
}

fn appendSqlJoinPredicateColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    lower: []const u8,
    start: usize,
) !void {
    var idx = start;
    while (findKeyword(lower, "join", idx)) |join_pos| {
        const on_pos = findKeyword(lower, "on", join_pos + "join".len) orelse {
            idx = join_pos + "join".len;
            continue;
        };
        const predicate_start = on_pos + "on".len;
        const predicate_end = minKeywordPos(lower, predicate_start, &.{
            "join",
            "where",
            "group",
            "order",
            "limit",
            "offset",
            "fetch",
            "returning",
        }) orelse lower.len;
        try appendSqlPredicateColumns(columns, allocator, line[predicate_start..predicate_end]);
        idx = predicate_end;
    }
}

fn appendSqlReturningColumns(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    lower: []const u8,
    start: usize,
) !void {
    const returning_pos = findKeyword(lower, "returning", start) orelse return;
    try appendSqlProjectionColumns(columns, allocator, line[returning_pos + "returning".len ..]);
}

fn appendSqlColumnList(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
) !void {
    var start: usize = 0;
    while (start < raw.len) {
        const comma = findTopLevelComma(raw, start) orelse raw.len;
        try appendSqlColumnReference(columns, allocator, raw[start..comma]);
        start = comma + 1;
    }
}

fn appendSqlColumnReference(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
) !void {
    const ident = std.mem.trim(u8, raw, " \t\r\n,;()");
    if (ident.len == 0) return;

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);

    var start: usize = 0;
    var saw_segment = false;
    while (start <= ident.len) {
        const dot = std.mem.indexOfScalarPos(u8, ident, start, '.') orelse ident.len;
        const segment = std.mem.trim(u8, ident[start..dot], " \t\r\n\"`");
        if (segment.len == 0) return;
        if (isSqlReservedWord(segment)) return;

        const lower = try toLowerAlloc(allocator, segment);
        defer allocator.free(lower);
        if (!std.mem.eql(u8, segment, "*") and findSqlIdentifierEnd(lower, 0) != lower.len) return;

        if (saw_segment) try normalized.append(allocator, '.');
        try normalized.appendSlice(allocator, segment);
        saw_segment = true;

        if (dot == ident.len) break;
        start = dot + 1;
    }

    if (normalized.items.len == 0) return;
    try appendUniqueOwned(columns, allocator, normalized.items);
}

fn appendSqlColumnIdentifier(
    columns: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
) !void {
    var ident = std.mem.trim(u8, raw, " \t\r\n,;()");
    if (ident.len == 0) return;

    if (std.mem.lastIndexOfScalar(u8, ident, '.')) |dot| {
        ident = ident[dot + 1 ..];
    }
    ident = std.mem.trim(u8, ident, " \t\r\n\"`");
    if (ident.len == 0) return;
    if (isSqlReservedWord(ident)) return;

    const lower = try toLowerAlloc(allocator, ident);
    defer allocator.free(lower);
    if (findSqlIdentifierEnd(lower, 0) != lower.len) return;

    try appendUniqueOwned(columns, allocator, ident);
}

fn containsSqlExpressionByte(expr: []const u8) bool {
    for (expr) |c| {
        switch (c) {
            '*', '(', ')', '\'', '"', '+', '-', '/', '%', '|', '&', '?', ':', '$', '[', ']' => return true,
            else => {},
        }
    }
    return false;
}

fn isSqlPredicateOperatorAt(lower: []const u8, pos: usize) bool {
    if (pos >= lower.len) return false;
    switch (lower[pos]) {
        '=', '<', '>', '!' => return true,
        else => {},
    }
    return keywordAt(lower, "is", pos) or
        keywordAt(lower, "in", pos) or
        keywordAt(lower, "like", pos) or
        keywordAt(lower, "ilike", pos) or
        keywordAt(lower, "between", pos);
}

fn isSqlPredicateOperatorBefore(lower: []const u8, pos: usize) bool {
    var idx = pos;
    while (idx > 0 and std.ascii.isWhitespace(lower[idx - 1])) : (idx -= 1) {}
    if (idx == 0) return false;

    switch (lower[idx - 1]) {
        '=', '<', '>', '!' => return true,
        else => {},
    }

    const before = lower[0..idx];
    return endsWithSqlKeyword(before, "is") or
        endsWithSqlKeyword(before, "in") or
        endsWithSqlKeyword(before, "like") or
        endsWithSqlKeyword(before, "ilike");
}

fn endsWithSqlKeyword(value: []const u8, keyword: []const u8) bool {
    if (value.len < keyword.len) return false;
    const start = value.len - keyword.len;
    if (!std.mem.eql(u8, value[start..], keyword)) return false;
    return keywordBoundaryAt(value, start, keyword.len);
}

fn keywordAt(s: []const u8, keyword: []const u8, pos: usize) bool {
    if (pos + keyword.len > s.len) return false;
    if (!std.mem.eql(u8, s[pos .. pos + keyword.len], keyword)) return false;
    return keywordBoundaryAt(s, pos, keyword.len);
}

fn minKeywordPos(s: []const u8, start: usize, comptime keywords: []const []const u8) ?usize {
    var best: ?usize = null;
    inline for (keywords) |keyword| {
        if (findKeyword(s, keyword, start)) |pos| {
            if (best == null or pos < best.?) best = pos;
        }
    }
    return best;
}

fn findTopLevelComma(s: []const u8, start: usize) ?usize {
    return findTopLevelByte(s, start, ',');
}

fn findTopLevelScalar(s: []const u8, target: u8) ?usize {
    return findTopLevelByte(s, 0, target);
}

fn findTopLevelByte(s: []const u8, start: usize, target: u8) ?usize {
    var paren: i32 = 0;
    var in_single = false;
    var in_double = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_single) {
            if (c == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
                i += 1;
            } else if (c == '\'') {
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (c == '"' and i + 1 < s.len and s[i + 1] == '"') {
                i += 1;
            } else if (c == '"') {
                in_double = false;
            }
            continue;
        }

        switch (c) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '(' => paren += 1,
            ')' => {
                if (paren > 0) paren -= 1;
            },
            else => {
                if (c == target and paren == 0) return i;
            },
        }
    }
    return null;
}

fn isSqlReservedWord(s: []const u8) bool {
    const words = [_][]const u8{
        "all",          "and",               "as",        "asc",         "avg",
        "between",      "by",                "case",      "collate",     "conflict",
        "constraint",   "count",             "cross",     "cube",        "current_date",
        "current_time", "current_timestamp", "delete",    "desc",        "distinct",
        "do",           "else",              "end",       "excluded",    "exists",
        "false",        "filter",            "following", "from",        "full",
        "group",        "grouping",          "groups",    "having",      "ilike",
        "in",           "inner",             "insert",    "into",        "is",
        "join",         "last",              "left",      "like",        "limit",
        "localtime",    "localtimestamp",    "max",       "min",         "natural",
        "not",          "nothing",           "null",      "nulls",       "offset",
        "on",           "or",                "order",     "ordinality",  "outer",
        "over",         "partition",         "preceding", "range",       "returning",
        "right",        "rollup",            "row",       "rows",        "select",
        "set",          "sets",              "sum",       "tablesample", "then",
        "ties",         "true",              "unbounded", "union",       "update",
        "using",        "values",            "when",      "where",       "window",
        "with",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(s, word)) return true;
    }
    return false;
}

fn skipWs(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    return i;
}

fn isQailBuilderAction(name: []const u8) bool {
    return std.mem.eql(u8, name, "get") or
        std.mem.eql(u8, name, "set") or
        std.mem.eql(u8, name, "add") or
        std.mem.eql(u8, name, "del") or
        std.mem.eql(u8, name, "put") or
        std.mem.eql(u8, name, "make");
}

fn findMatchingParen(s: []const u8, open_idx: usize) ?usize {
    if (open_idx >= s.len or s[open_idx] != '(') return null;
    var depth: usize = 0;
    var i = open_idx;
    var in_string = false;
    var escape = false;
    var line_comment = false;
    var block_comment = false;

    while (i < s.len) : (i += 1) {
        const c = s[i];

        if (line_comment) {
            if (c == '\n') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (c == '*' and i + 1 < s.len and s[i + 1] == '/') {
                block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
            line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
            block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }

        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findStatementEnd(s: []const u8, start: usize) ?usize {
    var i = start;
    var paren: i32 = 0;
    var bracket: i32 = 0;
    var brace: i32 = 0;
    var in_string = false;
    var escape = false;
    var line_comment = false;
    var block_comment = false;

    while (i < s.len) : (i += 1) {
        const c = s[i];

        if (line_comment) {
            if (c == '\n') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (c == '*' and i + 1 < s.len and s[i + 1] == '/') {
                block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '/' and i + 1 < s.len and s[i + 1] == '/') {
            line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
            block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }

        switch (c) {
            '(' => paren += 1,
            ')' => paren -= 1,
            '[' => bracket += 1,
            ']' => bracket -= 1,
            '{' => brace += 1,
            '}' => brace -= 1,
            ';' => if (paren <= 0 and bracket <= 0 and brace <= 0) return i,
            else => {},
        }
    }
    return null;
}

fn offsetToLine(line_starts: []const usize, offset: usize) usize {
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (line_starts[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) 1 else lo;
}

fn firstTopLevelArg(args: []const u8) []const u8 {
    var i: usize = 0;
    var paren: i32 = 0;
    var bracket: i32 = 0;
    var brace: i32 = 0;
    var in_string = false;
    var escape = false;
    while (i < args.len) : (i += 1) {
        const c = args[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        switch (c) {
            '(' => paren += 1,
            ')' => paren -= 1,
            '[' => bracket += 1,
            ']' => bracket -= 1,
            '{' => brace += 1,
            '}' => brace -= 1,
            ',' => if (paren == 0 and bracket == 0 and brace == 0) {
                return std.mem.trim(u8, args[0..i], " \t\r\n");
            },
            else => {},
        }
    }
    return std.mem.trim(u8, args, " \t\r\n");
}

fn extractLookupIdent(arg: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, arg, " \t\r\n");
    while (std.mem.startsWith(u8, s, "&")) s = std.mem.trimStart(u8, s[1..], " \t");
    if (s.len == 0) return null;
    if (s[0] == '"') return null;

    var seg = s;
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| seg = s[dot + 1 ..];
    if (std.mem.lastIndexOf(u8, seg, "::")) |sep| seg = seg[sep + 2 ..];
    seg = std.mem.trim(u8, seg, " \t\r\n()[]");
    if (seg.len == 0) return null;
    if (!isIdentifier(seg)) return null;
    return seg;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const StringList = std.ArrayList([]const u8);

const LiteralBindings = struct {
    allocator: std.mem.Allocator,
    scalars: std.StringHashMap(StringList),
    arrays: std.StringHashMap(StringList),

    fn init(allocator: std.mem.Allocator) LiteralBindings {
        return .{
            .allocator = allocator,
            .scalars = std.StringHashMap(StringList).init(allocator),
            .arrays = std.StringHashMap(StringList).init(allocator),
        };
    }

    fn deinit(self: *LiteralBindings) void {
        var it_scalars = self.scalars.iterator();
        while (it_scalars.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |v| self.allocator.free(v);
            entry.value_ptr.deinit(self.allocator);
        }
        self.scalars.deinit();

        var it_arrays = self.arrays.iterator();
        while (it_arrays.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |v| self.allocator.free(v);
            entry.value_ptr.deinit(self.allocator);
        }
        self.arrays.deinit();
    }

    fn collect(allocator: std.mem.Allocator, content: []const u8) !LiteralBindings {
        var out = LiteralBindings.init(allocator);
        errdefer out.deinit();

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(allocator);
        var split = std.mem.splitScalar(u8, content, '\n');
        while (split.next()) |line| try lines.append(allocator, line);

        var i: usize = 0;
        while (i < lines.items.len) {
            const line = std.mem.trim(u8, lines.items[i], " \t\r\n");

            if (std.mem.startsWith(u8, line, "let ")) {
                var stmt: std.ArrayList(u8) = .empty;
                defer stmt.deinit(allocator);
                try stmt.appendSlice(allocator, line);

                var j = i + 1;
                while (j < lines.items.len and std.mem.indexOfScalar(u8, stmt.items, ';') == null) : (j += 1) {
                    try stmt.append(allocator, '\n');
                    try stmt.appendSlice(allocator, std.mem.trim(u8, lines.items[j], " \t\r\n"));
                }
                try out.recordLetOrConst(stmt.items, true);
                i = if (j > i) j else i + 1;
                continue;
            }

            if (looksLikeConstBinding(line)) {
                var stmt: std.ArrayList(u8) = .empty;
                defer stmt.deinit(allocator);
                try stmt.appendSlice(allocator, line);

                var j = i + 1;
                while (j < lines.items.len and std.mem.indexOfScalar(u8, stmt.items, ';') == null) : (j += 1) {
                    try stmt.append(allocator, '\n');
                    try stmt.appendSlice(allocator, std.mem.trim(u8, lines.items[j], " \t\r\n"));
                }
                try out.recordLetOrConst(stmt.items, false);
                i = if (j > i) j else i + 1;
                continue;
            }

            i += 1;
        }

        return out;
    }

    fn recordLetOrConst(self: *LiteralBindings, stmt: []const u8, is_let: bool) !void {
        const parsed = if (is_let) parseLetBinding(stmt) else parseConstBinding(stmt);
        if (parsed == null) return;
        const binding = parsed.?;

        if (extractStringLiteral(self.allocator, binding.rhs)) |scalar| {
            try self.appendBinding(&self.scalars, binding.name, scalar);
        } else |err| switch (err) {
            error.NotAStringLiteral => {},
            else => return err,
        }

        var array_vals = try extractArrayStringLiterals(self.allocator, binding.rhs);
        defer {
            for (array_vals.items) |v| self.allocator.free(v);
            array_vals.deinit(self.allocator);
        }
        if (array_vals.items.len > 0) {
            for (array_vals.items) |v| {
                try self.appendBinding(&self.arrays, binding.name, try self.allocator.dupe(u8, v));
            }
        }
    }

    fn appendBinding(
        self: *LiteralBindings,
        map: *std.StringHashMap(StringList),
        name: []const u8,
        value_owned: []const u8,
    ) !void {
        var gop = try map.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, value_owned)) {
                self.allocator.free(value_owned);
                return;
            }
        }
        try gop.value_ptr.append(self.allocator, value_owned);
    }
};

const ParsedBinding = struct {
    name: []const u8,
    rhs: []const u8,
};

fn parseLetBinding(stmt: []const u8) ?ParsedBinding {
    var s = std.mem.trim(u8, stmt, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "let ")) return null;
    s = std.mem.trimStart(u8, s["let ".len..], " \t");
    if (std.mem.startsWith(u8, s, "mut ")) s = std.mem.trimStart(u8, s["mut ".len..], " \t");
    if (s.len == 0 or s[0] == '(') return null;

    const name_end = findIdentifierEnd(s, 0);
    if (name_end == 0) return null;
    const name = s[0..name_end];

    var rest = std.mem.trimStart(u8, s[name_end..], " \t");
    if (rest.len > 0 and rest[0] == ':') {
        if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
            rest = rest[eq..];
        } else return null;
    }
    if (rest.len == 0 or rest[0] != '=') return null;
    var rhs = std.mem.trim(u8, rest[1..], " \t\r\n");
    rhs = std.mem.trimEnd(u8, rhs, "; \t\r\n");
    return .{ .name = name, .rhs = rhs };
}

fn looksLikeConstBinding(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "const ",
        "static ",
        "pub const ",
        "pub static ",
        "pub(crate) const ",
        "pub(crate) static ",
        "pub(super) const ",
        "pub(super) static ",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

fn parseConstBinding(stmt: []const u8) ?ParsedBinding {
    var s = std.mem.trim(u8, stmt, " \t\r\n");
    const prefixes = [_][]const u8{
        "pub(crate) ",
        "pub(super) ",
        "pub ",
        "const ",
        "static ",
    };
    var rounds: usize = 0;
    while (rounds < 6) : (rounds += 1) {
        var advanced = false;
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, s, p)) {
                s = std.mem.trimStart(u8, s[p.len..], " \t");
                advanced = true;
            }
        }
        if (!advanced) break;
    }
    if (std.mem.startsWith(u8, s, "mut ")) s = std.mem.trimStart(u8, s["mut ".len..], " \t");
    const name_end = findIdentifierEnd(s, 0);
    if (name_end == 0) return null;
    const name = s[0..name_end];

    var rest = std.mem.trimStart(u8, s[name_end..], " \t");
    if (rest.len > 0 and rest[0] == ':') {
        if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
            rest = rest[eq..];
        } else return null;
    }
    if (rest.len == 0 or rest[0] != '=') return null;
    var rhs = std.mem.trim(u8, rest[1..], " \t\r\n");
    rhs = std.mem.trimEnd(u8, rhs, "; \t\r\n");
    return .{ .name = name, .rhs = rhs };
}

fn extractStringLiteral(allocator: std.mem.Allocator, expr: []const u8) ![]const u8 {
    const s = std.mem.trim(u8, expr, " \t\r\n");
    if (s.len == 0 or s[0] != '"') return error.NotAStringLiteral;

    var i: usize = 1;
    var escape = false;
    while (i < s.len) : (i += 1) {
        if (escape) {
            escape = false;
            continue;
        }
        if (s[i] == '\\') {
            escape = true;
            continue;
        }
        if (s[i] == '"') {
            return allocator.dupe(u8, s[1..i]);
        }
    }
    return error.NotAStringLiteral;
}

fn extractArrayStringLiterals(allocator: std.mem.Allocator, expr: []const u8) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).empty;
    if (std.mem.indexOfScalar(u8, expr, '[') == null) return out;

    var in_string = false;
    var escape = false;
    var line_comment = false;
    var block_comment = false;
    var str_start: usize = 0;
    var i: usize = 0;

    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (line_comment) {
            if (c == '\n') line_comment = false;
            continue;
        }
        if (block_comment) {
            if (c == '*' and i + 1 < expr.len and expr[i + 1] == '/') {
                block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') {
                try appendUniqueOwned(&out, allocator, expr[str_start..i]);
                in_string = false;
            }
            continue;
        }

        if (c == '/' and i + 1 < expr.len and expr[i + 1] == '/') {
            line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < expr.len and expr[i + 1] == '*') {
            block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            str_start = i + 1;
            continue;
        }
    }
    return out;
}

fn appendUniqueOwned(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn extractColumnsFromChain(
    allocator: std.mem.Allocator,
    chain: []const u8,
    bindings: *const LiteralBindings,
) !std.ArrayList([]const u8) {
    var columns = std.ArrayList([]const u8).empty;
    var idx: usize = 0;

    while (std.mem.indexOfPos(u8, chain, idx, ".")) |dot| {
        const name_start = dot + 1;
        const name_end = findIdentifierEnd(chain, name_start);
        if (name_end <= name_start) {
            idx = name_start;
            continue;
        }
        const name = chain[name_start..name_end];
        const open = skipWs(chain, name_end);
        if (open >= chain.len or chain[open] != '(') {
            idx = name_end;
            continue;
        }
        const close = findMatchingParen(chain, open) orelse {
            idx = open + 1;
            continue;
        };

        const args = chain[open + 1 .. close];
        const first_arg = firstTopLevelArg(args);

        if (std.mem.eql(u8, name, "column")) {
            if (extractStringLiteral(allocator, first_arg)) |col| {
                try appendSqlColumnIdentifier(&columns, allocator, col);
                allocator.free(col);
            } else |_| {}
        } else if (std.mem.eql(u8, name, "columns") or std.mem.eql(u8, name, "returning")) {
            var vals = try extractArrayStringLiterals(allocator, first_arg);
            defer {
                for (vals.items) |v| allocator.free(v);
                vals.deinit(allocator);
            }
            if (vals.items.len == 0) {
                if (extractLookupIdent(first_arg)) |ident| {
                    if (bindings.arrays.get(ident)) |arr| {
                        for (arr.items) |v| try appendSqlColumnIdentifier(&columns, allocator, v);
                    }
                }
            } else {
                for (vals.items) |v| try appendSqlColumnIdentifier(&columns, allocator, v);
            }
        } else if (isSingleColumnMethod(name)) {
            if (extractStringLiteral(allocator, first_arg)) |col| {
                try appendSqlColumnIdentifier(&columns, allocator, col);
                allocator.free(col);
            } else |_| {}
        }

        idx = close + 1;
    }

    return columns;
}

fn isSingleColumnMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "filter") or
        std.mem.eql(u8, name, "eq") or
        std.mem.eql(u8, name, "ne") or
        std.mem.eql(u8, name, "gt") or
        std.mem.eql(u8, name, "lt") or
        std.mem.eql(u8, name, "gte") or
        std.mem.eql(u8, name, "lte") or
        std.mem.eql(u8, name, "like") or
        std.mem.eql(u8, name, "ilike") or
        std.mem.eql(u8, name, "where_eq") or
        std.mem.eql(u8, name, "order_by") or
        std.mem.eql(u8, name, "order_desc") or
        std.mem.eql(u8, name, "order_asc") or
        std.mem.eql(u8, name, "in_vals") or
        std.mem.eql(u8, name, "is_null") or
        std.mem.eql(u8, name, "is_not_null") or
        std.mem.eql(u8, name, "set_value") or
        std.mem.eql(u8, name, "set_coalesce") or
        std.mem.eql(u8, name, "set_coalesce_opt");
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
    try expectHasColumn(scanner.refs.items[0].columns.items, "name");
    try expectHasColumn(scanner.refs.items[0].columns.items, "id");
}

test "sql scanner requires keyword boundaries" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "let preselected = \"preselect name from users\";");
    try scanner.scanLine("test.rs", 2, "let updated_at = \"last_update set users\";");
    try scanner.scanLine("test.rs", 3, "let deleted = \"notdeleted from users\";");

    try std.testing.expectEqual(@as(usize, 0), scanner.refs.items.len);
}

test "sql scanner ignores source comments outside string literals" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "// SELECT id FROM users");
    try scanner.scanLine("test.py", 2, "# INSERT INTO users VALUES (1)");
    try scanner.scanLine("test.rs", 3, "let sql = \"SELECT id FROM users\"; // SELECT id FROM ignored");
    try scanner.scanLine("test.rs", 4, "let raw = r#\"SELECT id FROM audit.events\"#;");

    try std.testing.expectEqual(@as(usize, 2), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("audit.events", scanner.refs.items[1].table);
}

test "scanFile ignores multiline block comments" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    const content =
        \\/*
        \\const q = "get::block_users:'id'";
        \\const s = "DELETE FROM block_users";
        \\*/
        \\const sql = "SELECT id FROM users";
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.ts", .data = content });

    var scan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const scan_path_len = try tmp.dir.realPathFile(std.testing.io, "scan.ts", &scan_path_buf);
    try scanner.scanFile(scan_path_buf[0..scan_path_len]);

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqual(QueryType.raw_sql, scanner.refs.items[0].query_type);
}

test "sql scanner keeps qualified table references" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"SELECT id FROM tenant.users WHERE id = $1\")");
    try scanner.scanLine("test.rs", 2, "sqlx::query(\"INSERT INTO audit.events(id) VALUES ($1)\")");
    try scanner.scanLine("test.rs", 3, "sqlx::query(\"UPDATE billing.invoices SET status = $1\")");
    try scanner.scanLine("test.rs", 4, "sqlx::query(\"DELETE FROM archive.logs WHERE id = $1\")");

    try std.testing.expectEqual(@as(usize, 4), scanner.refs.items.len);
    try std.testing.expectEqualStrings("tenant.users", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("audit.events", scanner.refs.items[1].table);
    try std.testing.expectEqualStrings("billing.invoices", scanner.refs.items[2].table);
    try std.testing.expectEqualStrings("archive.logs", scanner.refs.items[3].table);
}

test "sql scanner extracts raw select projection and predicate columns" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"SELECT users.email AS user_email, status FROM public.users WHERE id = $1 AND deleted_at IS NULL\")");

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    const ref = scanner.refs.items[0];
    try std.testing.expectEqualStrings("public.users", ref.table);
    try expectHasColumn(ref.columns.items, "email");
    try expectHasColumn(ref.columns.items, "status");
    try expectHasColumn(ref.columns.items, "id");
    try expectHasColumn(ref.columns.items, "deleted_at");
}

test "sql scanner tracks joined raw sql table references" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"SELECT users.email, orders.total FROM users JOIN orders ON users.id = orders.user_id WHERE orders.status = $1\")",
    );

    try std.testing.expectEqual(@as(usize, 2), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("orders", scanner.refs.items[1].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "email");
    try expectHasColumn(scanner.refs.items[0].columns.items, "id");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "total");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "status");
    try expectHasColumn(scanner.refs.items[1].columns.items, "total");
    try expectHasColumn(scanner.refs.items[1].columns.items, "user_id");
    try expectHasColumn(scanner.refs.items[1].columns.items, "status");
    try expectMissingColumn(scanner.refs.items[1].columns.items, "email");
}

test "sql scanner scopes alias qualified join columns" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"SELECT u.email, o.total FROM users AS u JOIN orders o ON u.id = o.user_id WHERE o.status = $1\")",
    );

    try std.testing.expectEqual(@as(usize, 2), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("orders", scanner.refs.items[1].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "email");
    try expectHasColumn(scanner.refs.items[0].columns.items, "id");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "total");
    try expectHasColumn(scanner.refs.items[1].columns.items, "total");
    try expectHasColumn(scanner.refs.items[1].columns.items, "user_id");
    try expectHasColumn(scanner.refs.items[1].columns.items, "status");
    try expectMissingColumn(scanner.refs.items[1].columns.items, "email");
}

test "sql scanner tracks multiple select sources on one raw sql line" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"WITH recent AS (SELECT user_id FROM orders WHERE status = $1) SELECT users.email FROM users JOIN recent ON recent.user_id = users.id\")",
    );

    try expectHasTable(scanner.refs.items, "orders");
    try expectHasTable(scanner.refs.items, "users");
}

test "sql scanner extracts raw insert update delete columns" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"INSERT INTO audit.events(id, event_type) VALUES ($1, $2) RETURNING created_at\")");
    try scanner.scanLine("test.rs", 2, "sqlx::query(\"UPDATE billing.invoices SET status = $1, total = $2 WHERE id = $3 RETURNING updated_at\")");
    try scanner.scanLine("test.rs", 3, "sqlx::query(\"DELETE FROM archive.logs WHERE id = $1 AND archived_at IS NOT NULL\")");

    try std.testing.expectEqual(@as(usize, 3), scanner.refs.items.len);

    try expectHasColumn(scanner.refs.items[0].columns.items, "id");
    try expectHasColumn(scanner.refs.items[0].columns.items, "event_type");
    try expectHasColumn(scanner.refs.items[0].columns.items, "created_at");

    try expectHasColumn(scanner.refs.items[1].columns.items, "status");
    try expectHasColumn(scanner.refs.items[1].columns.items, "total");
    try expectHasColumn(scanner.refs.items[1].columns.items, "id");
    try expectHasColumn(scanner.refs.items[1].columns.items, "updated_at");

    try expectHasColumn(scanner.refs.items[2].columns.items, "id");
    try expectHasColumn(scanner.refs.items[2].columns.items, "archived_at");
}

test "sql scanner tracks update from and delete using sources" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"UPDATE orders SET status = $1 FROM users WHERE users.id = orders.user_id\")");
    try scanner.scanLine("test.rs", 2, "sqlx::query(\"DELETE FROM order_items USING orders WHERE orders.id = order_items.order_id\")");

    try std.testing.expectEqual(@as(usize, 4), scanner.refs.items.len);
    try std.testing.expectEqualStrings("orders", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("users", scanner.refs.items[1].table);
    try std.testing.expectEqualStrings("order_items", scanner.refs.items[2].table);
    try std.testing.expectEqualStrings("orders", scanner.refs.items[3].table);
}

test "sql scanner does not leak qualified update source columns into target" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"UPDATE orders o SET status = p.status FROM payments p WHERE o.payment_id = p.id AND p.state = $1\")",
    );

    try std.testing.expectEqual(@as(usize, 2), scanner.refs.items.len);
    try std.testing.expectEqualStrings("orders", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("payments", scanner.refs.items[1].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "status");
    try expectHasColumn(scanner.refs.items[0].columns.items, "payment_id");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "state");
    try expectHasColumn(scanner.refs.items[1].columns.items, "status");
    try expectHasColumn(scanner.refs.items[1].columns.items, "id");
    try expectHasColumn(scanner.refs.items[1].columns.items, "state");
}

test "sql scanner does not leak qualified delete using source columns into target" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"DELETE FROM sessions s USING users u WHERE s.user_id = u.id AND u.disabled = true\")",
    );

    try std.testing.expectEqual(@as(usize, 2), scanner.refs.items.len);
    try std.testing.expectEqualStrings("sessions", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("users", scanner.refs.items[1].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "user_id");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "disabled");
    try expectHasColumn(scanner.refs.items[1].columns.items, "id");
    try expectHasColumn(scanner.refs.items[1].columns.items, "disabled");
}

test "sql scanner sanitizes sql comments and dollar quoted text" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"SELECT id FROM users WHERE note = $$SELECT secret FROM ghosts;$$ AND status = 'active' -- SELECT id FROM ignored\")",
    );

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "id");
    try expectHasColumn(scanner.refs.items[0].columns.items, "note");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "secret");
}

test "sql scanner extracts raw select expression projection columns" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"SELECT lower(email) email_lower, COUNT(*) FILTER (WHERE active) AS active_count FROM users WHERE status = $1 ORDER BY created_at DESC\")",
    );

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "email");
    try expectHasColumn(scanner.refs.items[0].columns.items, "active");
    try expectHasColumn(scanner.refs.items[0].columns.items, "status");
    try expectHasColumn(scanner.refs.items[0].columns.items, "created_at");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "email_lower");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "active_count");
}

test "sql scanner extracts distinct on and grouping expression columns" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine(
        "test.rs",
        1,
        "sqlx::query(\"SELECT DISTINCT ON (tenant_id) tenant_id, status, sum(total) FROM orders GROUP BY ROLLUP(region, product), CUBE(channel, status) HAVING sum(total) > 0 ORDER BY tenant_id, created_at DESC\")",
    );

    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    try std.testing.expectEqualStrings("orders", scanner.refs.items[0].table);
    try expectHasColumn(scanner.refs.items[0].columns.items, "tenant_id");
    try expectHasColumn(scanner.refs.items[0].columns.items, "status");
    try expectHasColumn(scanner.refs.items[0].columns.items, "total");
    try expectHasColumn(scanner.refs.items[0].columns.items, "region");
    try expectHasColumn(scanner.refs.items[0].columns.items, "product");
    try expectHasColumn(scanner.refs.items[0].columns.items, "channel");
    try expectHasColumn(scanner.refs.items[0].columns.items, "created_at");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "rollup");
    try expectMissingColumn(scanner.refs.items[0].columns.items, "cube");
}

test "sql scanner tracks raw ddl table references" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"ALTER TABLE users ADD COLUMN risk_score integer\")");
    try scanner.scanLine("test.rs", 2, "sqlx::query(\"DROP TABLE IF EXISTS archive.logs\")");
    try scanner.scanLine("test.rs", 3, "sqlx::query(\"CREATE TABLE IF NOT EXISTS audit.events(id uuid)\")");
    try scanner.scanLine("test.rs", 4, "sqlx::query(\"TRUNCATE TABLE sessions\")");

    try std.testing.expectEqual(@as(usize, 4), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("archive.logs", scanner.refs.items[1].table);
    try std.testing.expectEqualStrings("audit.events", scanner.refs.items[2].table);
    try std.testing.expectEqualStrings("sessions", scanner.refs.items[3].table);
}

test "sql scanner tracks raw table privilege references" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    try scanner.scanLine("test.rs", 1, "sqlx::query(\"GRANT SELECT ON users TO app_role\")");
    try scanner.scanLine("test.rs", 2, "sqlx::query(\"REVOKE UPDATE ON TABLE billing.invoices FROM app_role\")");
    try scanner.scanLine("test.rs", 3, "sqlx::query(\"GRANT USAGE ON SCHEMA public TO app_role\")");

    try std.testing.expectEqual(@as(usize, 2), scanner.refs.items.len);
    try std.testing.expectEqualStrings("users", scanner.refs.items[0].table);
    try std.testing.expectEqualStrings("billing.invoices", scanner.refs.items[1].table);
}

test "isSourceFile" {
    try std.testing.expect(isSourceFile("main.rs"));
    try std.testing.expect(isSourceFile("app.ts"));
    try std.testing.expect(isSourceFile("app.tsx"));
    try std.testing.expect(isSourceFile("query.mjs"));
    try std.testing.expect(isSourceFile("query.cjs"));
    try std.testing.expect(isSourceFile("query.mts"));
    try std.testing.expect(isSourceFile("query.cts"));
    try std.testing.expect(isSourceFile("query.sql"));
    try std.testing.expect(isSourceFile("server.zig"));
    try std.testing.expect(!isSourceFile("readme.md"));
    try std.testing.expect(!isSourceFile("config.json"));
}

test "scanFile resolves const array columns with inline comments in qail builder chain" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    const content =
        \\const ORDER_COLUMNS: &[&str] = &[
        \\    "id",                 // 0
        \\    "invoice_number",     // 1
        \\    "status",             // 2
        \\    "total_amount",       // 3
        \\    "created_at",         // 4
        \\];
        \\
        \\fn list(uid: &str) {
        \\    let _cmd = qail_core::ast::Qail::get("orders")
        \\        .columns(ORDER_COLUMNS)
        \\        .eq("user_id", uid)
        \\        .order_by("created_at", qail_core::ast::SortOrder::Desc);
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.rs", .data = content });

    var scan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const scan_path_len = try tmp.dir.realPathFile(std.testing.io, "scan.rs", &scan_path_buf);
    try scanner.scanFile(scan_path_buf[0..scan_path_len]);
    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    const ref = scanner.refs.items[0];
    try std.testing.expectEqualStrings("orders", ref.table);

    try expectHasColumn(ref.columns.items, "id");
    try expectHasColumn(ref.columns.items, "invoice_number");
    try expectHasColumn(ref.columns.items, "status");
    try expectHasColumn(ref.columns.items, "total_amount");
    try expectHasColumn(ref.columns.items, "created_at");
    try expectHasColumn(ref.columns.items, "user_id");
}

test "scanFile resolves const scalar table binding in qail builder chain" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    const content =
        \\const USERS_TABLE: &str = "users";
        \\
        \\fn demo(uid: &str) {
        \\    let _cmd = qail_core::ast::Qail::get(USERS_TABLE)
        \\        .column("id")
        \\        .eq("id", uid);
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.rs", .data = content });

    var scan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const scan_path_len = try tmp.dir.realPathFile(std.testing.io, "scan.rs", &scan_path_buf);
    try scanner.scanFile(scan_path_buf[0..scan_path_len]);
    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    const ref = scanner.refs.items[0];
    try std.testing.expectEqualStrings("users", ref.table);
    try expectHasColumn(ref.columns.items, "id");
}

test "scanFile extracts returning and qualified qail builder columns" {
    const allocator = std.testing.allocator;
    var scanner = CodebaseScanner.init(allocator);
    defer scanner.deinit();

    const content =
        \\const RETURNING_COLUMNS: &[&str] = &[
        \\    "orders.id",
        \\    "orders.created_at",
        \\];
        \\
        \\fn update(status: &str) {
        \\    let _cmd = qail_core::ast::Qail::set("orders")
        \\        .set_value("orders.status", status)
        \\        .eq("orders.id", "order-1")
        \\        .returning(RETURNING_COLUMNS);
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.rs", .data = content });

    var scan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const scan_path_len = try tmp.dir.realPathFile(std.testing.io, "scan.rs", &scan_path_buf);
    try scanner.scanFile(scan_path_buf[0..scan_path_len]);
    try std.testing.expectEqual(@as(usize, 1), scanner.refs.items.len);
    const ref = scanner.refs.items[0];
    try std.testing.expectEqualStrings("orders", ref.table);

    try expectHasColumn(ref.columns.items, "status");
    try expectHasColumn(ref.columns.items, "id");
    try expectHasColumn(ref.columns.items, "created_at");
}

fn expectHasColumn(columns: []const []const u8, target: []const u8) !void {
    for (columns) |col| {
        if (std.mem.eql(u8, col, target)) return;
    }
    return error.ExpectedColumnMissing;
}

fn expectMissingColumn(columns: []const []const u8, target: []const u8) !void {
    for (columns) |col| {
        if (std.mem.eql(u8, col, target)) return error.UnexpectedColumnPresent;
    }
}

fn expectHasTable(refs: []const CodeReference, target: []const u8) !void {
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.table, target)) return;
    }
    return error.ExpectedTableMissing;
}
