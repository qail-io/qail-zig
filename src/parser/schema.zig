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
const ast = @import("../ast/mod.zig");
const schema_types = @import("schema/types.zig");

const Expr = ast.Expr;
const BinaryOp = ast.BinaryOp;
const Value = ast.Value;
const ast_policy = ast.policy;
const freeOwnedExpr = ast_policy.freeOwnedExpr;

pub const PolicyTarget = schema_types.PolicyTarget;
pub const PolicyPermissiveness = schema_types.PolicyPermissiveness;
pub const PolicyDef = schema_types.PolicyDef;
pub const GrantAction = schema_types.GrantAction;
pub const GrantDef = schema_types.GrantDef;
pub const TableDef = schema_types.TableDef;
pub const ColumnDef = schema_types.ColumnDef;

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
            if (policy.using_expr) |expr| freeOwnedExpr(self.allocator, expr);
            if (policy.with_check_expr) |expr| freeOwnedExpr(self.allocator, expr);
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

    fn parsePolicyPredicate(self: *Parser, expr_slot: *?Expr) !void {
        const raw = try self.parseParenthesizedExpr();
        errdefer self.allocator.free(raw);

        const parsed = parseOwnedPolicyExpr(self.allocator, raw) catch |err| switch (err) {
            error.InvalidPolicyExpression, error.UnsupportedPolicyExpr => {
                if (expr_slot.*) |old_expr| {
                    freeOwnedExpr(self.allocator, old_expr);
                }
                expr_slot.* = .{ .raw = raw };
                return;
            },
            else => return err,
        };

        if (expr_slot.*) |old_expr| freeOwnedExpr(self.allocator, old_expr);
        expr_slot.* = parsed;
        self.allocator.free(raw);
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
            .using_expr = null,
            .with_check_expr = null,
        };
        errdefer {
            self.allocator.free(policy.name);
            self.allocator.free(policy.table);
            if (policy.role) |role| self.allocator.free(role);
            if (policy.using_expr) |expr| freeOwnedExpr(self.allocator, expr);
            if (policy.with_check_expr) |expr| freeOwnedExpr(self.allocator, expr);
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
                try self.parsePolicyPredicate(&policy.using_expr);
                continue;
            }

            if (self.matchKeyword("with_check")) {
                try self.parsePolicyPredicate(&policy.with_check_expr);
                continue;
            }

            if (self.matchKeyword("with")) {
                if (self.matchKeyword("check")) {
                    try self.parsePolicyPredicate(&policy.with_check_expr);
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

fn parseOwnedPolicyExpr(allocator: Allocator, input: []const u8) !Expr {
    var normalized = try tryParseNormalizedPolicyExpr(allocator, input);
    if (normalized != null) {
        return normalized.?.take();
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = PolicyExprParser.init(arena.allocator(), input);
    const arena_expr = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPolicyExpression,
    };

    return ast_policy.cloneOwnedExpr(allocator, arena_expr);
}

const PolicyLhs = union(enum) {
    column: []const u8,
    bool_literal: bool,
};

const ParsedSettingExpr = struct {
    session_var: []const u8,
    cast_type: []const u8,
};

fn tryParseNormalizedPolicyExpr(allocator: Allocator, input: []const u8) !?ast_policy.OwnedExpr {
    const s = stripOuterParens(input);

    if (findTopLevelOp(s, " OR ")) |pos| {
        var left = (try tryParseNormalizedPolicyExpr(allocator, s[0..pos])) orelse return null;
        defer left.deinit();

        var right = (try tryParseNormalizedPolicyExpr(allocator, s[pos + 4 ..])) orelse return null;
        defer right.deinit();

        return try ast_policy.orExpr(allocator, left.root(), right.root());
    }

    if (findTopLevelOp(s, " AND ")) |pos| {
        var left = (try tryParseNormalizedPolicyExpr(allocator, s[0..pos])) orelse return null;
        defer left.deinit();

        var right = (try tryParseNormalizedPolicyExpr(allocator, s[pos + 5 ..])) orelse return null;
        defer right.deinit();

        return try ast_policy.andExpr(allocator, left.root(), right.root());
    }

    if (findTopLevelOp(s, " = ")) |eq_pos| {
        const lhs = std.mem.trim(u8, s[0..eq_pos], " \t\r\n");
        const rhs = std.mem.trim(u8, s[eq_pos + 3 ..], " \t\r\n");

        if (try tryBuildNormalizedPolicyCheck(allocator, lhs, rhs)) |expr| return expr;
        if (try tryBuildNormalizedPolicyCheck(allocator, rhs, lhs)) |expr| return expr;
    }

    return null;
}

fn tryBuildNormalizedPolicyCheck(allocator: Allocator, lhs_sql: []const u8, rhs_sql: []const u8) !?ast_policy.OwnedExpr {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const setting = (try parseNormalizedSettingExpr(arena.allocator(), rhs_sql)) orelse return null;
    const lhs = parsePolicyLhs(lhs_sql) orelse return null;

    switch (lhs) {
        .column => |column| return @as(?ast_policy.OwnedExpr, try ast_policy.tenantCheck(allocator, column, setting.session_var, setting.cast_type)),
        .bool_literal => |bool_value| {
            if (bool_value and std.ascii.eqlIgnoreCase(setting.cast_type, "boolean")) {
                return @as(?ast_policy.OwnedExpr, try ast_policy.sessionBoolCheck(allocator, setting.session_var));
            }

            const session_arg = Expr.str(setting.session_var);
            const args = [_]Expr{session_arg};
            const current_setting: Expr = .{
                .func_call = .{
                    .name = "current_setting",
                    .args = &args,
                },
            };
            const cast_expr: Expr = .{
                .cast = .{
                    .expr = &current_setting,
                    .target_type = setting.cast_type,
                },
            };
            const expected = Expr.val(Value.fromBool(bool_value));
            return @as(
                ?ast_policy.OwnedExpr,
                try ast_policy.OwnedExpr.init(
                    allocator,
                    .{
                        .binary = .{
                            .left = &cast_expr,
                            .op = .eq,
                            .right = &expected,
                        },
                    },
                ),
            );
        },
    }
}

fn parsePolicyLhs(input: []const u8) ?PolicyLhs {
    const lhs = std.mem.trim(u8, stripOuterParens(input), " \t\r\n");
    if (isSqlTrueLiteral(lhs)) return .{ .bool_literal = true };
    if (isSqlFalseLiteral(lhs)) return .{ .bool_literal = false };
    if (lhs.len == 0) return null;
    return .{ .column = lhs };
}

fn parseNormalizedSettingExpr(allocator: Allocator, input: []const u8) anyerror!?ParsedSettingExpr {
    var normalized = std.mem.trim(u8, stripOuterParens(input), " \t\r\n");

    while (normalized.len > 0 and normalized[0] == '(') {
        const close_idx = findMatchingParen(normalized, 0) orelse break;
        const rest = std.mem.trim(u8, normalized[close_idx + 1 ..], " \t\r\n");
        if (!std.mem.startsWith(u8, rest, "::")) break;
        normalized = normalized[1..close_idx];
        normalized = std.mem.trim(u8, normalized, " \t\r\n");
        normalized = try std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized, rest });
    }

    if (try parseCurrentSettingExpr(allocator, normalized)) |setting| {
        return setting;
    }

    if (try parseWrappedSettingExpr(allocator, normalized, "NULLIF")) |setting| {
        return setting;
    }

    if (try parseCoalesceSettingExpr(allocator, normalized)) |setting| {
        return setting;
    }

    return null;
}

