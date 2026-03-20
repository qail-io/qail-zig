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
const io = @import("../compat/io.zig");
const ast_cmd = @import("../ast/cmd.zig");

pub const PolicyTarget = ast_cmd.PolicyTarget;
pub const PolicyPermissiveness = ast_cmd.PolicyPermissiveness;
pub const PolicyDef = ast_cmd.PolicyDef;

pub const GrantAction = enum {
    grant,
    revoke,
};

pub const GrantDef = struct {
    action: GrantAction,
    privileges: []const []const u8,
    on_object: []const u8,
    role: []const u8,

    pub fn deinit(self: *const GrantDef, allocator: Allocator) void {
        for (self.privileges) |p| allocator.free(p);
        allocator.free(self.privileges);
        allocator.free(self.on_object);
        allocator.free(self.role);
    }
};

// ============================================================================
// Types
// ============================================================================

/// Schema containing all table definitions
pub const Schema = struct {
    tables: std.ArrayList(TableDef),
    policies: std.ArrayList(PolicyDef),
    grants: std.ArrayList(GrantDef),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Schema {
        return .{
            .tables = std.ArrayList(TableDef).initCapacity(allocator, 0) catch unreachable,
            .policies = std.ArrayList(PolicyDef).initCapacity(allocator, 0) catch unreachable,
            .grants = std.ArrayList(GrantDef).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Schema) void {
        for (self.tables.items) |*table| {
            table.deinit(self.allocator);
        }
        for (self.policies.items) |policy| {
            self.allocator.free(policy.name);
            self.allocator.free(policy.table);
            if (policy.role) |role| self.allocator.free(role);
            if (policy.using_sql) |using_sql| self.allocator.free(using_sql);
            if (policy.with_check_sql) |with_check_sql| self.allocator.free(with_check_sql);
        }
        for (self.grants.items) |grant| {
            grant.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
        self.policies.deinit(self.allocator);
        self.grants.deinit(self.allocator);
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

    pub fn findPolicy(self: *const Schema, name: []const u8, table: []const u8) ?*const PolicyDef {
        for (self.policies.items) |*policy| {
            if (std.ascii.eqlIgnoreCase(policy.name, name) and std.ascii.eqlIgnoreCase(policy.table, table)) {
                return policy;
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
        var ddl_writer = io.AllocatingWriter.init(allocator);
        defer ddl_writer.deinit();
        const writer = ddl_writer.writer();

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
        return ddl_writer.toOwnedSlice();
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
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
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

    fn parsePolicyTarget(self: *Parser) !PolicyTarget {
        if (self.matchKeyword("all")) return .all;
        if (self.matchKeyword("select")) return .select;
        if (self.matchKeyword("insert")) return .insert;
        if (self.matchKeyword("update")) return .update;
        if (self.matchKeyword("delete")) return .delete;
        return error.ExpectedPolicyTarget;
    }

    fn parseParenthesizedExpr(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        try self.expectChar('(');
        const expr_start = self.pos;

        var depth: usize = 1;
        while (self.current()) |ch| {
            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
            self.advance();
        }

        if (self.current() == null) return error.UnterminatedExpression;
        const expr_end = self.pos;
        self.advance(); // Skip closing ')'

        const expr = std.mem.trim(u8, self.input[expr_start..expr_end], " \t\r\n");
        return self.allocator.dupe(u8, expr);
    }

    fn parsePolicy(self: *Parser) !PolicyDef {
        if (!self.matchKeyword("policy")) return error.ExpectedPolicy;

        const name = try self.parseIdentifier();
        errdefer self.allocator.free(name);

        if (!self.matchKeyword("on")) return error.ExpectedOnKeyword;
        const table = try self.parseIdentifier();
        errdefer self.allocator.free(table);

        var policy = PolicyDef{
            .name = name,
            .table = table,
            .target = .all,
            .permissiveness = .permissive,
            .role = null,
            .using_sql = null,
            .with_check_sql = null,
        };
        errdefer {
            self.allocator.free(policy.name);
            self.allocator.free(policy.table);
            if (policy.role) |role| self.allocator.free(role);
            if (policy.using_sql) |using_sql| self.allocator.free(using_sql);
            if (policy.with_check_sql) |with_check_sql| self.allocator.free(with_check_sql);
        }

        while (true) {
            const restore = self.pos;

            if (self.matchKeyword("for")) {
                policy.target = try self.parsePolicyTarget();
                continue;
            }

            if (self.matchKeyword("to")) {
                const role = try self.parseIdentifier();
                if (policy.role) |old_role| self.allocator.free(old_role);
                policy.role = role;
                continue;
            }

            if (self.matchKeyword("using")) {
                const using_sql = try self.parseParenthesizedExpr();
                if (policy.using_sql) |old_using| self.allocator.free(old_using);
                policy.using_sql = using_sql;
                continue;
            }

            if (self.matchKeyword("with_check")) {
                const with_check_sql = try self.parseParenthesizedExpr();
                if (policy.with_check_sql) |old_with_check| self.allocator.free(old_with_check);
                policy.with_check_sql = with_check_sql;
                continue;
            }

            if (self.matchKeyword("with")) {
                if (self.matchKeyword("check")) {
                    const with_check_sql = try self.parseParenthesizedExpr();
                    if (policy.with_check_sql) |old_with_check| self.allocator.free(old_with_check);
                    policy.with_check_sql = with_check_sql;
                    continue;
                }
                self.pos = restore;
                break;
            }

            if (self.matchKeyword("restrictive")) {
                policy.permissiveness = .restrictive;
                continue;
            }
            if (self.matchKeyword("permissive")) {
                policy.permissiveness = .permissive;
                continue;
            }

            self.pos = restore;
            break;
        }

        return policy;
    }

    fn parsePrivilegesUntilOn(self: *Parser) ![]const []const u8 {
        var privileges: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (privileges.items) |p| self.allocator.free(p);
            privileges.deinit(self.allocator);
        }

        while (true) {
            self.skipWhitespace();
            if (self.matchKeyword("on")) break;

            const start = self.pos;
            while (self.current()) |ch| {
                if (ch == ',' or std.ascii.isWhitespace(ch)) break;
                self.advance();
            }

            if (self.pos == start) return error.ExpectedPrivilege;

            const raw = std.mem.trim(u8, self.input[start..self.pos], " \t\r\n");
            if (raw.len == 0) return error.ExpectedPrivilege;
            try privileges.append(self.allocator, try self.allocator.dupe(u8, raw));

            self.skipWhitespace();
            if (self.current() == ',') self.advance();
        }

        if (privileges.items.len == 0) return error.ExpectedPrivilege;
        return try privileges.toOwnedSlice(self.allocator);
    }

    fn parseGrantLike(self: *Parser, action: GrantAction) !GrantDef {
        const ok = switch (action) {
            .grant => self.matchKeyword("grant"),
            .revoke => self.matchKeyword("revoke"),
        };
        if (!ok) return error.ExpectedGrantOrRevoke;

        const privileges = try self.parsePrivilegesUntilOn();
        errdefer {
            for (privileges) |p| self.allocator.free(p);
            self.allocator.free(privileges);
        }

        const on_object = try self.parseIdentifier();
        errdefer self.allocator.free(on_object);

        const role_kw = switch (action) {
            .grant => "to",
            .revoke => "from",
        };
        if (!self.matchKeyword(role_kw)) return error.ExpectedGrantRole;

        const role = try self.parseIdentifier();

        return .{
            .action = action,
            .privileges = privileges,
            .on_object = on_object,
            .role = role,
        };
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
            } else if (self.matchKeyword("policy")) {
                self.pos -= 6; // rewind "policy"
                const policy = try self.parsePolicy();
                try schema.policies.append(self.allocator, policy);
            } else if (self.matchKeyword("grant")) {
                self.pos -= 5; // rewind "grant"
                const grant = try self.parseGrantLike(.grant);
                try schema.grants.append(self.allocator, grant);
            } else if (self.matchKeyword("revoke")) {
                self.pos -= 6; // rewind "revoke"
                const revoke = try self.parseGrantLike(.revoke);
                try schema.grants.append(self.allocator, revoke);
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

test "parse policy block" {
    const allocator = std.testing.allocator;

    const input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\
        \\policy orders_tenant_isolation on orders
        \\    for all
        \\    to app_user
        \\    restrictive
        \\    using (tenant_id = current_setting('app.tenant_id')::uuid)
        \\    with_check (tenant_id = current_setting('app.tenant_id')::uuid)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 1), schema.policies.items.len);
    const policy = schema.policies.items[0];
    try std.testing.expectEqualStrings("orders_tenant_isolation", policy.name);
    try std.testing.expectEqualStrings("orders", policy.table);
    try std.testing.expectEqual(PolicyTarget.all, policy.target);
    try std.testing.expectEqual(PolicyPermissiveness.restrictive, policy.permissiveness);
    try std.testing.expectEqualStrings("app_user", policy.role.?);
    try std.testing.expect(policy.using_sql != null);
    try std.testing.expect(policy.with_check_sql != null);
}

test "parse grant and revoke statements" {
    const allocator = std.testing.allocator;

    const input =
        \\grant select, insert on users to app_role
        \\revoke update on users from app_role
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 2), schema.grants.items.len);

    const grant = schema.grants.items[0];
    try std.testing.expectEqual(GrantAction.grant, grant.action);
    try std.testing.expectEqual(@as(usize, 2), grant.privileges.len);
    try std.testing.expectEqualStrings("select", grant.privileges[0]);
    try std.testing.expectEqualStrings("insert", grant.privileges[1]);
    try std.testing.expectEqualStrings("users", grant.on_object);
    try std.testing.expectEqualStrings("app_role", grant.role);

    const revoke = schema.grants.items[1];
    try std.testing.expectEqual(GrantAction.revoke, revoke.action);
    try std.testing.expectEqual(@as(usize, 1), revoke.privileges.len);
    try std.testing.expectEqualStrings("update", revoke.privileges[0]);
    try std.testing.expectEqualStrings("users", revoke.on_object);
    try std.testing.expectEqualStrings("app_role", revoke.role);
}
