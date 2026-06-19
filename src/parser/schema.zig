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
pub const IndexDef = schema_types.IndexDef;
pub const TableDef = schema_types.TableDef;
pub const ColumnDef = schema_types.ColumnDef;

fn deinitPolicyDef(allocator: Allocator, policy: *const PolicyDef) void {
    allocator.free(policy.name);
    allocator.free(policy.table);
    if (policy.role) |role| allocator.free(role);
    if (policy.using_expr) |expr| freeOwnedExpr(allocator, expr);
    if (policy.with_check_expr) |expr| freeOwnedExpr(allocator, expr);
}

// ============================================================================
// Types
// ============================================================================

/// Schema containing all table definitions
pub const Schema = struct {
    tables: std.ArrayList(TableDef),
    indexes: std.ArrayList(IndexDef),
    policies: std.ArrayList(PolicyDef),
    grants: std.ArrayList(GrantDef),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Schema {
        return .{
            .tables = std.ArrayList(TableDef).initCapacity(allocator, 0) catch unreachable,
            .indexes = std.ArrayList(IndexDef).initCapacity(allocator, 0) catch unreachable,
            .policies = std.ArrayList(PolicyDef).initCapacity(allocator, 0) catch unreachable,
            .grants = std.ArrayList(GrantDef).initCapacity(allocator, 0) catch unreachable,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Schema) void {
        for (self.tables.items) |*table| {
            table.deinit(self.allocator);
        }
        for (self.indexes.items) |index| {
            index.deinit(self.allocator);
        }
        for (self.policies.items) |policy| {
            deinitPolicyDef(self.allocator, &policy);
        }
        for (self.grants.items) |grant| {
            grant.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
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

    pub fn findIndex(self: *const Schema, name: []const u8) ?*const IndexDef {
        for (self.indexes.items) |*index| {
            if (std.ascii.eqlIgnoreCase(index.name, name)) {
                return index;
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

    fn skipInlineWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn isIdentifierStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentifierPart(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn isQualifiedIdentifierPart(c: u8) bool {
        return isIdentifierPart(c) or c == '.';
    }

    fn validateIdentifierPart(part: []const u8) bool {
        if (part.len == 0 or !isIdentifierStart(part[0])) return false;
        for (part[1..]) |ch| {
            if (!isIdentifierPart(ch)) return false;
        }
        return true;
    }

    fn validateQualifiedIdentifier(identifier: []const u8) bool {
        var parts = std.mem.splitScalar(u8, identifier, '.');
        while (parts.next()) |part| {
            if (!validateIdentifierPart(part)) return false;
        }
        return true;
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        const first = self.current() orelse return error.ExpectedIdentifier;
        if (!isIdentifierStart(first)) return error.ExpectedIdentifier;
        self.advance();

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isQualifiedIdentifierPart(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }

        const identifier = self.input[start..self.pos];
        if (!validateQualifiedIdentifier(identifier)) return error.ExpectedIdentifier;

        return self.allocator.dupe(u8, identifier);
    }

    fn parseBareIdentifier(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        const first = self.current() orelse return error.ExpectedIdentifier;
        if (!isIdentifierStart(first)) return error.ExpectedIdentifier;
        self.advance();

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isIdentifierPart(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.current() == '.') return error.ExpectedIdentifier;

        const identifier = self.input[start..self.pos];
        if (!validateIdentifierPart(identifier)) return error.ExpectedIdentifier;

        return self.allocator.dupe(u8, identifier);
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
                if (rem.len == keyword.len or !isIdentifierPart(rem[keyword.len])) {
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

    fn canonicalGrantPrivilege(privilege: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, privilege, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "SELECT")) return "SELECT";
        if (std.ascii.eqlIgnoreCase(trimmed, "INSERT")) return "INSERT";
        if (std.ascii.eqlIgnoreCase(trimmed, "UPDATE")) return "UPDATE";
        if (std.ascii.eqlIgnoreCase(trimmed, "DELETE")) return "DELETE";
        if (std.ascii.eqlIgnoreCase(trimmed, "TRUNCATE")) return "TRUNCATE";
        if (std.ascii.eqlIgnoreCase(trimmed, "REFERENCES")) return "REFERENCES";
        if (std.ascii.eqlIgnoreCase(trimmed, "TRIGGER")) return "TRIGGER";
        if (std.ascii.eqlIgnoreCase(trimmed, "USAGE")) return "USAGE";
        if (std.ascii.eqlIgnoreCase(trimmed, "CREATE")) return "CREATE";
        if (std.ascii.eqlIgnoreCase(trimmed, "CONNECT")) return "CONNECT";
        if (std.ascii.eqlIgnoreCase(trimmed, "TEMP") or
            std.ascii.eqlIgnoreCase(trimmed, "TEMPORARY")) return "TEMPORARY";
        if (std.ascii.eqlIgnoreCase(trimmed, "EXECUTE")) return "EXECUTE";
        if (std.ascii.eqlIgnoreCase(trimmed, "ALL") or
            std.ascii.eqlIgnoreCase(trimmed, "ALL PRIVILEGES")) return "ALL PRIVILEGES";
        return null;
    }

    fn parseParenthesizedExpr(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        try self.expectChar('(');
        const expr_start = self.pos;

        var depth: usize = 1;
        var in_single = false;
        var in_double = false;
        while (self.current()) |ch| {
            if (in_single) {
                if (ch == '\'') {
                    self.advance();
                    if (self.current() == '\'') {
                        self.advance();
                        continue;
                    }
                    in_single = false;
                    continue;
                }
                self.advance();
                continue;
            }

            if (in_double) {
                if (ch == '"') {
                    self.advance();
                    if (self.current() == '"') {
                        self.advance();
                        continue;
                    }
                    in_double = false;
                    continue;
                }
                self.advance();
                continue;
            }

            if (ch == '\'') {
                in_single = true;
                self.advance();
                continue;
            }
            if (ch == '"') {
                in_double = true;
                self.advance();
                continue;
            }

            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
            self.advance();
        }

        if (in_single or in_double) return error.UnterminatedStringLiteral;
        if (self.current() == null) return error.UnterminatedExpression;
        const expr_end = self.pos;
        self.advance(); // Skip closing ')'

        const expr = std.mem.trim(u8, self.input[expr_start..expr_end], " \t\r\n");
        if (expr.len == 0) return error.InvalidPolicyExpression;
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
        var name_owned = true;
        errdefer if (name_owned) self.allocator.free(name);

        if (!self.matchKeyword("on")) return error.ExpectedOnKeyword;
        const table = try self.parseIdentifier();
        var table_owned = true;
        errdefer if (table_owned) self.allocator.free(table);

        var policy = PolicyDef{
            .name = name,
            .table = table,
            .target = .all,
            .permissiveness = .permissive,
            .role = null,
            .using_expr = null,
            .with_check_expr = null,
        };
        name_owned = false;
        table_owned = false;
        errdefer deinitPolicyDef(self.allocator, &policy);

        var seen_for = false;
        var seen_role = false;
        var seen_using = false;
        var seen_with_check = false;
        var seen_permissiveness = false;

        while (true) {
            const restore = self.pos;

            if (self.matchKeyword("for")) {
                if (seen_for) return error.DuplicatePolicyClause;
                seen_for = true;
                policy.target = try self.parsePolicyTarget();
                continue;
            }

            if (self.matchKeyword("to")) {
                if (seen_role) return error.DuplicatePolicyClause;
                seen_role = true;
                const role = try self.parseIdentifier();
                policy.role = role;
                continue;
            }

            if (self.matchKeyword("using")) {
                if (seen_using) return error.DuplicatePolicyClause;
                seen_using = true;
                try self.parsePolicyPredicate(&policy.using_expr);
                continue;
            }

            if (self.matchKeyword("with_check")) {
                if (seen_with_check) return error.DuplicatePolicyClause;
                seen_with_check = true;
                try self.parsePolicyPredicate(&policy.with_check_expr);
                continue;
            }

            if (self.matchKeyword("with")) {
                if (self.matchKeyword("check")) {
                    if (seen_with_check) return error.DuplicatePolicyClause;
                    seen_with_check = true;
                    try self.parsePolicyPredicate(&policy.with_check_expr);
                    continue;
                }
                self.pos = restore;
                break;
            }

            if (self.matchKeyword("restrictive")) {
                if (seen_permissiveness) return error.DuplicatePolicyClause;
                seen_permissiveness = true;
                policy.permissiveness = .restrictive;
                continue;
            }
            if (self.matchKeyword("permissive")) {
                if (seen_permissiveness) return error.DuplicatePolicyClause;
                seen_permissiveness = true;
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

            var canonical = canonicalGrantPrivilege(raw) orelse return error.ExpectedPrivilege;
            if (std.ascii.eqlIgnoreCase(raw, "ALL")) {
                const after_all = self.pos;
                self.skipWhitespace();
                if (self.matchKeyword("privileges")) {
                    canonical = "ALL PRIVILEGES";
                } else {
                    self.pos = after_all;
                }
            }
            try privileges.append(self.allocator, try self.allocator.dupe(u8, canonical));

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

    const TypeInfo = struct {
        name: []const u8,
        params: ?[]const u8,
        is_array: bool,
        is_serial: bool,

        fn deinit(self: *TypeInfo, allocator: Allocator) void {
            allocator.free(self.name);
            if (self.params) |params| allocator.free(params);
        }
    };

    fn isTypeNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isTypeNamePart(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn validateTypeParams(params: []const u8) !void {
        if (std.mem.indexOfAny(u8, params, "\r\n") != null) return error.InvalidTypeParams;

        var saw_part = false;
        var parts = std.mem.splitScalar(u8, params, ',');
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (part.len == 0) return error.InvalidTypeParams;
            for (part) |ch| {
                if (!std.ascii.isDigit(ch)) return error.InvalidTypeParams;
            }
            saw_part = true;
        }

        if (!saw_part) return error.InvalidTypeParams;
    }

    fn parseTypeInfo(self: *Parser) !TypeInfo {
        self.skipWhitespace();
        const start = self.pos;
        const first = self.current() orelse return error.ExpectedType;
        if (!isTypeNameStart(first)) return error.ExpectedType;
        self.advance();

        // Parse type name
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isTypeNamePart(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }

        const type_name = try self.allocator.dupe(u8, self.input[start..self.pos]);
        errdefer self.allocator.free(type_name);

        // Check for type params like (255) or (10, 2)
        var params: ?[]const u8 = null;
        errdefer if (params) |owned_params| self.allocator.free(owned_params);
        if (self.current() == '(') {
            self.advance();
            const param_start = self.pos;
            while (self.current()) |c| {
                if (c == ')') break;
                self.advance();
            }
            if (self.current() != ')') return error.UnterminatedTypeParams;
            const raw_params = self.input[param_start..self.pos];
            try validateTypeParams(raw_params);
            params = try self.allocator.dupe(u8, raw_params);
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
        extra_checks: []const []const u8 = &.{},

        fn deinit(self: *ConstraintResult, allocator: Allocator) void {
            if (self.references) |refs| allocator.free(refs);
            if (self.default_value) |default_value| allocator.free(default_value);
            if (self.check) |check| allocator.free(check);
            for (self.extra_checks) |check| allocator.free(check);
            if (self.extra_checks.len > 0) allocator.free(self.extra_checks);
        }

        fn appendCheck(self: *ConstraintResult, allocator: Allocator, check: []const u8) !void {
            if (self.check == null) {
                self.check = check;
                return;
            }

            const next = try allocator.alloc([]const u8, self.extra_checks.len + 1);
            errdefer allocator.free(next);
            @memcpy(next[0..self.extra_checks.len], self.extra_checks);
            next[self.extra_checks.len] = check;
            if (self.extra_checks.len > 0) allocator.free(self.extra_checks);
            self.extra_checks = next;
        }
    };

    fn parseConstraints(self: *Parser) !ConstraintResult {
        var result = ConstraintResult{};
        errdefer result.deinit(self.allocator);
        var seen_primary_key = false;
        var seen_not_null = false;
        var seen_nullable = false;
        var seen_unique = false;
        var seen_references = false;
        var seen_default = false;

        // Parse constraint keywords until we hit , or ) or } or newline
        while (true) {
            self.skipInlineWhitespace();
            const c = self.current() orelse break;
            if (c == ',' or c == ')' or c == '}' or c == '\n' or c == '\r') break;
            if (c == '#') break;
            if (c == '-' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '-') break;

            if (self.matchKeyword("primary_key")) {
                if (seen_primary_key) return error.DuplicateColumnConstraint;
                if (seen_nullable) return error.InvalidColumnConstraint;
                seen_primary_key = true;
                result.primary_key = true;
                result.nullable = false;
            } else if (self.matchKeyword("primary")) {
                if (!self.matchKeyword("key")) return error.InvalidColumnConstraint;
                if (seen_primary_key) return error.DuplicateColumnConstraint;
                if (seen_nullable) return error.InvalidColumnConstraint;
                seen_primary_key = true;
                result.primary_key = true;
                result.nullable = false;
            } else if (self.matchKeyword("not_null")) {
                if (!seen_not_null and seen_nullable) return error.InvalidColumnConstraint;
                if (seen_not_null) return error.DuplicateColumnConstraint;
                seen_not_null = true;
                result.nullable = false;
            } else if (self.matchKeyword("not")) {
                if (!seen_not_null and seen_nullable) return error.InvalidColumnConstraint;
                if (seen_not_null) return error.DuplicateColumnConstraint;
                if (!self.matchKeyword("null")) return error.InvalidColumnConstraint;
                seen_not_null = true;
                result.nullable = false;
            } else if (self.matchKeyword("nullable") or self.matchKeyword("null")) {
                if (seen_nullable) return error.DuplicateColumnConstraint;
                if (seen_primary_key or seen_not_null) return error.InvalidColumnConstraint;
                seen_nullable = true;
                result.nullable = true;
            } else if (self.matchKeyword("unique")) {
                if (seen_unique) return error.DuplicateColumnConstraint;
                seen_unique = true;
                result.unique = true;
            } else if (self.matchKeyword("references")) {
                if (seen_references) return error.DuplicateColumnConstraint;
                seen_references = true;
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
                const refs = std.mem.trim(u8, self.input[ref_start..self.pos], " \t\r\n");
                if (refs.len == 0) return error.InvalidColumnConstraint;
                if (std.mem.indexOfAny(u8, refs, "\r\n") != null) return error.InvalidColumnConstraint;
                result.references = try self.allocator.dupe(u8, refs);
            } else if (self.matchKeyword("default")) {
                if (seen_default) return error.DuplicateColumnConstraint;
                seen_default = true;
                self.skipWhitespace();
                const def_start = self.pos;
                // Parse default value - track parens for function calls like NOW()
                var paren_depth: usize = 0;
                var in_single = false;
                var in_double = false;
                while (self.current()) |ch| {
                    if (in_single) {
                        if (ch == '\'') {
                            self.advance();
                            if (self.current() == '\'') {
                                self.advance();
                                continue;
                            }
                            in_single = false;
                            continue;
                        }
                        self.advance();
                        continue;
                    }

                    if (in_double) {
                        if (ch == '"') {
                            self.advance();
                            if (self.current() == '"') {
                                self.advance();
                                continue;
                            }
                            in_double = false;
                            continue;
                        }
                        self.advance();
                        continue;
                    }

                    if (ch == '\'') {
                        in_single = true;
                        self.advance();
                    } else if (ch == '"') {
                        in_double = true;
                        self.advance();
                    } else if (ch == '(') {
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
                if (in_single or in_double) return error.UnterminatedStringLiteral;
                const default_value = std.mem.trim(u8, self.input[def_start..self.pos], " \t\r\n");
                if (default_value.len == 0) return error.InvalidColumnConstraint;
                result.default_value = try self.allocator.dupe(u8, default_value);
            } else if (self.matchKeyword("check")) {
                try self.expectChar('(');
                const check_start = self.pos;
                var depth: usize = 1;
                var in_single = false;
                var in_double = false;
                while (self.current()) |ch| {
                    if (in_single) {
                        if (ch == '\'') {
                            self.advance();
                            if (self.current() == '\'') {
                                self.advance();
                                continue;
                            }
                            in_single = false;
                            continue;
                        }
                        self.advance();
                        continue;
                    }

                    if (in_double) {
                        if (ch == '"') {
                            self.advance();
                            if (self.current() == '"') {
                                self.advance();
                                continue;
                            }
                            in_double = false;
                            continue;
                        }
                        self.advance();
                        continue;
                    }

                    if (ch == '\'') {
                        in_single = true;
                        self.advance();
                        continue;
                    }
                    if (ch == '"') {
                        in_double = true;
                        self.advance();
                        continue;
                    }
                    if (ch == '(') depth += 1;
                    if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    self.advance();
                }
                if (in_single or in_double) return error.UnterminatedStringLiteral;
                if (self.current() != ')') return error.UnterminatedExpression;
                const check_expr = std.mem.trim(u8, self.input[check_start..self.pos], " \t\r\n");
                if (check_expr.len == 0) return error.InvalidColumnConstraint;
                const owned_check = try self.allocator.dupe(u8, check_expr);
                var moved_check = false;
                errdefer if (!moved_check) self.allocator.free(owned_check);
                try result.appendCheck(self.allocator, owned_check);
                moved_check = true;
                self.advance(); // skip closing )
            } else {
                return error.InvalidColumnConstraint;
            }
        }

        return result;
    }

    fn parseColumn(self: *Parser) !ColumnDef {
        const name = try self.parseBareIdentifier();
        errdefer self.allocator.free(name);
        const type_info = try self.parseTypeInfo();
        errdefer {
            var owned_type_info = type_info;
            owned_type_info.deinit(self.allocator);
        }
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
            .extra_checks = constraints.extra_checks,
        };
    }

    fn parseTableRlsDirective(self: *Parser, table: *TableDef) !bool {
        if (self.matchKeyword("enable_rls")) {
            if (table.enable_rls) return error.DuplicateTableDirective;
            table.enable_rls = true;
            return true;
        }
        if (self.matchKeyword("force_rls")) {
            if (table.force_rls) return error.DuplicateTableDirective;
            table.force_rls = true;
            return true;
        }
        return false;
    }

    fn parseTable(self: *Parser) !TableDef {
        if (!self.matchKeyword("table")) {
            return error.ExpectedTable;
        }

        const name = try self.parseIdentifier();
        var table = TableDef.init(self.allocator, name);
        errdefer table.deinit(self.allocator);

        // Support both () and {} for table definitions (like qail.rs uses {})
        self.skipWhitespace();
        const open_char = self.current() orelse return error.ExpectedOpenBrace;
        const close_char: u8 = if (open_char == '{') '}' else if (open_char == '(') ')' else return error.ExpectedOpenBrace;
        self.advance();

        while (true) {
            self.skipWhitespace(); // Skips spaces, tabs, newlines, and comments
            if (self.current() == close_char) break;
            if (self.current() == null) break;

            if (try self.parseTableRlsDirective(&table)) {
                self.skipWhitespace();
                if (self.current() == ',') {
                    self.advance();
                }
                continue;
            }

            const col = try self.parseColumn();
            for (table.columns.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, col.name)) {
                    var owned_col = col;
                    owned_col.deinit(self.allocator);
                    return error.DuplicateColumn;
                }
            }
            try table.columns.append(self.allocator, col);

            self.skipWhitespace();
            // Comma is optional (qail.rs doesn't require commas)
            if (self.current() == ',') {
                self.advance();
            }
        }

        try self.expectChar(close_char);
        while (try self.parseTableRlsDirective(&table)) {}
        if (table.columns.items.len == 0) return error.EmptyTable;
        try validateTableKeyTypes(&table);
        try validateTableCheckReferences(&table);
        return table;
    }

    fn parseIndexListFragment(self: *Parser, include_list: bool) ![]const u8 {
        try self.expectChar('(');
        const start = self.pos;
        while (self.current()) |ch| {
            if (ch == '\n' or ch == '\r' or ch == 0) return error.InvalidIndexColumns;
            if (ch == ')') break;
            self.advance();
        }
        if (self.current() != ')') return error.UnexpectedChar;
        const fragment = std.mem.trim(u8, self.input[start..self.pos], " \t\r\n");
        if (fragment.len == 0) return error.InvalidIndexColumns;
        if (include_list) {
            if (!isSafeSchemaIndexIdentifierList(fragment)) return error.InvalidIndexColumns;
        } else {
            if (!isSafeSchemaIndexElementList(fragment)) return error.InvalidIndexColumns;
        }
        self.advance();
        return try self.allocator.dupe(u8, fragment);
    }

    fn parseIndexWhereClause(self: *Parser) !?[]const u8 {
        if (!self.matchKeyword("where")) return null;
        self.skipInlineWhitespace();
        const start = self.pos;
        while (self.current()) |ch| {
            if (ch == '\n' or ch == '\r') break;
            if (ch == '#') break;
            if (ch == '-' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '-') break;
            self.advance();
        }
        const fragment = std.mem.trim(u8, self.input[start..self.pos], " \t\r\n");
        if (fragment.len == 0 or containsUnquotedStatementDelimiter(fragment)) return error.UnsafeSqlFragment;
        return try self.allocator.dupe(u8, fragment);
    }

    fn parseIndex(self: *Parser) !IndexDef {
        const unique = self.matchKeyword("unique");
        if (!self.matchKeyword("index")) return error.ExpectedIndex;
        const concurrently = self.matchKeyword("concurrently");

        const name = try self.parseBareIdentifier();
        errdefer self.allocator.free(name);
        if (!self.matchKeyword("on")) return error.ExpectedIndexOn;
        const table = try self.parseIdentifier();
        errdefer self.allocator.free(table);

        var index_type: ?[]const u8 = null;
        errdefer if (index_type) |value| self.allocator.free(value);
        if (self.matchKeyword("using")) {
            const method = try self.parseBareIdentifier();
            errdefer self.allocator.free(method);
            if (!isAllowedSchemaIndexMethod(method)) return error.InvalidIndexMethod;
            index_type = method;
        }

        const columns = try self.parseIndexListFragment(false);
        errdefer self.allocator.free(columns);

        var include: ?[]const u8 = null;
        errdefer if (include) |value| self.allocator.free(value);
        if (self.matchKeyword("include")) {
            include = try self.parseIndexListFragment(true);
        }

        const where_clause = try self.parseIndexWhereClause();
        errdefer if (where_clause) |value| self.allocator.free(value);

        return .{
            .name = name,
            .table = table,
            .columns = columns,
            .unique = unique,
            .index_type = index_type,
            .include = include,
            .concurrently = concurrently,
            .where_clause = where_clause,
        };
    }

    pub fn parseSchema(self: *Parser) !Schema {
        var schema = Schema.init(self.allocator);
        errdefer schema.deinit();

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;

            if (self.matchKeyword("table")) {
                self.pos -= 5; // rewind "table"
                var table = try self.parseTable();
                if (schema.findTable(table.name) != null) {
                    table.deinit(self.allocator);
                    return error.DuplicateTable;
                }
                try schema.tables.append(self.allocator, table);
            } else if (self.matchKeyword("unique")) {
                self.pos -= 6; // rewind "unique"
                const index = try self.parseIndex();
                if (schema.findIndex(index.name) != null) {
                    index.deinit(self.allocator);
                    return error.DuplicateIndex;
                }
                try schema.indexes.append(self.allocator, index);
            } else if (self.matchKeyword("index")) {
                self.pos -= 5; // rewind "index"
                const index = try self.parseIndex();
                if (schema.findIndex(index.name) != null) {
                    index.deinit(self.allocator);
                    return error.DuplicateIndex;
                }
                try schema.indexes.append(self.allocator, index);
            } else if (self.matchKeyword("policy")) {
                self.pos -= 6; // rewind "policy"
                const policy = try self.parsePolicy();
                if (schema.findPolicy(policy.name, policy.table) != null) {
                    deinitPolicyDef(self.allocator, &policy);
                    return error.DuplicatePolicy;
                }
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
                return error.UnknownSchemaStatement;
            }
        }

        try validateSchemaForeignKeys(&schema);
        try validateSchemaIndexes(&schema);
        return schema;
    }
};

fn containsUnquotedStatementDelimiter(value: []const u8) bool {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;

    while (i < value.len) {
        const b = value[i];
        if (b == 0) return true;

        if (in_single) {
            if (b == '\'') {
                if (i + 1 < value.len and value[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                in_single = false;
            }
            i += 1;
            continue;
        }

        if (in_double) {
            if (b == '"') {
                if (i + 1 < value.len and value[i + 1] == '"') {
                    i += 2;
                    continue;
                }
                in_double = false;
            }
            i += 1;
            continue;
        }

        switch (b) {
            '\'' => in_single = true,
            '"' => in_double = true,
            ';' => return true,
            '-' => if (i + 1 < value.len and value[i + 1] == '-') return true,
            '/' => if (i + 1 < value.len and value[i + 1] == '*') return true,
            '*' => if (i + 1 < value.len and value[i + 1] == '/') return true,
            else => {},
        }
        i += 1;
    }

    return false;
}

fn isSafeSchemaIndexElementList(fragment: []const u8) bool {
    var parts = std.mem.splitScalar(u8, fragment, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (!isSafeSchemaIndexElement(std.mem.trim(u8, part, " \t\r\n"))) return false;
    }
    return count > 0;
}

fn isSafeSchemaIndexIdentifierList(fragment: []const u8) bool {
    var parts = std.mem.splitScalar(u8, fragment, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (!isSchemaQualifiedIdentifier(std.mem.trim(u8, part, " \t\r\n"))) return false;
    }
    return count > 0;
}

fn isSafeSchemaIndexElement(element: []const u8) bool {
    if (element.len == 0 or containsUnquotedStatementDelimiter(element)) return false;
    if (std.mem.indexOfScalar(u8, element, '(') != null or
        std.mem.indexOfScalar(u8, element, ')') != null or
        std.mem.indexOfScalar(u8, element, '\'') != null or
        std.mem.indexOfScalar(u8, element, '"') != null)
    {
        return false;
    }

    var tokens = std.mem.tokenizeAny(u8, element, " \t\r\n");
    const column = tokens.next() orelse return false;
    if (!isSchemaQualifiedIdentifier(column)) return false;
    while (tokens.next()) |token| {
        if (!isAllowedSchemaIndexModifier(token)) return false;
    }
    return true;
}

fn isAllowedSchemaIndexModifier(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "asc") or
        std.ascii.eqlIgnoreCase(token, "desc") or
        std.ascii.eqlIgnoreCase(token, "nulls") or
        std.ascii.eqlIgnoreCase(token, "first") or
        std.ascii.eqlIgnoreCase(token, "last") or
        isAllowedSchemaIndexOpclass(token);
}

fn isAllowedSchemaIndexOpclass(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '_') == null) return false;
    if (token.len == 0 or !std.ascii.isAlphabetic(token[0])) return false;
    for (token[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isSchemaQualifiedIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or std.mem.startsWith(u8, identifier, ".") or std.mem.endsWith(u8, identifier, ".")) {
        return false;
    }
    var parts = std.mem.splitScalar(u8, identifier, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or !Parser.isIdentifierStart(part[0])) return false;
        for (part[1..]) |ch| {
            if (!Parser.isIdentifierPart(ch)) return false;
        }
    }
    return true;
}

fn isAllowedSchemaIndexMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "btree") or
        std.ascii.eqlIgnoreCase(method, "hash") or
        std.ascii.eqlIgnoreCase(method, "gin") or
        std.ascii.eqlIgnoreCase(method, "gist") or
        std.ascii.eqlIgnoreCase(method, "brin") or
        std.ascii.eqlIgnoreCase(method, "spgist") or
        std.ascii.eqlIgnoreCase(method, "hnsw") or
        std.ascii.eqlIgnoreCase(method, "ivfflat");
}

const ForeignKeyReference = struct {
    table: []const u8,
    column: []const u8,
};

fn validateSchemaIndexes(schema: *const Schema) !void {
    for (schema.indexes.items) |index| {
        const table = schema.findTable(index.table) orelse return error.InvalidIndexReference;
        try validateIndexColumnList(table, index.columns);
        if (index.include) |include| try validateIndexIdentifierList(table, include);
    }
}

fn validateIndexColumnList(table: *const TableDef, fragment: []const u8) !void {
    var parts = std.mem.splitScalar(u8, fragment, ',');
    while (parts.next()) |part| {
        const column_name = indexElementColumnName(std.mem.trim(u8, part, " \t\r\n")) orelse return error.InvalidIndexReference;
        if (table.findColumn(column_name) == null) return error.InvalidIndexReference;
    }
}

fn validateIndexIdentifierList(table: *const TableDef, fragment: []const u8) !void {
    var parts = std.mem.splitScalar(u8, fragment, ',');
    while (parts.next()) |part| {
        const column_name = unqualifiedIdentifier(std.mem.trim(u8, part, " \t\r\n"));
        if (table.findColumn(column_name) == null) return error.InvalidIndexReference;
    }
}

fn indexElementColumnName(element: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, element, " \t\r\n");
    const column = tokens.next() orelse return null;
    return unqualifiedIdentifier(column);
}

fn unqualifiedIdentifier(identifier: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, identifier, '.')) |dot| {
        return identifier[dot + 1 ..];
    }
    return identifier;
}

fn validateSchemaForeignKeys(schema: *const Schema) !void {
    for (schema.tables.items) |table| {
        for (table.columns.items) |col| {
            const refs = col.references orelse continue;
            const target = try parseForeignKeyReference(refs);
            const target_table = schema.findTable(target.table) orelse return error.InvalidForeignKeyReference;
            const target_column = target_table.findColumn(target.column) orelse return error.InvalidForeignKeyReference;
            if (!target_column.primary_key and !target_column.unique) {
                return error.InvalidForeignKeyReference;
            }
        }
    }
}

fn parseForeignKeyReference(refs: []const u8) !ForeignKeyReference {
    const trimmed = std.mem.trim(u8, refs, " \t\r\n");
    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.InvalidForeignKeyReference;
    const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, ')') orelse return error.InvalidForeignKeyReference;
    if (std.mem.indexOfScalarPos(u8, trimmed, close + 1, ')') != null) return error.InvalidForeignKeyReference;

    const table = std.mem.trim(u8, trimmed[0..open], " \t\r\n");
    const column = std.mem.trim(u8, trimmed[open + 1 .. close], " \t\r\n");
    const trailing = std.mem.trim(u8, trimmed[close + 1 ..], " \t\r\n");

    if (table.len == 0 or column.len == 0 or trailing.len != 0) return error.InvalidForeignKeyReference;
    if (!isForeignKeyTableIdentifier(table) or !isForeignKeyColumnIdentifier(column)) {
        return error.InvalidForeignKeyReference;
    }
    return .{ .table = table, .column = column };
}

fn isForeignKeyTableIdentifier(identifier: []const u8) bool {
    var parts = std.mem.splitScalar(u8, identifier, '.');
    while (parts.next()) |part| {
        if (!isForeignKeyColumnIdentifier(part)) return false;
    }
    return true;
}

fn isForeignKeyColumnIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or !Parser.isIdentifierStart(identifier[0])) return false;
    for (identifier[1..]) |ch| {
        if (!Parser.isIdentifierPart(ch)) return false;
    }
    return true;
}

