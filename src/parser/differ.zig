// Schema Differ
//
// Computes the difference between two schemas and generates migration commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("../runtime/io.zig");
const schema = @import("schema.zig");
const compare = @import("differ/compare.zig");
const differ_types = @import("differ/types.zig");
const Schema = schema.Schema;
const ColumnDef = schema.ColumnDef;
pub const MigrationCmd = differ_types.MigrationCmd;
pub const IndexInfo = differ_types.IndexInfo;

// ============================================================================
// Differ
// ============================================================================

fn columnTypesEquivalent(old_col: *const ColumnDef, new_col: *const ColumnDef) bool {
    if (old_col.is_serial != new_col.is_serial) return false;
    if (old_col.is_array != new_col.is_array) return false;
    const old_kind = normalizedTypeKind(old_col.typ);
    const new_kind = normalizedTypeKind(new_col.typ);
    if (old_kind == .decimal and new_kind == .decimal) {
        return typeParamsEquivalent(old_col.type_params, new_col.type_params);
    }
    if (!std.ascii.eqlIgnoreCase(old_col.typ, new_col.typ)) return false;
    return typeParamsEquivalent(old_col.type_params, new_col.type_params);
}

fn isSafeColumnTypeChange(old_col: *const ColumnDef, new_col: *const ColumnDef) bool {
    if (columnTypesEquivalent(old_col, new_col)) return true;
    if (old_col.is_serial or new_col.is_serial) return false;
    if (old_col.is_array != new_col.is_array) return false;

    const old_kind = normalizedTypeKind(old_col.typ);
    const new_kind = normalizedTypeKind(new_col.typ);

    if (old_kind == .smallint and (new_kind == .integer or new_kind == .bigint)) return true;
    if (old_kind == .integer and new_kind == .bigint) return true;

    if (isUnboundedCharacterType(new_kind, new_col.type_params) and isCharacterKind(old_kind)) return true;
    if (old_kind == .varchar and new_kind == .varchar) {
        return varcharWidening(old_col.type_params, new_col.type_params);
    }
    if (old_kind == .decimal and new_kind == .decimal) {
        return decimalWidening(old_col.type_params, new_col.type_params);
    }

    return false;
}

const TypeKind = enum {
    smallint,
    integer,
    bigint,
    text,
    varchar,
    decimal,
    other,
};

fn normalizedTypeKind(typ: []const u8) TypeKind {
    const trimmed = std.mem.trim(u8, typ, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "i16") or
        std.ascii.eqlIgnoreCase(trimmed, "smallint") or
        std.ascii.eqlIgnoreCase(trimmed, "int2"))
    {
        return .smallint;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "i32") or
        std.ascii.eqlIgnoreCase(trimmed, "int") or
        std.ascii.eqlIgnoreCase(trimmed, "integer") or
        std.ascii.eqlIgnoreCase(trimmed, "int4"))
    {
        return .integer;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "i64") or
        std.ascii.eqlIgnoreCase(trimmed, "bigint") or
        std.ascii.eqlIgnoreCase(trimmed, "int8"))
    {
        return .bigint;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "text")) return .text;
    if (std.ascii.eqlIgnoreCase(trimmed, "varchar") or
        std.ascii.eqlIgnoreCase(trimmed, "character varying"))
    {
        return .varchar;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "numeric") or
        std.ascii.eqlIgnoreCase(trimmed, "decimal"))
    {
        return .decimal;
    }
    return .other;
}

fn isCharacterKind(kind: TypeKind) bool {
    return kind == .text or kind == .varchar;
}

fn isUnboundedCharacterType(kind: TypeKind, params: ?[]const u8) bool {
    return kind == .text or (kind == .varchar and params == null);
}

fn varcharWidening(old_params: ?[]const u8, new_params: ?[]const u8) bool {
    if (new_params == null) return true;
    if (old_params == null) return false;

    const old_len = parseSingleTypeParam(old_params.?) orelse return false;
    const new_len = parseSingleTypeParam(new_params.?) orelse return false;
    return new_len >= old_len;
}

fn parseSingleTypeParam(params: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, params, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, ',') != null) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

fn decimalWidening(old_params: ?[]const u8, new_params: ?[]const u8) bool {
    if (new_params == null) return old_params != null;
    if (old_params == null) return false;

    const old_decimal = parseDecimalTypeParams(old_params.?) orelse return false;
    const new_decimal = parseDecimalTypeParams(new_params.?) orelse return false;
    const old_integer_digits = old_decimal.precision - old_decimal.scale;
    const new_integer_digits = new_decimal.precision - new_decimal.scale;
    return new_integer_digits >= old_integer_digits and new_decimal.scale >= old_decimal.scale;
}