fn parseCurrentSettingExpr(allocator: Allocator, input: []const u8) anyerror!?ParsedSettingExpr {
    const parsed = parseFunctionArgsAndRestCi(input, "current_setting") orelse return null;
    const session_var = (try extractFirstStringLiteral(allocator, parsed.args)) orelse return null;
    const cast_type = parseCastSuffix(parsed.rest) orelse "text";
    return .{
        .session_var = session_var,
        .cast_type = cast_type,
    };
}

fn parseWrappedSettingExpr(allocator: Allocator, input: []const u8, fn_name: []const u8) anyerror!?ParsedSettingExpr {
    const parsed = parseFunctionArgsAndRestCi(input, fn_name) orelse return null;
    const args = splitArgs2(parsed.args) orelse return null;
    var setting = (try parseNormalizedSettingExpr(allocator, std.mem.trim(u8, args.left, " \t\r\n"))) orelse return null;
    if (parseCastSuffix(parsed.rest)) |cast_type| {
        setting.cast_type = cast_type;
    }
    return setting;
}

fn parseCoalesceSettingExpr(allocator: Allocator, input: []const u8) anyerror!?ParsedSettingExpr {
    const parsed = parseFunctionArgsAndRestCi(input, "COALESCE") orelse return null;
    const args = splitArgs2(parsed.args) orelse return null;
    var setting = (try parseNormalizedSettingExpr(allocator, std.mem.trim(u8, args.left, " \t\r\n"))) orelse return null;

    if (parseCastSuffix(parsed.rest)) |cast_type| {
        setting.cast_type = cast_type;
    } else if (isSqlBoolStringLiteral(std.mem.trim(u8, args.right, " \t\r\n"))) {
        setting.cast_type = "boolean";
    }

    return setting;
}