fn validateTableKeyTypes(table: *const TableDef) !void {
    for (table.columns.items) |col| {
        if (col.primary_key and !canBePrimaryKeyColumn(&col)) {
            return error.InvalidPrimaryKeyColumnType;
        }
        if (col.unique and !supportsUniqueConstraint(&col)) {
            return error.InvalidUniqueColumnType;
        }
    }
}

fn canBePrimaryKeyColumn(col: *const ColumnDef) bool {
    if (col.is_array) return false;
    if (isUnsupportedUniqueType(col.typ)) return false;
    return !isUnsupportedPrimaryKeyType(col.typ);
}

fn supportsUniqueConstraint(col: *const ColumnDef) bool {
    return !isUnsupportedUniqueType(col.typ);
}

fn isUnsupportedUniqueType(typ: []const u8) bool {
    const names = [_][]const u8{ "json", "jsonb", "bytea", "xml" };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(typ, name)) return true;
    }
    return false;
}

fn isUnsupportedPrimaryKeyType(typ: []const u8) bool {
    const names = [_][]const u8{
        "interval",
        "int4range",
        "int8range",
        "numrange",
        "tsrange",
        "tstzrange",
        "daterange",
        "int4multirange",
        "int8multirange",
        "nummultirange",
        "tsmultirange",
        "tstzmultirange",
        "datemultirange",
    };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(typ, name)) return true;
    }
    return false;
}