const DecimalTypeParams = struct {
    precision: u64,
    scale: u64,
};

fn parseDecimalTypeParams(params: []const u8) ?DecimalTypeParams {
    var parts = std.mem.splitScalar(u8, params, ',');
    const precision_raw = parts.next() orelse return null;
    const precision_text = std.mem.trim(u8, precision_raw, " \t\r\n");
    if (precision_text.len == 0) return null;
    const precision = std.fmt.parseInt(u64, precision_text, 10) catch return null;
    if (precision == 0) return null;

    var scale: u64 = 0;
    if (parts.next()) |scale_raw| {
        const scale_text = std.mem.trim(u8, scale_raw, " \t\r\n");
        if (scale_text.len == 0) return null;
        scale = std.fmt.parseInt(u64, scale_text, 10) catch return null;
        if (parts.next() != null) return null;
    }
    if (scale > precision) return null;

    return .{
        .precision = precision,
        .scale = scale,
    };
}

fn columnChecksEquivalent(old_col: *const ColumnDef, new_col: *const ColumnDef) bool {
    const old_count = old_col.checkCount();
    const new_count = new_col.checkCount();
    if (old_count != new_count) return false;
    for (0..old_count) |i| {
        if (!checkExpressionsEquivalent(old_col.checkAt(i), new_col.checkAt(i))) return false;
    }
    return true;
}

fn optionalTextEquivalent(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return eqlIgnoreAsciiWhitespace(left.?, right.?);
}

fn optionalTrimmedTextEquivalent(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(
        u8,
        std.mem.trim(u8, left.?, " \t\r\n"),
        std.mem.trim(u8, right.?, " \t\r\n"),
    );
}

fn columnReferencesEquivalent(old_col: *const ColumnDef, new_col: *const ColumnDef) bool {
    return optionalTextEquivalent(old_col.references, new_col.references);
}

fn columnDefaultsEquivalent(old_col: *const ColumnDef, new_col: *const ColumnDef) bool {
    return optionalTrimmedTextEquivalent(old_col.default_value, new_col.default_value);
}

fn validateExistingColumnConstraintDrift(old_col: *const ColumnDef, new_col: *const ColumnDef) !void {
    if (old_col.primary_key != new_col.primary_key) return error.UnsupportedPrimaryKeyConstraintDrift;
    if (old_col.unique != new_col.unique) return error.UnsupportedUniqueConstraintDrift;
    if (old_col.nullable != new_col.nullable and !old_col.primary_key and !new_col.primary_key) {
        return error.UnsupportedNullabilityConstraintDrift;
    }
    if (!columnReferencesEquivalent(old_col, new_col)) return error.UnsupportedReferenceConstraintDrift;
    if (!columnDefaultsEquivalent(old_col, new_col)) return error.UnsupportedDefaultConstraintDrift;
    if (!columnChecksEquivalent(old_col, new_col)) return error.UnsupportedCheckConstraintDrift;
}

fn validateNewExistingTableColumn(column: *const ColumnDef) !void {
    if (column.primary_key) return error.UnsupportedPrimaryKeyColumnBackfill;
    if (!column.nullable and column.default_value == null) return error.UnsupportedRequiredColumnBackfill;
    if (column.unique and column.default_value != null) return error.UnsupportedUniqueColumnBackfill;
    if (column.references != null and column.default_value != null) return error.UnsupportedReferenceColumnBackfill;
    if (column.checkCount() > 0 and (!column.nullable or column.default_value != null)) {
        return error.UnsupportedCheckColumnBackfill;
    }
}

fn checkExpressionsEquivalent(left: []const u8, right: []const u8) bool {
    const normalized_left = stripRedundantOuterParens(std.mem.trim(u8, left, " \t\r\n"));
    const normalized_right = stripRedundantOuterParens(std.mem.trim(u8, right, " \t\r\n"));
    return eqlCheckExpressionUnits(normalized_left, normalized_right);
}

fn stripRedundantOuterParens(input: []const u8) []const u8 {
    var current = input;
    while (hasRedundantOuterParens(current)) {
        current = std.mem.trim(u8, current[1 .. current.len - 1], " \t\r\n");
    }
    return current;
}

