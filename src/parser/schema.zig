// Schema Parser for .qail format
//
// Parses schema definitions like:
// ```
// table users (
//   id uuid primary_key,
//   email text not null,
//   name text,
//   created_at timestamp
// )
// ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

/// Schema containing all table definitions
pub const Schema = struct {
    tables: std.ArrayList(TableDef),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Schema {
        return .{
            .tables = std.ArrayList(TableDef).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Schema) void {
        for (self.tables.items) |*table| {
            table.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
    }

    /// Parse a schema from .qail format
    pub fn parse(allocator: Allocator, input: []const u8) !Schema {
        var parser = Parser.init(allocator, input);
        return parser.parseSchema();
    }

    /// Find a table by name (case-insensitive)
    pub fn findTable(self: *const Schema, name: []const u8) ?*const TableDef {
        for (self.tables.items) |*table| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) {
                return table;
            }
        }
        return null;
    }
};

/// Table definition
pub const TableDef = struct {
    name: []const u8,
    columns: std.ArrayList(ColumnDef),

    pub fn init(allocator: Allocator, name: []const u8) TableDef {
        return .{
            .name = name,
            .columns = std.ArrayList(ColumnDef).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *TableDef, allocator: Allocator) void {
        for (self.columns.items) |*col| {
            col.deinit(allocator);
        }
        self.columns.deinit(allocator);
        allocator.free(self.name);
    }

    /// Find a column by name (case-insensitive)
    pub fn findColumn(self: *const TableDef, name: []const u8) ?*const ColumnDef {
        for (self.columns.items) |*col| {
            if (std.ascii.eqlIgnoreCase(col.name, name)) {
                return col;
            }
        }
        return null;
    }

    /// Generate CREATE TABLE DDL
    pub fn toDdl(self: *const TableDef, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        const writer = buf.writer(allocator);

        try writer.print("CREATE TABLE IF NOT EXISTS {s} (\n", .{self.name});

        for (self.columns.items, 0..) |col, i| {
            try writer.print("    {s} {s}", .{ col.name, col.typ });

            if (col.type_params) |params| {
                try writer.print("({s})", .{params});
            }
            if (col.is_array) {
                try writer.writeAll("[]");
            }
            if (col.primary_key) {
                try writer.writeAll(" PRIMARY KEY");
            }
            if (!col.nullable and !col.primary_key and !col.is_serial) {
                try writer.writeAll(" NOT NULL");
            }
            if (col.unique and !col.primary_key) {
                try writer.writeAll(" UNIQUE");
            }
            if (col.default_value) |default| {
                try writer.print(" DEFAULT {s}", .{default});
            }
            if (col.references) |refs| {
                try writer.print(" REFERENCES {s}", .{refs});
            }
            if (col.check) |check_expr| {
                try writer.print(" CHECK({s})", .{check_expr});
            }

            if (i < self.columns.items.len - 1) {
                try writer.writeAll(",");
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll(")");
        return buf.toOwnedSlice(allocator);
    }
};

/// Column definition
pub const ColumnDef = struct {
    name: []const u8,
    typ: []const u8,
    type_params: ?[]const u8 = null,
    is_array: bool = false,
    is_serial: bool = false,
    nullable: bool = true,
    primary_key: bool = false,
    unique: bool = false,
    references: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    check: ?[]const u8 = null,

    pub fn deinit(self: *ColumnDef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.typ);
        if (self.type_params) |p| allocator.free(p);
        if (self.references) |r| allocator.free(r);
        if (self.default_value) |d| allocator.free(d);
        if (self.check) |c| allocator.free(c);
    }
};

// ============================================================================
// Parser
// ============================================================================

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize = 0,

    pub fn init(allocator: Allocator, input: []const u8) Parser {
        return .{
            .allocator = allocator,
            .input = input,
        };
    }

    fn remaining(self: *Parser) []const u8 {
        return self.input[self.pos..];
    }

    fn current(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) self.pos += 1;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (self.pos + 1 < self.input.len and self.input[self.pos] == '-' and self.input[self.pos + 1] == '-') {
                // Skip -- comment until end of line
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else if (c == '#') {
                // Skip # comment until end of line
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        const start = self.pos;

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos == start) {
            return error.ExpectedIdentifier;
        }

        return self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn expectChar(self: *Parser, c: u8) !void {
        self.skipWhitespace();
        if (self.current() != c) {
            return error.UnexpectedChar;
        }
        self.advance();
    }

    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        self.skipWhitespace();
        const rem = self.remaining();
        if (rem.len >= keyword.len) {
            if (std.ascii.eqlIgnoreCase(rem[0..keyword.len], keyword)) {
                // Check word boundary
                if (rem.len == keyword.len or !std.ascii.isAlphanumeric(rem[keyword.len])) {
                    self.pos += keyword.len;
                    return true;
                }
            }
        }
        return false;
    }

    fn parseTypeInfo(self: *Parser) !struct {
        name: []const u8,
        params: ?[]const u8,
        is_array: bool,
        is_serial: bool,
    } {
        self.skipWhitespace();
        const start = self.pos;

        // Parse type name
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos == start) {
            return error.ExpectedType;
        }

        const type_name = try self.allocator.dupe(u8, self.input[start..self.pos]);

        // Check for type params like (255) or (10, 2)
        var params: ?[]const u8 = null;
        if (self.current() == '(') {
            self.advance();
            const param_start = self.pos;
            while (self.current()) |c| {
                if (c == ')') break;
                self.advance();
            }
            params = try self.allocator.dupe(u8, self.input[param_start..self.pos]);
            self.advance(); // skip )
        }

        // Check for array suffix []
        var is_array = false;
        if (self.pos + 1 < self.input.len and self.input[self.pos] == '[' and self.input[self.pos + 1] == ']') {
            is_array = true;
            self.pos += 2;
        }

        const is_serial = std.ascii.eqlIgnoreCase(type_name, "serial") or
            std.ascii.eqlIgnoreCase(type_name, "bigserial") or
            std.ascii.eqlIgnoreCase(type_name, "smallserial");

        return .{
            .name = type_name,
            .params = params,
            .is_array = is_array,
            .is_serial = is_serial,
        };
    }

    const ConstraintResult = struct {
        primary_key: bool = false,
        nullable: bool = true,
        unique: bool = false,
        references: ?[]const u8 = null,
        default_value: ?[]const u8 = null,
        check: ?[]const u8 = null,
    };

    fn parseConstraints(self: *Parser) !ConstraintResult {
        var result = ConstraintResult{};

        // Parse constraint keywords until we hit , or ) or } or newline
        while (true) {
            self.skipWhitespace();
            const c = self.current() orelse break;
            if (c == ',' or c == ')' or c == '}' or c == '\n') break;

            if (self.matchKeyword("primary_key") or self.matchKeyword("primary")) {
                _ = self.matchKeyword("key"); // optional "key" part
                result.primary_key = true;
                result.nullable = false;
            } else if (self.matchKeyword("not_null") or self.matchKeyword("not")) {
                _ = self.matchKeyword("null");
                result.nullable = false;
            } else if (self.matchKeyword("unique")) {
                result.unique = true;
            } else if (self.matchKeyword("references")) {
                self.skipWhitespace();
                const ref_start = self.pos;
                // Parse table(column) - track parens depth
                var paren_depth: usize = 0;
                while (self.current()) |ch| {
                    if (ch == '(') {
                        paren_depth += 1;
                        self.advance();
                    } else if (ch == ')') {
                        if (paren_depth > 0) {
                            paren_depth -= 1;
                            self.advance();
                            if (paren_depth == 0) break; // End of references(col)
                        } else {
                            break; // End of table definition
                        }
                    } else if ((ch == ' ' or ch == '\t' or ch == ',' or ch == '}' or ch == '\n') and paren_depth == 0) {
                        break;
                    } else {
                        self.advance();
                    }
                }
                result.references = try self.allocator.dupe(u8, self.input[ref_start..self.pos]);
            } else if (self.matchKeyword("default")) {
                self.skipWhitespace();
                const def_start = self.pos;
                // Parse default value - track parens for function calls like NOW()
                var paren_depth: usize = 0;
                while (self.current()) |ch| {
                    if (ch == '(') {
                        paren_depth += 1;
                        self.advance();
                    } else if (ch == ')') {
                        if (paren_depth > 0) {
                            paren_depth -= 1;
                            self.advance();
                        } else {
                            break; // End of table definition
                        }
                    } else if ((ch == ' ' or ch == '\t' or ch == ',' or ch == '}' or ch == '\n') and paren_depth == 0) {
                        break;
                    } else {
                        self.advance();
                    }
                }
                result.default_value = try self.allocator.dupe(u8, self.input[def_start..self.pos]);
            } else if (self.matchKeyword("check")) {
                try self.expectChar('(');
                const check_start = self.pos;
                var depth: usize = 1;
                while (self.current()) |ch| {
                    if (ch == '(') depth += 1;
                    if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    self.advance();
                }
                result.check = try self.allocator.dupe(u8, self.input[check_start..self.pos]);
                self.advance(); // skip closing )
            } else {
                // Unknown token - only skip if it's not a terminator
                const ch = self.current() orelse break;
                if (ch == '\n' or ch == ',' or ch == ')' or ch == '}') break;
                self.advance();
            }
        }

        return result;
    }

    fn parseColumn(self: *Parser) !ColumnDef {
        const name = try self.parseIdentifier();
        const type_info = try self.parseTypeInfo();
        const constraints = try self.parseConstraints();

        return ColumnDef{
            .name = name,
            .typ = type_info.name,
            .type_params = type_info.params,
            .is_array = type_info.is_array,
            .is_serial = type_info.is_serial,
            .nullable = if (type_info.is_serial) false else constraints.nullable,
            .primary_key = constraints.primary_key,
            .unique = constraints.unique,
            .references = constraints.references,
            .default_value = constraints.default_value,
            .check = constraints.check,
        };
    }

    fn parseTable(self: *Parser) !TableDef {
        if (!self.matchKeyword("table")) {
            return error.ExpectedTable;
        }

        const name = try self.parseIdentifier();
        var table = TableDef.init(self.allocator, name);

        // Support both () and {} for table definitions (like qail.rs uses {})
        self.skipWhitespace();
        const open_char = self.current() orelse return error.ExpectedOpenBrace;
        const close_char: u8 = if (open_char == '{') '}' else if (open_char == '(') ')' else return error.ExpectedOpenBrace;
        self.advance();

        while (true) {
            self.skipWhitespace(); // Skips spaces, tabs, newlines, and comments
            if (self.current() == close_char) break;
            if (self.current() == null) break;

            const col = try self.parseColumn();
            try table.columns.append(self.allocator, col);

            self.skipWhitespace();
            // Comma is optional (qail.rs doesn't require commas)
            if (self.current() == ',') {
                self.advance();
            }
        }

        try self.expectChar(close_char);
        return table;
    }

    pub fn parseSchema(self: *Parser) !Schema {
        var schema = Schema.init(self.allocator);

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.matchKeyword("table")) {
                self.pos -= 5; // rewind "table"
                const table = try self.parseTable();
                try schema.tables.append(self.allocator, table);
            } else {
                break;
            }
        }

        return schema;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse simple table" {
    const allocator = std.testing.allocator;

    const input =
        \\table users (
        \\    id uuid primary_key,
        \\    email text not null,
        \\    name text
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 1), schema.tables.items.len);

    const users = schema.tables.items[0];
    try std.testing.expectEqualStrings("users", users.name);
    try std.testing.expectEqual(@as(usize, 3), users.columns.items.len);

    const id = users.columns.items[0];
    try std.testing.expectEqualStrings("id", id.name);
    try std.testing.expectEqualStrings("uuid", id.typ);
    try std.testing.expect(id.primary_key);
    try std.testing.expect(!id.nullable);
}

test "parse multiple tables" {
    const allocator = std.testing.allocator;

    const input =
        \\-- Users table
        \\table users (
        \\    id uuid primary_key,
        \\    email text not null unique
        \\)
        \\
        \\-- Orders table
        \\table orders (
        \\    id uuid primary_key,
        \\    user_id uuid references users(id),
        \\    total i64 not null default 0
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 2), schema.tables.items.len);
}

test "parse array types" {
    const allocator = std.testing.allocator;

    const input =
        \\table products (
        \\    id uuid primary_key,
        \\    tags text[]
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const products = schema.tables.items[0];
    const tags = products.findColumn("tags").?;
    try std.testing.expect(tags.is_array);
}

test "parse type params" {
    const allocator = std.testing.allocator;

    const input =
        \\table items (
        \\    id serial primary_key,
        \\    name varchar(255) not null
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const items = schema.tables.items[0];

    const id = items.findColumn("id").?;
    try std.testing.expect(id.is_serial);
    try std.testing.expect(!id.nullable);

    const name = items.findColumn("name").?;
    try std.testing.expectEqualStrings("varchar", name.typ);
    try std.testing.expectEqualStrings("255", name.type_params.?);
}