fn validateTableCheckReferences(table: *const TableDef) !void {
    for (table.columns.items) |col| {
        if (col.check) |expr| {
            try validateCheckColumnReferences(table, expr);
        }
        for (col.extra_checks) |expr| {
            try validateCheckColumnReferences(table, expr);
        }
    }
}

fn validateCheckColumnReferences(table: *const TableDef, expr: []const u8) !void {
    var i: usize = 0;
    var in_single = false;

    while (i < expr.len) {
        const b = expr[i];

        if (in_single) {
            if (b == '\'') {
                if (i + 1 < expr.len and expr[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                in_single = false;
            }
            i += 1;
            continue;
        }

        if (b == '\'') {
            in_single = true;
            i += 1;
            continue;
        }

        if (!isCheckIdentifierStart(b)) {
            i += 1;
            continue;
        }

        const start = i;
        i += 1;
        while (i < expr.len and isCheckIdentifierContinue(expr[i])) : (i += 1) {}
        const token = expr[start..i];
        const referenced = unqualifiedCheckIdentifier(token);

        if (isCheckKeyword(referenced)) continue;
        if (isCastTypeToken(expr, start)) continue;
        if (nextNonWhitespace(expr, i) == '(') continue;

        if (table.findColumn(referenced) == null) {
            return error.InvalidCheckColumnReference;
        }
    }
}

fn isCheckIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isCheckIdentifierContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn unqualifiedCheckIdentifier(token: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, token, '.')) |dot| {
        return token[dot + 1 ..];
    }
    return token;
}