fn hasRedundantOuterParens(input: []const u8) bool {
    if (input.len < 2 or input[0] != '(' or input[input.len - 1] != ')') return false;

    var depth: usize = 0;
    var in_single = false;
    var in_double = false;

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (in_single) {
            if (b == '\'') {
                if (i + 1 < input.len and input[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }

        if (in_double) {
            if (b == '"') {
                if (i + 1 < input.len and input[i + 1] == '"') {
                    i += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }

        switch (b) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0 and i != input.len - 1) return false;
            },
            else => {},
        }
    }

    return depth == 0;
}

fn typeParamsEquivalent(old_params: ?[]const u8, new_params: ?[]const u8) bool {
    if (old_params == null and new_params == null) return true;
    if (old_params == null or new_params == null) return false;
    return eqlIgnoreAsciiWhitespace(old_params.?, new_params.?);
}

fn eqlIgnoreAsciiWhitespace(left: []const u8, right: []const u8) bool {
    var left_i: usize = 0;
    var right_i: usize = 0;

    while (true) {
        while (left_i < left.len and std.ascii.isWhitespace(left[left_i])) : (left_i += 1) {}
        while (right_i < right.len and std.ascii.isWhitespace(right[right_i])) : (right_i += 1) {}

        if (left_i == left.len or right_i == right.len) {
            return left_i == left.len and right_i == right.len;
        }

        if (std.ascii.toLower(left[left_i]) != std.ascii.toLower(right[right_i])) {
            return false;
        }

        left_i += 1;
        right_i += 1;
    }
}

const CheckComparableUnit = union(enum) {
    byte: u8,
    identifier: []const u8,
};

const CheckExpressionScanner = struct {
    input: []const u8,
    index: usize = 0,
    in_single: bool = false,

    fn next(self: *CheckExpressionScanner) ?CheckComparableUnit {
        if (!self.in_single) {
            while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) {
                self.index += 1;
            }
        }
        if (self.index >= self.input.len) return null;

        const ch = self.input[self.index];
        if (self.in_single) {
            self.index += 1;
            if (ch == '\'') {
                if (self.index < self.input.len and self.input[self.index] == '\'') {
                    self.index += 1;
                } else {
                    self.in_single = false;
                }
            }
            return .{ .byte = ch };
        }

        if (ch == '\'') {
            self.in_single = true;
            self.index += 1;
            return .{ .byte = ch };
        }

        if (ch == '"') {
            if (self.quotedSimpleLowercaseIdentifier()) |identifier| {
                return .{ .identifier = identifier };
            }
            self.index += 1;
            return .{ .byte = ch };
        }

        if (isUnquotedCheckIdentifierStart(ch)) {
            const start = self.index;
            self.index += 1;
            while (self.index < self.input.len and isUnquotedCheckIdentifierContinue(self.input[self.index])) {
                self.index += 1;
            }
            return .{ .identifier = self.input[start..self.index] };
        }

        self.index += 1;
        return .{ .byte = std.ascii.toLower(ch) };
    }

    fn quotedSimpleLowercaseIdentifier(self: *CheckExpressionScanner) ?[]const u8 {
        const content_start = self.index + 1;
        var idx = content_start;
        while (idx < self.input.len) : (idx += 1) {
            const ch = self.input[idx];
            if (ch == '"') {
                if (idx + 1 < self.input.len and self.input[idx + 1] == '"') return null;
                const content = self.input[content_start..idx];
                if (!isSimpleLowercaseIdentifier(content)) return null;
                self.index = idx + 1;
                return content;
            }
        }
        return null;
    }
};

fn eqlCheckExpressionUnits(left: []const u8, right: []const u8) bool {
    var left_scanner = CheckExpressionScanner{ .input = left };
    var right_scanner = CheckExpressionScanner{ .input = right };

    while (true) {
        const left_unit = left_scanner.next();
        const right_unit = right_scanner.next();
        if (left_unit == null or right_unit == null) return left_unit == null and right_unit == null;
        if (!checkComparableUnitsEqual(left_unit.?, right_unit.?)) return false;
    }
}

fn checkComparableUnitsEqual(left: CheckComparableUnit, right: CheckComparableUnit) bool {
    return switch (left) {
        .byte => |left_byte| switch (right) {
            .byte => |right_byte| left_byte == right_byte,
            .identifier => false,
        },
        .identifier => |left_identifier| switch (right) {
            .byte => false,
            .identifier => |right_identifier| std.ascii.eqlIgnoreCase(left_identifier, right_identifier),
        },
    };
}