const FunctionArgsAndRest = struct {
    args: []const u8,
    rest: []const u8,
};

fn parseFunctionArgsAndRestCi(input: []const u8, fn_name: []const u8) ?FunctionArgsAndRest {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len <= fn_name.len + 1) return null;
    if (!std.ascii.eqlIgnoreCase(s[0..fn_name.len], fn_name)) return null;
    if (s[fn_name.len] != '(') return null;
    const close_idx = findMatchingParen(s, fn_name.len) orelse return null;
    return .{
        .args = s[fn_name.len + 1 .. close_idx],
        .rest = s[close_idx + 1 ..],
    };
}

const SplitArgs2 = struct {
    left: []const u8,
    right: []const u8,
};

fn splitArgs2(input: []const u8) ?SplitArgs2 {
    const idx = findTopLevelChar(input, ',') orelse return null;
    return .{
        .left = input[0..idx],
        .right = input[idx + 1 ..],
    };
}

fn parseCastSuffix(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stripOuterParens(input), " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "::")) return null;
    return std.mem.trim(u8, trimmed[2..], " \t\r\n");
}

fn extractFirstStringLiteral(allocator: Allocator, input: []const u8) !?[]const u8 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0 or s[0] != '\'') return null;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\'') {
            if (i + 1 < s.len and s[i + 1] == '\'') {
                try buf.append(allocator, '\'');
                i += 1;
                continue;
            }
            return try buf.toOwnedSlice(allocator);
        }
        try buf.append(allocator, s[i]);
    }

    return null;
}

fn isSqlTrueLiteral(input: []const u8) bool {
    return eqlAsciiLowerTrimmed(input, "true") or
        eqlAsciiLowerTrimmed(input, "'true'") or
        eqlAsciiLowerTrimmed(input, "'true'::text") or
        eqlAsciiLowerTrimmed(input, "'true'::varchar");
}

fn isSqlFalseLiteral(input: []const u8) bool {
    return eqlAsciiLowerTrimmed(input, "false") or
        eqlAsciiLowerTrimmed(input, "'false'") or
        eqlAsciiLowerTrimmed(input, "'false'::text") or
        eqlAsciiLowerTrimmed(input, "'false'::varchar");
}

fn isSqlBoolStringLiteral(input: []const u8) bool {
    return isSqlTrueLiteral(input) or isSqlFalseLiteral(input);
}

fn eqlAsciiLowerTrimmed(input: []const u8, expected: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len != expected.len) return false;
    for (trimmed, expected) |actual, want| {
        if (std.ascii.toLower(actual) != want) return false;
    }
    return true;
}

fn stripOuterParens(input: []const u8) []const u8 {
    var s = std.mem.trim(u8, input, " \t\r\n");
    while (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') {
        var depth: usize = 0;
        var i: usize = 0;
        var wraps = true;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0 and i < s.len - 1) {
                        wraps = false;
                        break;
                    }
                },
                else => {},
            }
        }
        if (!wraps or depth != 0) break;
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
    }
    return s;
}