fn isCastTypeToken(expr: []const u8, token_start: usize) bool {
    var idx = token_start;
    while (idx > 0 and std.ascii.isWhitespace(expr[idx - 1])) : (idx -= 1) {}
    return idx >= 2 and expr[idx - 1] == ':' and expr[idx - 2] == ':';
}

fn nextNonWhitespace(expr: []const u8, start: usize) ?u8 {
    var idx = start;
    while (idx < expr.len) : (idx += 1) {
        if (!std.ascii.isWhitespace(expr[idx])) return expr[idx];
    }
    return null;
}

fn isCheckKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{
        "and",
        "or",
        "not",
        "null",
        "is",
        "in",
        "between",
        "like",
        "ilike",
        "similar",
        "to",
        "true",
        "false",
        "unknown",
        "case",
        "when",
        "then",
        "else",
        "end",
        "coalesce",
        "distinct",
        "from",
        "as",
        "any",
        "all",
    };

    for (keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(token, keyword)) return true;
    }
    return false;
}

fn parseOwnedPolicyExpr(allocator: Allocator, input: []const u8) !Expr {
    var normalized = try tryParseNormalizedPolicyExpr(allocator, input);
    if (normalized != null) {
        return normalized.?.take();
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = PolicyExprParser.init(arena.allocator(), input);
    const arena_expr = parser.parse() catch |err| switch (err) {
        error.OutOfMemory, error.InvalidPolicyNumeric => return err,
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

    fn isIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isIdentPart(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    fn isValidIdentifierPath(path: []const u8) bool {
        var parts = std.mem.splitScalar(u8, path, '.');
        while (parts.next()) |part| {
            if (part.len == 0 or !isIdentStart(part[0])) return false;
            for (part[1..]) |ch| {
                if (!isIdentPart(ch)) return false;
            }
        }
        return true;
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
        return self.parseOrExpr();
    }

    fn parseOrExpr(self: *PolicyExprParser) anyerror!Expr {
        var expr = try self.parseAndExpr();

        while (true) {
            if (self.matchKeyword("or")) {
                const left = try self.allocator.create(Expr);
                left.* = expr;
                errdefer self.allocator.destroy(left);

                const right_expr = try self.parseAndExpr();
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

            break;
        }

        return expr;
    }

    fn parseAndExpr(self: *PolicyExprParser) anyerror!Expr {
        var expr = try self.parseComparison();

        while (true) {
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
        if (self.current() == '.') return error.InvalidPolicyNumeric;

        if (std.mem.indexOfScalar(u8, digits, '.')) |_| {
            if (policyNumberSignificantDigits(digits) > 15) return error.InvalidPolicyNumeric;
            const value = std.fmt.parseFloat(f64, digits) catch return error.InvalidPolicyNumeric;
            if (!std.math.isFinite(value)) return error.InvalidPolicyNumeric;
            return .{ .literal = Value.fromFloat(value) };
        }

        const value = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidPolicyNumeric;
        return .{ .literal = Value.fromInt(value) };
    }

    fn parseIdentifier(self: *PolicyExprParser) anyerror![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        const first = self.current() orelse return error.ExpectedIdentifier;
        if (!isIdentStart(first)) return error.ExpectedIdentifier;
        self.advance();

        while (self.current()) |ch| {
            if (isIdentChar(ch)) {
                self.advance();
            } else {
                break;
            }
        }

        const identifier = self.input[start..self.pos];
        if (!isValidIdentifierPath(identifier)) return error.ExpectedIdentifier;
        return self.allocator.dupe(u8, identifier);
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

fn policyNumberSignificantDigits(value: []const u8) usize {
    var count: usize = 0;
    var seen_non_zero = false;

    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) continue;
        if (byte != '0') seen_non_zero = true;
        if (seen_non_zero) count += 1;
    }

    return count;
}

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

test "parse table row level security directives" {
    const allocator = std.testing.allocator;

    const input =
        \\table orders {
        \\    id uuid primary_key
        \\    enable_rls
        \\    force_rls
        \\}
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const orders = schema.tables.items[0];
    try std.testing.expectEqualStrings("orders", orders.name);
    try std.testing.expect(orders.enable_rls);
    try std.testing.expect(orders.force_rls);
}

test "parse trailing table row level security directives" {
    const allocator = std.testing.allocator;

    const input =
        \\table orders (
        \\    id uuid primary_key
        \\) enable_rls force_rls
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const orders = schema.tables.items[0];
    try std.testing.expect(orders.enable_rls);
    try std.testing.expect(orders.force_rls);
}

test "parse duplicate table directives fails closed" {
    const allocator = std.testing.allocator;

    const input =
        \\table orders (
        \\    id uuid primary_key
        \\    enable_rls
        \\    enable_rls
        \\)
    ;

    try std.testing.expectError(error.DuplicateTableDirective, Schema.parse(allocator, input));
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

test "parse rich index declaration" {
    const allocator = std.testing.allocator;

    const input =
        \\table users (
        \\    id uuid primary_key
        \\    email text
        \\    created_at timestamp
        \\    deleted_at timestamp
        \\)
        \\
        \\unique index concurrently idx_users_active_email on users using gin (email, created_at DESC NULLS LAST) include (id) where deleted_at IS NULL
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 1), schema.indexes.items.len);
    const index = schema.indexes.items[0];
    try std.testing.expectEqualStrings("idx_users_active_email", index.name);
    try std.testing.expectEqualStrings("users", index.table);
    try std.testing.expect(index.unique);
    try std.testing.expect(index.concurrently);
    try std.testing.expectEqualStrings("gin", index.index_type.?);
    try std.testing.expectEqualStrings("email, created_at DESC NULLS LAST", index.columns);
    try std.testing.expectEqualStrings("id", index.include.?);
    try std.testing.expectEqualStrings("deleted_at IS NULL", index.where_clause.?);
}

test "parse index rejects expressions and missing columns" {
    const allocator = std.testing.allocator;

    const expression_input =
        \\table users (
        \\    id uuid primary_key
        \\    email text
        \\)
        \\
        \\index idx_users_lower_email on users (lower(email))
    ;
    try std.testing.expectError(error.InvalidIndexColumns, Schema.parse(allocator, expression_input));

    const missing_column_input =
        \\table users (
        \\    id uuid primary_key
        \\)
        \\
        \\index idx_users_email on users (email)
    ;
    try std.testing.expectError(error.InvalidIndexReference, Schema.parse(allocator, missing_column_input));
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
        \\    name varchar(255) not null,
        \\    amount numeric(10, 2)
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

    const amount = items.findColumn("amount").?;
    try std.testing.expectEqualStrings("numeric", amount.typ);
    try std.testing.expectEqualStrings("10, 2", amount.type_params.?);
}

fn expectSchemaParseFailure(input: []const u8) !void {
    var schema = Schema.parse(std.testing.allocator, input) catch return;
    defer schema.deinit();
    return error.ExpectedSchemaParseFailure;
}

test "schema parser rejects malformed types and params" {
    const invalid_inputs = [_][]const u8{
        \\table users (
        \\    id 1uuid
        \\)
        ,
        \\table users (
        \\    id uuid-name
        \\)
        ,
        \\table users (
        \\    id varchar()
        \\)
        ,
        \\table users (
        \\    id varchar( )
        \\)
        ,
        \\table users (
        \\    id varchar(255,)
        \\)
        ,
        \\table users (
        \\    id varchar(,255)
        \\)
        ,
        \\table users (
        \\    id varchar(255,,10)
        \\)
        ,
        \\table users (
        \\    id varchar(size)
        \\)
        ,
        \\table users (
        \\    id varchar(255
        \\)
        ,
    };

    for (invalid_inputs) |input| {
        try expectSchemaParseFailure(input);
    }
}

test "schema parser rejects malformed identifiers" {
    const invalid_inputs = [_][]const u8{
        \\table 1users (
        \\    id uuid
        \\)
        ,
        \\table .users (
        \\    id uuid
        \\)
        ,
        \\table users. (
        \\    id uuid
        \\)
        ,
        \\table users..archive (
        \\    id uuid
        \\)
        ,
        \\table users (
        \\    1id uuid
        \\)
        ,
        \\table users (
        \\    .id uuid
        \\)
        ,
        \\table users (
        \\    id. uuid
        \\)
        ,
        \\table users (
        \\    profile.id uuid
        \\)
        ,
    };

    for (invalid_inputs) |input| {
        try expectSchemaParseFailure(input);
    }
}

test "schema parser rejects empty tables and duplicate schema objects" {
    const invalid_inputs = [_][]const u8{
        \\table empty (
        \\)
        ,
        \\table users (
        \\    id uuid,
        \\    id text
        \\)
        ,
        \\table users (
        \\    id uuid
        \\)
        \\table users (
        \\    email text
        \\)
        ,
        \\table users (
        \\    id uuid
        \\)
        \\policy users_filter on users using (id = 1)
        \\policy users_filter on users using (id = 2)
        ,
    };

    for (invalid_inputs) |input| {
        try expectSchemaParseFailure(input);
    }
}

test "schema parser rejects unknown top-level input" {
    const invalid_inputs = [_][]const u8{
        \\not_a_schema_statement
        ,
        \\table_name users (
        \\    id uuid
        \\)
        ,
        \\table users (
        \\    id uuid
        \\)
        \\trailing garbage
        ,
        \\table users (
        \\    id uuid
        \\)
        \\view users_view as select * from users
        ,
    };

    for (invalid_inputs) |input| {
        try expectSchemaParseFailure(input);
    }
}

test "schema parser skips sql comments inside table blocks" {
    const input =
        \\table users (
        \\    -- external auth identifier
        \\    id uuid
        \\    # display name
        \\    name text
        \\)
    ;

    var schema = try Schema.parse(std.testing.allocator, input);
    defer schema.deinit();

    const users = schema.findTable("users").?;
    try std.testing.expectEqual(@as(usize, 2), users.columns.items.len);
    try std.testing.expectEqualStrings("id", users.columns.items[0].name);
    try std.testing.expectEqualStrings("name", users.columns.items[1].name);
}

test "schema parser rejects duplicate and contradictory column constraints" {
    const invalid_inputs = [_][]const u8{
        \\table users (
        \\    id uuid primary_key primary_key
        \\)
        ,
        \\table users (
        \\    id uuid primary key primary_key
        \\)
        ,
        \\table users (
        \\    id uuid unique unique
        \\)
        ,
        \\table users (
        \\    id uuid nullable null
        \\)
        ,
        \\table users (
        \\    id uuid not null not_null
        \\)
        ,
        \\table users (
        \\    id uuid default 1 default 2
        \\)
        ,
        \\table users (
        \\    id uuid primary_key null
        \\)
        ,
        \\table users (
        \\    id uuid nullable primary_key
        \\)
        ,
        \\table users (
        \\    id uuid not nullable
        \\)
        ,
        \\table users (
        \\    id uuid references users(id) references accounts(id)
        \\)
        ,
        \\table users (
        \\    id uuid default
        \\)
        ,
        \\table users (
        \\    id uuid check ()
        \\)
        ,
    };

    for (invalid_inputs) |input| {
        try expectSchemaParseFailure(input);
    }
}

test "schema parser rejects unsafe key column types" {
    const allocator = std.testing.allocator;

    const invalid_primary_key_inputs = [_][]const u8{
        \\table events (
        \\    data jsonb primary_key
        \\)
        ,
        \\table events (
        \\    data bytea primary_key
        \\)
        ,
        \\table events (
        \\    tags text[] primary_key
        \\)
        ,
        \\table events (
        \\    duration interval primary_key
        \\)
        ,
        \\table events (
        \\    active_window tstzrange primary_key
        \\)
        ,
    };

    for (invalid_primary_key_inputs) |input| {
        try std.testing.expectError(error.InvalidPrimaryKeyColumnType, Schema.parse(allocator, input));
    }

    const invalid_unique_inputs = [_][]const u8{
        \\table events (
        \\    data jsonb unique
        \\)
        ,
        \\table events (
        \\    payload bytea unique
        \\)
        ,
        \\table events (
        \\    data json unique
        \\)
        ,
        \\table events (
        \\    document xml unique
        \\)
        ,
    };

    for (invalid_unique_inputs) |input| {
        try std.testing.expectError(error.InvalidUniqueColumnType, Schema.parse(allocator, input));
    }

    const valid_input =
        \\table endpoints (
        \\    address inet primary_key,
        \\    tags text[] unique
        \\)
    ;

    var schema = try Schema.parse(allocator, valid_input);
    defer schema.deinit();

    const endpoints = schema.findTable("endpoints").?;
    try std.testing.expect(endpoints.findColumn("address").?.primary_key);
    try std.testing.expect(endpoints.findColumn("tags").?.unique);
}

test "schema parser keeps constraint keywords inside quoted expressions" {
    const allocator = std.testing.allocator;

    const input =
        \\table messages (
        \\    plain text default 'unique not null primary key references users(id) check(x)',
        \\    fn_default text default unique_label(),
        \\    guarded text check(guarded = 'unique not null primary key')
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const messages = schema.tables.items[0];
    const plain = messages.findColumn("plain").?;
    try std.testing.expectEqualStrings("'unique not null primary key references users(id) check(x)'", plain.default_value.?);
    try std.testing.expect(!plain.unique);
    try std.testing.expect(plain.nullable);
    try std.testing.expect(!plain.primary_key);
    try std.testing.expect(plain.references == null);
    try std.testing.expect(plain.check == null);

    const fn_default = messages.findColumn("fn_default").?;
    try std.testing.expectEqualStrings("unique_label()", fn_default.default_value.?);
    try std.testing.expect(!fn_default.unique);

    const guarded = messages.findColumn("guarded").?;
    try std.testing.expectEqualStrings("guarded = 'unique not null primary key'", guarded.check.?);
    try std.testing.expect(!guarded.unique);
}

test "schema parser preserves multiple column checks" {
    const allocator = std.testing.allocator;

    const input =
        \\table products (
        \\    score integer check (score >= 0) check (score <= 100)
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const products = schema.tables.items[0];
    const score = products.findColumn("score").?;
    try std.testing.expectEqual(@as(usize, 2), score.checkCount());
    try std.testing.expectEqualStrings("score >= 0", score.check.?);
    try std.testing.expectEqual(@as(usize, 1), score.extra_checks.len);
    try std.testing.expectEqualStrings("score <= 100", score.extra_checks[0]);
}

test "schema parser ignores parentheses inside double quoted SQL fragments" {
    const allocator = std.testing.allocator;

    const input =
        \\table products (
        \\    weird text,
        \\    label text default coalesce("weird)", 'fallback') check ("weird)" <> '(')
        \\)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const products = schema.tables.items[0];
    const label = products.findColumn("label").?;
    try std.testing.expectEqualStrings("coalesce(\"weird)\", 'fallback')", label.default_value.?);
    try std.testing.expectEqualStrings("\"weird)\" <> '('", label.check.?);
}

test "schema parser validates column check references" {
    const invalid_input =
        \\table orders (
        \\    status text check (missing_status = 'paid')
        \\)
    ;
    try expectSchemaParseFailure(invalid_input);

    const invalid_extra_input =
        \\table orders (
        \\    status text check (status = 'paid') check (missing_status = 'paid')
        \\)
    ;
    try expectSchemaParseFailure(invalid_extra_input);

    const allocator = std.testing.allocator;
    const valid_input =
        \\table bookings (
        \\    starts_at timestamp check (starts_at <= coalesce(ends_at, '2099-12-31'::timestamp)),
        \\    ends_at timestamp,
        \\    code text check (length(code) <= 12 and code <> 'missing_name')
        \\)
    ;

    var schema = try Schema.parse(allocator, valid_input);
    defer schema.deinit();

    const bookings = schema.tables.items[0];
    try std.testing.expect(bookings.findColumn("starts_at") != null);
    try std.testing.expect(bookings.findColumn("ends_at") != null);
    try std.testing.expect(bookings.findColumn("code") != null);
}

test "schema parser validates foreign key references" {
    const allocator = std.testing.allocator;

    const valid_input =
        \\table posts (
        \\    id uuid primary_key,
        \\    user_id uuid references users(id),
        \\    author_email text references users(email)
        \\)
        \\
        \\table users (
        \\    id uuid primary_key,
        \\    email text unique
        \\)
    ;

    var schema = try Schema.parse(allocator, valid_input);
    defer schema.deinit();

    const posts = schema.findTable("posts").?;
    try std.testing.expectEqualStrings("users(id)", posts.findColumn("user_id").?.references.?);
    try std.testing.expectEqualStrings("users(email)", posts.findColumn("author_email").?.references.?);

    const invalid_inputs = [_][]const u8{
        \\table posts (
        \\    user_id uuid references users(id)
        \\)
        ,
        \\table users (
        \\    id uuid primary_key
        \\)
        \\table posts (
        \\    user_id uuid references users(missing_id)
        \\)
        ,
        \\table users (
        \\    email text
        \\)
        \\table posts (
        \\    author_email text references users(email)
        \\)
        ,
        \\table users (
        \\    id uuid primary_key,
        \\    email text unique
        \\)
        \\table posts (
        \\    user_id uuid references users(id, email)
        \\)
        ,
        \\table users (
        \\    id uuid primary_key
        \\)
        \\table posts (
        \\    user_id uuid references users.id
        \\)
        ,
    };

    for (invalid_inputs) |input| {
        try std.testing.expectError(error.InvalidForeignKeyReference, Schema.parse(allocator, input));
    }
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

test "parse policy block rejects duplicate clauses" {
    const invalid_inputs = [_][]const u8{
        \\table orders (
        \\    id uuid primary_key
        \\)
        \\policy p on orders for select for update using (id = 1)
        ,
        \\table orders (
        \\    id uuid primary_key
        \\)
        \\policy p on orders to app_user to app_admin using (id = 1)
        ,
        \\table orders (
        \\    id uuid primary_key
        \\)
        \\policy p on orders restrictive restrictive using (id = 1)
        ,
        \\table orders (
        \\    id uuid primary_key
        \\)
        \\policy p on orders using (id = 1) using (id = 2)
        ,
        \\table orders (
        \\    id uuid primary_key
        \\)
        \\policy p on orders with check (id = 1) with_check (id = 2)
        ,
    };

    for (invalid_inputs) |input| {
        try expectSchemaParseFailure(input);
    }
}

test "parse policy block handles escaped strings and rejects unterminated strings" {
    const allocator = std.testing.allocator;

    const input =
        \\table users (
        \\    id uuid primary_key,
        \\    name text
        \\)
        \\policy users_name on users
        \\    for select
        \\    using (name = 'Bob''s account')
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const policy = schema.policies.items[0];
    const expr = policy.using_expr.?;
    try std.testing.expect(expr == .binary);
    try std.testing.expect(expr.binary.right.* == .literal);
    try std.testing.expect(expr.binary.right.literal == .string);
    try std.testing.expectEqualStrings("Bob's account", expr.binary.right.literal.string);

    try expectSchemaParseFailure(
        \\table users (
        \\    id uuid primary_key,
        \\    name text
        \\)
        \\policy users_name on users
        \\    for select
        \\    using (name = 'unterminated)
    );
}

test "parse policy block rejects overflowing numeric literals" {
    const huge_int = "999999999999999999999999999999999999999999999999";
    const huge_float =
        "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999.0";
    const bad_literals = [_][]const u8{
        huge_int,
        huge_float,
        "1.2.3",
        "9007199254740993.25",
    };

    for (bad_literals) |literal| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            \\table users (
            \\    id uuid primary_key,
            \\    risk numeric
            \\)
            \\policy users_risk on users
            \\    using (risk = {s})
        ,
            .{literal},
        );
        defer std.testing.allocator.free(input);

        try expectSchemaParseFailure(input);
    }
}

test "parse policy block ignores parentheses inside double quoted identifiers" {
    const allocator = std.testing.allocator;

    const input =
        \\table users (
        \\    tenant text
        \\)
        \\policy users_tenant on users
        \\    using ("tenant)" = current_setting('app.tenant_id'))
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const policy = schema.policies.items[0];
    const expr = policy.using_expr.?;
    try std.testing.expect(expr == .raw);
    try std.testing.expectEqualStrings("\"tenant)\" = current_setting('app.tenant_id')", expr.raw);
}

test "parse policy block gives and higher precedence than or" {
    const allocator = std.testing.allocator;

    const input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid,
        \\    active bool,
        \\    public bool
        \\)
        \\policy mixed on orders
        \\    for select
        \\    using (public = true or tenant_id = 7 and active = true)
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    const expr = schema.policies.items[0].using_expr.?;
    try std.testing.expect(expr == .binary);
    try std.testing.expectEqual(BinaryOp.@"or", expr.binary.op);
    try std.testing.expect(expr.binary.right.* == .binary);
    try std.testing.expectEqual(BinaryOp.@"and", expr.binary.right.binary.op);
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
    try std.testing.expectEqualStrings("SELECT", grant.privileges[0]);
    try std.testing.expectEqualStrings("INSERT", grant.privileges[1]);
    try std.testing.expectEqualStrings("users", grant.on_object);
    try std.testing.expectEqualStrings("app_role", grant.role);

    const revoke = schema.grants.items[1];
    try std.testing.expectEqual(GrantAction.revoke, revoke.action);
    try std.testing.expectEqual(@as(usize, 1), revoke.privileges.len);
    try std.testing.expectEqualStrings("UPDATE", revoke.privileges[0]);
    try std.testing.expectEqualStrings("users", revoke.on_object);
    try std.testing.expectEqualStrings("app_role", revoke.role);
}

test "parse grant privileges are canonicalized and allowlisted" {
    const allocator = std.testing.allocator;

    const input =
        \\grant all privileges on users to app_role
        \\grant temp on database_name to app_role
    ;

    var schema = try Schema.parse(allocator, input);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 2), schema.grants.items.len);
    try std.testing.expectEqual(@as(usize, 1), schema.grants.items[0].privileges.len);
    try std.testing.expectEqualStrings("ALL PRIVILEGES", schema.grants.items[0].privileges[0]);
    try std.testing.expectEqual(@as(usize, 1), schema.grants.items[1].privileges.len);
    try std.testing.expectEqualStrings("TEMPORARY", schema.grants.items[1].privileges[0]);
}

test "parse grant rejects invalid privileges" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.ExpectedPrivilege, Schema.parse(allocator, "grant own on users to app_role"));
    try std.testing.expectError(error.ExpectedPrivilege, Schema.parse(allocator, "grant select; drop table users on users to app_role"));
}