fn isUnquotedCheckIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isUnquotedCheckIdentifierContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

fn isSimpleLowercaseIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!(isAsciiLower(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |ch| {
        if (!(isAsciiLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    }
    return true;
}

fn isAsciiLower(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

/// Compute the difference between two schemas.
/// Returns a list of migration commands needed to go from `old` to `new`.
pub fn diffSchemas(allocator: Allocator, old: *const Schema, new: *const Schema) !std.ArrayList(MigrationCmd) {
    var cmds = std.ArrayList(MigrationCmd).initCapacity(allocator, 0) catch unreachable;
    errdefer deinitDiffCommands(allocator, &cmds);

    // 1. Detect new tables - CREATE TABLE with all columns (AST-native)
    for (new.tables.items) |new_table| {
        if (old.findTable(new_table.name) == null) {
            // Copy column slice for AST-native CREATE TABLE
            const cols = try allocator.alloc(ColumnDef, new_table.columns.items.len);
            for (new_table.columns.items, 0..) |col, i| {
                cols[i] = col;
            }
            try cmds.append(allocator, MigrationCmd{
                .action = .create_table,
                .table = new_table.name,
                .table_columns = cols,
            });
        }
    }

    // 2. Detect dropped tables
    for (old.tables.items) |old_table| {
        if (new.findTable(old_table.name) == null) {
            try cmds.append(allocator, MigrationCmd{
                .action = .drop_table,
                .table = old_table.name,
            });
        }
    }

    // 3. Detect column changes in existing tables
    for (new.tables.items) |new_table| {
        if (old.findTable(new_table.name)) |old_table| {
            // New columns
            for (new_table.columns.items) |new_col| {
                if (old_table.findColumn(new_col.name) == null) {
                    try validateNewExistingTableColumn(&new_col);
                    try cmds.append(allocator, MigrationCmd{
                        .action = .add_column,
                        .table = new_table.name,
                        .column = new_col,
                    });
                }
            }

            // Dropped columns
            for (old_table.columns.items) |old_col| {
                if (new_table.findColumn(old_col.name) == null) {
                    try cmds.append(allocator, MigrationCmd{
                        .action = .drop_column,
                        .table = new_table.name,
                        .column = old_col,
                    });
                }
            }

            // Type changes (alter column)
            for (new_table.columns.items) |new_col| {
                if (old_table.findColumn(new_col.name)) |old_col| {
                    if (!columnTypesEquivalent(old_col, &new_col)) {
                        if (!isSafeColumnTypeChange(old_col, &new_col)) {
                            return error.UnsupportedColumnTypeDrift;
                        }
                        try cmds.append(allocator, MigrationCmd{
                            .action = .alter_column,
                            .table = new_table.name,
                            .column = new_col,
                        });
                    }
                    try validateExistingColumnConstraintDrift(old_col, &new_col);
                }
            }
        }
    }

    // 4. Detect policy changes
    for (new.policies.items) |*new_policy| {
        if (old.findPolicy(new_policy.name, new_policy.table)) |old_policy| {
            if (!compare.policyEquals(old_policy, new_policy)) {
                try cmds.append(allocator, MigrationCmd{
                    .action = .drop_policy,
                    .table = old_policy.table,
                    .policy = old_policy.*,
                });
                try cmds.append(allocator, MigrationCmd{
                    .action = .create_policy,
                    .table = new_policy.table,
                    .policy = new_policy.*,
                });
            }
        } else {
            try cmds.append(allocator, MigrationCmd{
                .action = .create_policy,
                .table = new_policy.table,
                .policy = new_policy.*,
            });
        }
    }

    for (old.policies.items) |*old_policy| {
        if (new.findPolicy(old_policy.name, old_policy.table) == null) {
            try cmds.append(allocator, MigrationCmd{
                .action = .drop_policy,
                .table = old_policy.table,
                .policy = old_policy.*,
            });
        }
    }

    // 5. Detect grant/revoke changes
    for (new.grants.items) |*new_grant| {
        var exists = false;
        for (old.grants.items) |*old_grant| {
            if (compare.grantEquals(old_grant, new_grant)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            const cmd_action: MigrationCmd.Action = switch (new_grant.action) {
                .grant => .grant,
                .revoke => .revoke,
            };
            try cmds.append(allocator, MigrationCmd{
                .action = cmd_action,
                .table = new_grant.on_object,
                .grant = new_grant.*,
            });
        }
    }

    for (old.grants.items) |*old_grant| {
        var exists = false;
        for (new.grants.items) |*new_grant| {
            if (compare.grantEquals(old_grant, new_grant)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var inverse_grant = old_grant.*;
            const cmd_action: MigrationCmd.Action = switch (old_grant.action) {
                .grant => blk: {
                    inverse_grant.action = .revoke;
                    break :blk .revoke;
                },
                .revoke => blk: {
                    inverse_grant.action = .grant;
                    break :blk .grant;
                },
            };
            try cmds.append(allocator, MigrationCmd{
                .action = cmd_action,
                .table = old_grant.on_object,
                .grant = inverse_grant,
            });
        }
    }

    return cmds;
}

fn deinitDiffCommands(allocator: Allocator, cmds: *std.ArrayList(MigrationCmd)) void {
    for (cmds.items) |cmd| {
        if (cmd.table_columns.len > 0) allocator.free(cmd.table_columns);
    }
    cmds.deinit(allocator);
}

/// Generate SQL statements from migration commands
pub fn toSqlStatements(allocator: Allocator, cmds: *const std.ArrayList(MigrationCmd)) ![]const u8 {
    var writer = io.AllocatingWriter.init(allocator);
    defer writer.deinit();
    const w = writer.writer();

    for (cmds.items) |cmd| {
        const sql = try cmd.toSql(allocator);
        defer allocator.free(sql);
        try w.print("{s};\n", .{sql});
    }

    return writer.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "diff new table" {
    const allocator = std.testing.allocator;

    const old_input = "";
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    name text not null
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    // New design: 1 create_table with full DDL (no separate add_column)
    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .create_table);
}

test "diff new table preserves column check constraint" {
    const allocator = std.testing.allocator;

    const old_input = "";
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table inventory (
        \\    quantity integer check (quantity >= 0)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.create_table, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CHECK (quantity >= 0)") != null);

    const qail_cmd = try cmds.items[0].toQailCmd(allocator);
    defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);
    try std.testing.expectEqualStrings("quantity >= 0", qail_cmd.columns[0].column_def.constraints[0].check[0]);

    const AstEncoder = @import("../protocol/ast_encoder.zig").AstEncoder;
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();
    const encoded_sql = try encoder.toSqlOwned(allocator, &qail_cmd);
    defer allocator.free(encoded_sql);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS inventory (quantity integer CHECK (quantity >= 0))",
        encoded_sql,
    );
}

test "diff new table preserves multiple column check constraints" {
    const allocator = std.testing.allocator;

    const old_input = "";
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table inventory (
        \\    quantity integer check (quantity >= 0) check (quantity <= 100)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.create_table, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CHECK (quantity >= 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CHECK (quantity <= 100)") != null);

    const qail_cmd = try cmds.items[0].toQailCmd(allocator);
    defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);
    try std.testing.expectEqual(@as(usize, 2), qail_cmd.columns[0].column_def.constraints[0].check.len);
    try std.testing.expectEqualStrings("quantity >= 0", qail_cmd.columns[0].column_def.constraints[0].check[0]);
    try std.testing.expectEqualStrings("quantity <= 100", qail_cmd.columns[0].column_def.constraints[0].check[1]);

    const AstEncoder = @import("../protocol/ast_encoder.zig").AstEncoder;
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();
    const encoded_sql = try encoder.toSqlOwned(allocator, &qail_cmd);
    defer allocator.free(encoded_sql);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS inventory (quantity integer CHECK (quantity >= 0) CHECK (quantity <= 100))",
        encoded_sql,
    );
}

test "diff dropped table" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input = "";
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .drop_table);
}

test "diff new column" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    email text
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .add_column);
    try std.testing.expectEqualStrings("email", cmds.items[0].column.?.name);
}

test "diff new column preserves column check constraint" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table players (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table players (
        \\    id uuid primary_key,
        \\    score integer check (score >= 0)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.add_column, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE players ADD COLUMN score integer CHECK (score >= 0)",
        sql,
    );

    const qail_cmd = try cmds.items[0].toQailCmd(allocator);
    defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);
    try std.testing.expectEqualStrings("score >= 0", qail_cmd.columns[0].column_def.constraints[0].check[0]);

    const AstEncoder = @import("../protocol/ast_encoder.zig").AstEncoder;
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();
    const encoded_sql = try encoder.toSqlOwned(allocator, &qail_cmd);
    defer allocator.free(encoded_sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE players ADD COLUMN score integer CHECK (score >= 0)",
        encoded_sql,
    );
}