fn findTopLevelOp(input: []const u8, op: []const u8) ?usize {
    if (input.len < op.len) return null;
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i + op.len <= input.len) : (i += 1) {
        const ch = input[i];
        if (in_string) {
            if (ch == '\'') {
                if (i + 1 < input.len and input[i + 1] == '\'') {
                    i += 1;
                } else {
                    in_string = false;
                }
            }
            continue;
        }
        switch (ch) {
            '\'' => in_string = true,
            '(' => depth += 1,
            ')' => depth -= 1,
            else => {},
        }
        if (depth == 0 and std.mem.eql(u8, input[i .. i + op.len], op)) return i;
    }
    return null;
}

fn findTopLevelChar(input: []const u8, needle: u8) ?usize {
    var depth: i32 = 0;
    var in_string = false;
    for (input, 0..) |ch, i| {
        if (in_string) {
            if (ch == '\'') {
                if (i + 1 < input.len and input[i + 1] == '\'') continue;
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '\'' => in_string = true,
            '(' => depth += 1,
            ')' => depth -= 1,
            else => if (depth == 0 and ch == needle) return i,
        }
    }
    return null;
}

fn findMatchingParen(input: []const u8, open_idx: usize) ?usize {
    if (open_idx >= input.len or input[open_idx] != '(') return null;

    var depth: usize = 0;
    var in_string = false;
    var i = open_idx;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (in_string) {
            if (ch == '\'') {
                if (i + 1 < input.len and input[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                in_string = false;
            }
            continue;
        }

        switch (ch) {
            '\'' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }

    return null;
}

const PolicyExprParser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize = 0,

    fn init(allocator: Allocator, input: []const u8) PolicyExprParser {
        return .{
            .allocator = allocator,
            .input = input,
        };
    }

    fn remaining(self: *PolicyExprParser) []const u8 {
        return self.input[self.pos..];
    }

    fn current(self: *PolicyExprParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *PolicyExprParser) void {
        if (self.pos < self.input.len) self.pos += 1;
    }

    fn skipWhitespace(self: *PolicyExprParser) void {
        while (self.current()) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn isIdentChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
    }

    fn matchKeyword(self: *PolicyExprParser, keyword: []const u8) bool {
        self.skipWhitespace();
        const rem = self.remaining();
        if (rem.len < keyword.len) return false;
        if (!std.ascii.eqlIgnoreCase(rem[0..keyword.len], keyword)) return false;
        if (rem.len > keyword.len and isIdentChar(rem[keyword.len])) return false;
        self.pos += keyword.len;
        return true;
    }

    fn parse(self: *PolicyExprParser) anyerror!Expr {
        const expr = try self.parseExpr();
        self.skipWhitespace();
        if (self.pos != self.input.len) return error.InvalidPolicyExpression;
        return expr;
    }

    fn parseExpr(self: *PolicyExprParser) anyerror!Expr {
        var expr = try self.parseComparison();

        while (true) {
            if (self.matchKeyword("or")) {
                const left = try self.allocator.create(Expr);
                left.* = expr;
                errdefer self.allocator.destroy(left);

                const right_expr = try self.parseComparison();
                const right = try self.allocator.create(Expr);
                right.* = right_expr;
                errdefer self.allocator.destroy(right);

                expr = .{
                    .binary = .{
                        .left = left,
                        .op = .@"or",
                        .right = right,
                    },
                };
                continue;
            }

            if (self.matchKeyword("and")) {
                const left = try self.allocator.create(Expr);
                left.* = expr;
                errdefer self.allocator.destroy(left);

                const right_expr = try self.parseComparison();
                const right = try self.allocator.create(Expr);
                right.* = right_expr;
                errdefer self.allocator.destroy(right);

                expr = .{
                    .binary = .{
                        .left = left,
                        .op = .@"and",
                        .right = right,
                    },
                };
                continue;
            }

            break;
        }

        return expr;
    }

    fn parseComparison(self: *PolicyExprParser) anyerror!Expr {
        const left_expr = try self.parseAtom();
        self.skipWhitespace();

        const op = self.parseCmpOp() orelse return left_expr;

        const left = try self.allocator.create(Expr);
        left.* = left_expr;
        errdefer self.allocator.destroy(left);

        const right_expr = try self.parseAtom();
        const right = try self.allocator.create(Expr);
        right.* = right_expr;
        errdefer self.allocator.destroy(right);

        return .{
            .binary = .{
                .left = left,
                .op = op,
                .right = right,
            },
        };
    }

    fn parseCmpOp(self: *PolicyExprParser) ?BinaryOp {
        self.skipWhitespace();
        const rem = self.remaining();
        if (std.mem.startsWith(u8, rem, ">=")) {
            self.pos += 2;
            return .gte;
        }
        if (std.mem.startsWith(u8, rem, "<=")) {
            self.pos += 2;
            return .lte;
        }
        if (std.mem.startsWith(u8, rem, "<>") or std.mem.startsWith(u8, rem, "!=")) {
            self.pos += 2;
            return .ne;
        }
        if (std.mem.startsWith(u8, rem, "=")) {
            self.pos += 1;
            return .eq;
        }
        if (std.mem.startsWith(u8, rem, ">")) {
            self.pos += 1;
            return .gt;
        }
        if (std.mem.startsWith(u8, rem, "<")) {
            self.pos += 1;
            return .lt;
        }
        return null;
    }

    fn parseAtom(self: *PolicyExprParser) anyerror!Expr {
        var expr = try self.parsePrimary();
        while (true) {
            self.skipWhitespace();
            const rem = self.remaining();
            if (rem.len < 2 or rem[0] != ':' or rem[1] != ':') break;
            self.pos += 2;
            const cast_type = try self.parseIdentifier();
            const inner = try self.allocator.create(Expr);
            inner.* = expr;
            expr = .{
                .cast = .{
                    .expr = inner,
                    .target_type = cast_type,
                },
            };
        }
        return expr;
    }

    fn parsePrimary(self: *PolicyExprParser) anyerror!Expr {
        self.skipWhitespace();
        const ch = self.current() orelse return error.UnexpectedEnd;

        if (ch == '(') return self.parseGrouped();
        if (ch == '\'') return self.parseString();
        if (std.ascii.isDigit(ch)) return self.parseNumber();
        if (self.matchKeyword("true")) return .{ .literal = Value.fromBool(true) };
        if (self.matchKeyword("false")) return .{ .literal = Value.fromBool(false) };

        return self.parseFuncOrIdent();
    }

    fn parseGrouped(self: *PolicyExprParser) anyerror!Expr {
        if (self.current() != '(') return error.InvalidPolicyExpression;
        self.advance();
        const expr = try self.parseExpr();
        self.skipWhitespace();
        if (self.current() != ')') return error.UnterminatedExpression;
        self.advance();
        return expr;
    }

    fn parseString(self: *PolicyExprParser) anyerror!Expr {
        if (self.current() != '\'') return error.InvalidPolicyExpression;
        self.advance();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        while (self.current()) |ch| {
            if (ch == '\'') {
                self.advance();
                if (self.current() == '\'') {
                    try buf.append(self.allocator, '\'');
                    self.advance();
                    continue;
                }
                return .{ .literal = Value.fromString(try buf.toOwnedSlice(self.allocator)) };
            }

            try buf.append(self.allocator, ch);
            self.advance();
        }

        return error.UnterminatedStringLiteral;
    }

    fn parseNumber(self: *PolicyExprParser) anyerror!Expr {
        self.skipWhitespace();
        const start = self.pos;
        var saw_dot = false;

        while (self.current()) |ch| {
            if (std.ascii.isDigit(ch)) {
                self.advance();
                continue;
            }
            if (ch == '.' and !saw_dot) {
                saw_dot = true;
                self.advance();
                continue;
            }
            break;
        }

        const digits = self.input[start..self.pos];
        if (digits.len == 0 or digits[0] == '.') return error.InvalidPolicyExpression;

        if (std.mem.indexOfScalar(u8, digits, '.')) |_| {
            return .{ .literal = Value.fromFloat(try std.fmt.parseFloat(f64, digits)) };
        }

        return .{ .literal = Value.fromInt(try std.fmt.parseInt(i64, digits, 10)) };
    }

    fn parseIdentifier(self: *PolicyExprParser) anyerror![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        while (self.current()) |ch| {
            if (isIdentChar(ch)) {
                self.advance();
            } else {
                break;
            }
        }

        if (self.pos == start) return error.ExpectedIdentifier;
        return self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn parseFuncOrIdent(self: *PolicyExprParser) anyerror!Expr {
        const name = try self.parseIdentifier();

        const expr: Expr = blk: {
            self.skipWhitespace();
            if (self.current() == '(') {
                self.advance();
                self.skipWhitespace();

                var args: std.ArrayList(Expr) = .empty;
                defer args.deinit(self.allocator);

                if (self.current() != ')') {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpr());
                        self.skipWhitespace();
                        if (self.current() == ',') {
                            self.advance();
                            self.skipWhitespace();
                            continue;
                        }
                        break;
                    }
                }

                if (self.current() != ')') return error.UnterminatedExpression;
                self.advance();

                break :blk .{
                    .func_call = .{
                        .name = name,
                        .args = try args.toOwnedSlice(self.allocator),
                    },
                };
            }

            break :blk .{ .named = name };
        };

        return expr;
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
    try std.testing.expect(policy.using_expr != null);
    try std.testing.expect(policy.with_check_expr != null);

    const using_expr = policy.using_expr.?;
    try std.testing.expect(using_expr == .binary);
    try std.testing.expectEqual(BinaryOp.eq, using_expr.binary.op);
    try std.testing.expect(using_expr.binary.left.* == .named);
    try std.testing.expectEqualStrings("tenant_id", using_expr.binary.left.named);
    try std.testing.expect(using_expr.binary.right.* == .cast);
    try std.testing.expectEqualStrings("uuid", using_expr.binary.right.cast.target_type);
    try std.testing.expect(using_expr.binary.right.cast.expr.* == .func_call);
    try std.testing.expectEqualStrings("current_setting", using_expr.binary.right.cast.expr.func_call.name);
}

test "parse policy block falls back to raw sql for unsupported predicate forms" {
    const allocator = std.testing.allocator;

    const input =
        \\table users (
        \\    id uuid primary_key,
        \\    email text not null
        \\)
        \\
        \\policy users_email_filter on users
        \\    for select
        \\    using (lower(email) like '%@qail.io')
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 1), schema.policies.items.len);
    const policy = schema.policies.items[0];
    try std.testing.expect(policy.using_expr != null);
    try std.testing.expectEqualStrings(
        "lower(email) like '%@qail.io'",
        switch (policy.using_expr.?) {
            .raw => |raw| raw,
            else => unreachable,
        },
    );
}