test "diff new column preserves multiple check constraints" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table players (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table players (
        \\    id uuid primary_key,
        \\    score integer check (score >= 0) check (score <= 100)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.add_column, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE players ADD COLUMN score integer CHECK (score >= 0) CHECK (score <= 100)",
        sql,
    );

    const qail_cmd = try cmds.items[0].toQailCmd(allocator);
    defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);
    try std.testing.expectEqual(@as(usize, 2), qail_cmd.columns[0].column_def.constraints[0].check.len);

    const AstEncoder = @import("../protocol/ast_encoder.zig").AstEncoder;
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();
    const encoded_sql = try encoder.toSqlOwned(allocator, &qail_cmd);
    defer allocator.free(encoded_sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE players ADD COLUMN score integer CHECK (score >= 0) CHECK (score <= 100)",
        encoded_sql,
    );
}

test "diff existing column check drift fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table inventory (
        \\    quantity integer check (quantity >= 0)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table inventory (
        \\    quantity integer check (quantity > 0)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedCheckConstraintDrift, diffSchemas(allocator, &old, &new));
}

test "diff existing column multiple checks stay equivalent" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table inventory (
        \\    quantity integer check (((quantity >= 0))) check (quantity <= 100)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table inventory (
        \\    quantity integer check ( quantity>=0 ) check ((quantity <= 100))
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff existing column check ignores lowercase identifier quotes" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table schedule_patterns (
        \\    interval integer check ("interval" > 0)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table schedule_patterns (
        \\    interval integer check (interval > 0)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff existing column check keeps non-simple identifier quotes distinct" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table schedule_patterns (
        \\    interval integer check ("Interval" > 0)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table schedule_patterns (
        \\    interval integer check (interval > 0)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(
        error.UnsupportedCheckConstraintDrift,
        diffSchemas(allocator, &old, &new),
    );
}

test "diff existing column extra check drift fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table inventory (
        \\    quantity integer check (quantity >= 0)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table inventory (
        \\    quantity integer check (quantity >= 0) check (quantity <= 100)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(
        error.UnsupportedCheckConstraintDrift,
        diffSchemas(allocator, &old, &new),
    );
}

test "diff existing column check ignores redundant parentheses and whitespace" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table inventory (
        \\    quantity integer check (((quantity >= 0)))
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table inventory (
        \\    quantity integer check ( quantity>=0 )
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff new required column without default fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    email text not null
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedRequiredColumnBackfill, diffSchemas(allocator, &old, &new));
}

test "diff new required column with default remains explicit in SQL" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    status text not null default 'active'
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.add_column, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE users ADD COLUMN status text NOT NULL DEFAULT 'active'",
        sql,
    );
}

test "diff new primary key column on existing table fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table api_keys (
        \\    label text
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table api_keys (
        \\    label text,
        \\    key text primary_key
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedPrimaryKeyColumnBackfill, diffSchemas(allocator, &old, &new));
}

test "diff new unique column with default fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    invite_code text unique default 'pending'
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedUniqueColumnBackfill, diffSchemas(allocator, &old, &new));
}

test "diff new nullable unique column preserves unique constraint" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    invite_code text unique
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE users ADD COLUMN invite_code text UNIQUE",
        sql,
    );
}

test "diff new reference column with default fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table tenants (
        \\    id uuid primary_key
        \\)
        \\
        \\table orders (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table tenants (
        \\    id uuid primary_key
        \\)
        \\
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid references tenants(id) default '00000000-0000-0000-0000-000000000000'
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedReferenceColumnBackfill, diffSchemas(allocator, &old, &new));
}

test "diff new nullable reference column preserves reference constraint" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table tenants (
        \\    id uuid primary_key
        \\)
        \\
        \\table orders (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table tenants (
        \\    id uuid primary_key
        \\)
        \\
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid references tenants(id)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE orders ADD COLUMN tenant_id uuid REFERENCES tenants(id)",
        sql,
    );
}

test "diff existing column constraint drift fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    email text
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const unique_input =
        \\table users (
        \\    email text unique
        \\)
    ;
    var with_unique = try Schema.parse(allocator, unique_input);
    defer with_unique.deinit();
    try std.testing.expectError(error.UnsupportedUniqueConstraintDrift, diffSchemas(allocator, &old, &with_unique));

    const not_null_input =
        \\table users (
        \\    email text not null
        \\)
    ;
    var with_not_null = try Schema.parse(allocator, not_null_input);
    defer with_not_null.deinit();
    try std.testing.expectError(error.UnsupportedNullabilityConstraintDrift, diffSchemas(allocator, &old, &with_not_null));

    const default_input =
        \\table users (
        \\    email text default 'active'
        \\)
    ;
    var with_default = try Schema.parse(allocator, default_input);
    defer with_default.deinit();
    try std.testing.expectError(error.UnsupportedDefaultConstraintDrift, diffSchemas(allocator, &old, &with_default));

    const reference_old_input =
        \\table tenants (
        \\    id uuid primary_key
        \\)
        \\
        \\table orders (
        \\    tenant_id uuid
        \\)
    ;
    var reference_old = try Schema.parse(allocator, reference_old_input);
    defer reference_old.deinit();

    const reference_new_input =
        \\table tenants (
        \\    id uuid primary_key
        \\)
        \\
        \\table orders (
        \\    tenant_id uuid references tenants(id)
        \\)
    ;
    var reference_new = try Schema.parse(allocator, reference_new_input);
    defer reference_new.deinit();
    try std.testing.expectError(error.UnsupportedReferenceConstraintDrift, diffSchemas(allocator, &reference_old, &reference_new));
}