test "parse policy block normalizes nullif wrapped current_setting tenant predicate" {
    const allocator = std.testing.allocator;

    const input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\
        \\policy orders_tenant_isolation on orders
        \\    using (tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const policy = schema.policies.items[0];
    try std.testing.expect(policy.using_expr != null);

    const expr = policy.using_expr.?;
    try std.testing.expect(expr == .binary);
    try std.testing.expect(expr.binary.left.* == .named);
    try std.testing.expectEqualStrings("tenant_id", expr.binary.left.named);
    try std.testing.expectEqual(BinaryOp.eq, expr.binary.op);
    try std.testing.expect(expr.binary.right.* == .cast);
    try std.testing.expectEqualStrings("uuid", expr.binary.right.cast.target_type);
    try std.testing.expect(expr.binary.right.cast.expr.* == .func_call);
    try std.testing.expectEqualStrings("current_setting", expr.binary.right.cast.expr.func_call.name);
}

test "parse policy block normalizes coalesce wrapped current_setting boolean predicate" {
    const allocator = std.testing.allocator;

    const input =
        \\table secrets (
        \\    id uuid primary_key
        \\)
        \\
        \\policy admin_bypass on secrets
        \\    using (COALESCE(current_setting('app.is_super_admin'::text, true), 'false'::text) = 'true'::text)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const policy = schema.policies.items[0];
    try std.testing.expect(policy.using_expr != null);

    const expr = policy.using_expr.?;
    try std.testing.expect(expr == .binary);
    try std.testing.expect(expr.binary.left.* == .cast);
    try std.testing.expectEqualStrings("boolean", expr.binary.left.cast.target_type);
    try std.testing.expect(expr.binary.left.cast.expr.* == .func_call);
    try std.testing.expectEqualStrings("current_setting", expr.binary.left.cast.expr.func_call.name);
    try std.testing.expect(expr.binary.right.* == .literal);
    try std.testing.expect(expr.binary.right.literal == .bool);
    try std.testing.expectEqual(true, expr.binary.right.literal.bool);
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