test "diff new column preserves full type in SQL and AST" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    email varchar(255)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.add_column, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE users ADD COLUMN email varchar(255)",
        sql,
    );

    const qail_cmd = try cmds.items[0].toQailCmd(allocator);
    defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);
    try std.testing.expectEqualStrings("varchar(255)", qail_cmd.columns[0].column_def.data_type);
}

test "diff dropped column" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key,
        \\    legacy text
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .drop_column);
    try std.testing.expectEqualStrings("legacy", cmds.items[0].column.?.name);
}

test "diff type change" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key,
        \\    count i32
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    count i64
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expect(cmds.items[0].action == .alter_column);
}

test "diff type params change" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    id uuid primary_key,
        \\    email varchar(64)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key,
        \\    email varchar(255)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.alter_column, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE users ALTER COLUMN email TYPE varchar(255)",
        sql,
    );

    const qail_cmd = try cmds.items[0].toQailCmd(allocator);
    defer MigrationCmd.deinitQailCmd(allocator, &qail_cmd);
    try std.testing.expectEqualStrings("varchar(255)", qail_cmd.columns[0].column_def.data_type);
}

test "diff unsafe type change fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table events (
        \\    external_id text
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table events (
        \\    external_id uuid
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedColumnTypeDrift, diffSchemas(allocator, &old, &new));
}

test "diff varchar narrowing fails closed" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table users (
        \\    display_name varchar(255)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    display_name varchar(64)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedColumnTypeDrift, diffSchemas(allocator, &old, &new));
}

test "diff type params ignore whitespace only drift" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table invoices (
        \\    amount numeric(10, 2)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table invoices (
        \\    amount numeric(10,2)
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff decimal typmod widening is safe" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table prices (
        \\    amount numeric(12, 6)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const unbounded_input =
        \\table prices (
        \\    amount numeric
        \\)
    ;
    var unbounded = try Schema.parse(allocator, unbounded_input);
    defer unbounded.deinit();

    var unbounded_cmds = try diffSchemas(allocator, &old, &unbounded);
    defer unbounded_cmds.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), unbounded_cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.alter_column, unbounded_cmds.items[0].action);

    const unbounded_sql = try unbounded_cmds.items[0].toSql(allocator);
    defer allocator.free(unbounded_sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE prices ALTER COLUMN amount TYPE numeric",
        unbounded_sql,
    );

    const wider_input =
        \\table prices (
        \\    amount decimal(14,8)
        \\)
    ;
    var wider = try Schema.parse(allocator, wider_input);
    defer wider.deinit();

    var wider_cmds = try diffSchemas(allocator, &old, &wider);
    defer wider_cmds.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wider_cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.alter_column, wider_cmds.items[0].action);

    const wider_sql = try wider_cmds.items[0].toSql(allocator);
    defer allocator.free(wider_sql);
    try std.testing.expectEqualStrings(
        "ALTER TABLE prices ALTER COLUMN amount TYPE decimal(14,8)",
        wider_sql,
    );
}

test "diff decimal typmod narrowing fails closed" {
    const allocator = std.testing.allocator;

    const unbounded_input =
        \\table prices (
        \\    amount numeric
        \\)
    ;
    var unbounded = try Schema.parse(allocator, unbounded_input);
    defer unbounded.deinit();

    const bounded_input =
        \\table prices (
        \\    amount numeric(12, 6)
        \\)
    ;
    var bounded = try Schema.parse(allocator, bounded_input);
    defer bounded.deinit();

    try std.testing.expectError(
        error.UnsupportedColumnTypeDrift,
        diffSchemas(allocator, &unbounded, &bounded),
    );

    const old_input =
        \\table prices (
        \\    amount numeric(12, 6)
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const scale_narrowing_input =
        \\table prices (
        \\    amount numeric(12, 5)
        \\)
    ;
    var scale_narrowing = try Schema.parse(allocator, scale_narrowing_input);
    defer scale_narrowing.deinit();

    try std.testing.expectError(
        error.UnsupportedColumnTypeDrift,
        diffSchemas(allocator, &old, &scale_narrowing),
    );

    const integer_digit_narrowing_input =
        \\table prices (
        \\    amount numeric(11, 6)
        \\)
    ;
    var integer_digit_narrowing = try Schema.parse(allocator, integer_digit_narrowing_input);
    defer integer_digit_narrowing.deinit();

    try std.testing.expectError(
        error.UnsupportedColumnTypeDrift,
        diffSchemas(allocator, &old, &integer_digit_narrowing),
    );
}

test "diff array type suffix change" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table articles (
        \\    tags text
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table articles (
        \\    tags text[]
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    try std.testing.expectError(error.UnsupportedColumnTypeDrift, diffSchemas(allocator, &old, &new));
}

test "generate sql" {
    const allocator = std.testing.allocator;

    const old_input = "";
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table users (
        \\    id uuid primary_key
        \\)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer {
        for (cmds.items) |cmd| {
            if (cmd.table_columns.len > 0) {
                allocator.free(cmd.table_columns);
            }
        }
        cmds.deinit(allocator);
    }

    const sql = try toSqlStatements(allocator, &cmds);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "id uuid") != null);
}

test "diff policy create and drop" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.tenant_id')::uuid)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    var has_create_policy = false;
    for (cmds.items) |cmd| {
        if (cmd.action == .create_policy) {
            has_create_policy = true;
            const sql = try cmd.toSql(allocator);
            defer allocator.free(sql);
            try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE POLICY orders_tenant_isolation ON orders") != null);
        }
    }
    try std.testing.expect(has_create_policy);
}

test "diff policy predicate change emits drop and recreate" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.tenant_id')::uuid)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.current_tenant_id')::uuid)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    var saw_drop = false;
    var saw_create = false;
    for (cmds.items) |cmd| {
        switch (cmd.action) {
            .drop_policy => saw_drop = true,
            .create_policy => {
                saw_create = true;
                const sql = try cmd.toSql(allocator);
                defer allocator.free(sql);
                try std.testing.expect(std.mem.indexOf(u8, sql, "current_setting('app.current_tenant_id')::uuid") != null);
            },
            else => {},
        }
    }

    try std.testing.expect(saw_drop);
    try std.testing.expect(saw_create);
}

test "diff policy ignores nullif wrapped tenant predicate equivalent" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = current_setting('app.current_tenant_id')::uuid)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table orders (
        \\    id uuid primary_key,
        \\    tenant_id uuid not null
        \\)
        \\policy orders_tenant_isolation on orders
        \\  for all
        \\  restrictive
        \\  using (tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff policy ignores coalesce wrapped boolean predicate equivalent" {
    const allocator = std.testing.allocator;

    const old_input =
        \\table secrets (
        \\    id uuid primary_key
        \\)
        \\policy admin_bypass on secrets
        \\  using (current_setting('app.is_super_admin')::boolean = true)
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input =
        \\table secrets (
        \\    id uuid primary_key
        \\)
        \\policy admin_bypass on secrets
        \\  using (COALESCE(current_setting('app.is_super_admin'::text, true), 'false'::text) = 'true'::text)
    ;
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}

test "diff grant removal emits revoke" {
    const allocator = std.testing.allocator;

    const old_input =
        \\grant select, insert on users to app_role
    ;
    var old = try Schema.parse(allocator, old_input);
    defer old.deinit();

    const new_input = "";
    var new = try Schema.parse(allocator, new_input);
    defer new.deinit();

    var cmds = try diffSchemas(allocator, &old, &new);
    defer cmds.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(MigrationCmd.Action.revoke, cmds.items[0].action);

    const sql = try cmds.items[0].toSql(allocator);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "REVOKE SELECT, INSERT ON users FROM app_role") != null);
}
