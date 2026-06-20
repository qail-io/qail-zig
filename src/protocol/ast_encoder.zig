// AST-Native Wire Encoder
//
// Encodes QAIL AST (QailCmd) directly to PostgreSQL wire protocol bytes.
// NO SQL STRING GENERATION - this is the core of QAIL's philosophy.

const std = @import("std");
const io = @import("../runtime/io.zig");
const ast = struct {
    pub const cmd = @import("../ast/cmd.zig");
    pub const expr = @import("../ast/expr.zig");
    pub const raw_cmd = @import("../ast/raw_cmd.zig");
    pub const trusted_policy_sql = @import("../ast/trusted_policy_sql.zig");
    pub const values = @import("../ast/values.zig");
    pub const operators = @import("../ast/operators.zig");
    pub const QailCmd = cmd.QailCmd;
    pub const Expr = expr.Expr;
    pub const Value = values.Value;
    pub const Operator = operators.Operator;
};
const wire = @import("wire.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Value = ast.Value;
const Operator = ast.Operator;
const TableConstraint = ast.cmd.TableConstraint;
const ColumnDef = @TypeOf(@as(Expr, undefined).column_def);
const WindowExpr = @TypeOf(@as(Expr, undefined).window);
const FrontendMessage = wire.FrontendMessage;
const PROTOCOL_VERSION = wire.PROTOCOL_VERSION;
const max_wire_message_len: usize = std.math.maxInt(i32);
const MAX_RAW_FUNCTION_VALUE_LEN: usize = 1024;

const INVALID_FUNCTION_NAME = "/* ERROR: Invalid function name */";
const INVALID_FUNCTION_KEYWORD = "/* ERROR: Invalid function keyword */";
const INVALID_WINDOW_FUNCTION_NAME = "/* ERROR: Invalid window function name */";
const INVALID_CAST_TARGET = "/* ERROR: Invalid cast target type */";
const INVALID_IDENTIFIER = "/* ERROR: Invalid identifier */";
const INVALID_INSERT_COLUMN = "/* ERROR: Invalid insert column */";
const INVALID_RAW_FRAGMENT = "/* ERROR: Invalid raw SQL fragment */";
const INVALID_COLUMN_TYPE = "/* ERROR: Invalid column type */";
const INVALID_COLUMN_FRAGMENT = "/* ERROR: Invalid column definition fragment */";

/// AST-to-Wire encoder
/// Directly encodes QailCmd AST to PostgreSQL Extended Query Protocol bytes
pub const AstEncoder = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    param_count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) AstEncoder {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AstEncoder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *AstEncoder) void {
        self.buffer.clearRetainingCapacity();
        self.param_count = 0;
    }

    pub fn getWritten(self: *const AstEncoder) []const u8 {
        return self.buffer.items;
    }

    // ==================== Low-level Writers ====================

    fn writeByte(self: *AstEncoder, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    fn writeBytes(self: *AstEncoder, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn writeU32(self: *AstEncoder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    fn writeU16(self: *AstEncoder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    fn writeI32(self: *AstEncoder, value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .big);
        try self.buffer.appendSlice(self.allocator, &bytes);
    }

    fn writeCString(self: *AstEncoder, str: []const u8) !void {
        if (std.mem.indexOfScalar(u8, str, 0) != null) return error.NullByte;
        try self.buffer.appendSlice(self.allocator, str);
        try self.buffer.append(self.allocator, 0);
    }

    fn addLenChecked(total: *usize, add: usize) !void {
        total.* = std.math.add(usize, total.*, add) catch return error.MessageTooLarge;
    }

    fn addCStringLenChecked(total: *usize, s: []const u8) !void {
        try addLenChecked(total, s.len);
        try addLenChecked(total, 1);
    }

    fn toWireLen(total: usize) !u32 {
        if (total > max_wire_message_len) return error.MessageTooLarge;
        return @intCast(total);
    }

    fn toWireI32Len(total: usize) !i32 {
        if (total > max_wire_message_len) return error.MessageTooLarge;
        return @intCast(total);
    }

    // ==================== AST-Native Encoding ====================

    /// Encode a complete query pipeline from AST
    /// Returns: Parse + Bind + Describe + Execute + Sync messages
    pub fn encodeQuery(self: *AstEncoder, cmd: *const QailCmd) !void {
        self.reset();

        // Generate a unique statement name
        const stmt_name = "";
        const portal_name = "";

        // 1. Parse message with embedded SQL from AST
        try self.encodeParse(stmt_name, cmd);

        // 2. Bind message (no parameters for now)
        try self.encodeBind(portal_name, stmt_name, &.{});

        // 3. Describe portal
        try self.encodeDescribe(portal_name);

        // 4. Execute
        try self.encodeExecute(portal_name, 0);

        // 5. Sync
        try self.encodeSync();
    }

    /// Append a query to the buffer WITHOUT resetting and WITHOUT Sync.
    /// Use this for pipeline batching — call once per query, then call
    /// appendSync() at the end. Unlike encodeQuery(), this accumulates
    /// multiple queries in the buffer.
    pub fn appendQuery(self: *AstEncoder, cmd: *const QailCmd) !void {
        const stmt_name = "";
        const portal_name = "";

        try self.encodeParse(stmt_name, cmd);
        try self.encodeBind(portal_name, stmt_name, &.{});
        try self.encodeExecute(portal_name, 0);
    }

    /// Append Sync to the buffer WITHOUT resetting (for pipeline batching).
    pub fn appendSync(self: *AstEncoder) !void {
        try self.encodeSync();
    }

    /// Encode Parse message with AST-generated query structure
    fn encodeParse(self: *AstEncoder, stmt_name: []const u8, cmd: *const QailCmd) !void {
        try self.writeByte(@intFromEnum(FrontendMessage.parse));
        const len_pos = self.buffer.items.len;
        try self.writeU32(0); // patched after SQL is written
        try self.writeCString(stmt_name);

        var sql_writer = io.AllocatingWriter.init(self.allocator);
        defer sql_writer.deinit();
        try self.writeAstToSql(sql_writer.writer(), cmd);
        const sql = try sql_writer.toOwnedSlice();
        defer self.allocator.free(sql);
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.NullByte;
        try self.writeBytes(sql);
        try self.writeByte(0); // SQL cstring terminator
        try self.writeU16(0); // No parameter types

        const msg_len_usize = std.math.sub(usize, self.buffer.items.len, len_pos) catch return error.MessageTooLarge;
        const msg_len = try toWireLen(msg_len_usize);
        std.mem.writeInt(u32, self.buffer.items[len_pos..][0..4], msg_len, .big);
    }

    /// Encode Bind message
    fn encodeBind(self: *AstEncoder, portal: []const u8, stmt_name: []const u8, params: []const ?[]const u8) !void {
        if (params.len > std.math.maxInt(i16)) return error.TooManyParameters;

        var params_size: usize = 0;
        for (params) |param| {
            try addLenChecked(&params_size, 4);
            if (param) |p| {
                _ = try toWireI32Len(p.len);
                try addLenChecked(&params_size, p.len);
            }
        }

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, portal);
        try addCStringLenChecked(&msg_len_usize, stmt_name);
        try addLenChecked(&msg_len_usize, 2);
        try addLenChecked(&msg_len_usize, 2);
        try addLenChecked(&msg_len_usize, params_size);
        try addLenChecked(&msg_len_usize, 2);
        const msg_len = try toWireLen(msg_len_usize);

        try self.writeByte(@intFromEnum(FrontendMessage.bind));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeCString(stmt_name);
        try self.writeU16(0); // No format codes
        try self.writeU16(@intCast(params.len));

        for (params) |param| {
            if (param) |p| {
                try self.writeI32(try toWireI32Len(p.len));
                try self.writeBytes(p);
            } else {
                try self.writeI32(-1);
            }
        }

        try self.writeU16(0); // No result format codes
    }

    /// Encode Describe message
    fn encodeDescribe(self: *AstEncoder, portal: []const u8) !void {
        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addLenChecked(&msg_len_usize, 1);
        try addCStringLenChecked(&msg_len_usize, portal);
        const msg_len = try toWireLen(msg_len_usize);
        try self.writeByte(@intFromEnum(FrontendMessage.describe));
        try self.writeU32(msg_len);
        try self.writeByte('P');
        try self.writeCString(portal);
    }

    /// Encode Execute message
    fn encodeExecute(self: *AstEncoder, portal: []const u8, max_rows: u32) !void {
        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, portal);
        try addLenChecked(&msg_len_usize, 4);
        const msg_len = try toWireLen(msg_len_usize);
        try self.writeByte(@intFromEnum(FrontendMessage.execute));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeU32(max_rows);
    }

    /// Encode Sync message
    fn encodeSync(self: *AstEncoder) !void {
        try self.writeByte(@intFromEnum(FrontendMessage.sync));
        try self.writeU32(4);
    }

    // ==================== Prepared Statement Protocol ====================

    /// Encode only Parse message for preparing a statement from AST
    pub fn encodePrepare(self: *AstEncoder, stmt_name: []const u8, cmd: *const QailCmd) !void {
        self.buffer.clearRetainingCapacity();
        try self.encodeParse(stmt_name, cmd);
        try self.encodeSync();
    }

    /// Encode Parse + Sync from a raw SQL string (for cache-based prepare flow)
    pub fn encodePrepareNamed(self: *AstEncoder, stmt_name: []const u8, sql: []const u8) !void {
        self.buffer.clearRetainingCapacity();

        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, stmt_name);
        try addCStringLenChecked(&msg_len_usize, sql);
        try addLenChecked(&msg_len_usize, 2);
        const msg_len = try toWireLen(msg_len_usize);

        try self.writeByte(@intFromEnum(FrontendMessage.parse));
        try self.writeU32(msg_len);
        try self.writeCString(stmt_name);
        try self.writeCString(sql);
        try self.writeU16(0); // No parameter types

        try self.encodeSync();
    }

    /// Render AST as SQL bytes using the same encoder path as Parse.
    pub fn toSqlOwned(self: *AstEncoder, allocator: std.mem.Allocator, cmd: *const QailCmd) ![]u8 {
        var writer = io.AllocatingWriter.init(allocator);
        defer writer.deinit();

        try self.writeAstToSql(writer.writer(), cmd);
        return try writer.toOwnedSlice();
    }

    /// Execute a named prepared statement with parameters (Bind + Describe + Execute + Sync)
    pub fn executeNamedStatement(self: *AstEncoder, stmt_name: []const u8, params: []const ?[]const u8) !void {
        self.buffer.clearRetainingCapacity();

        // Use empty portal name (default)
        const portal = "";

        // Bind
        try self.encodeBind(portal, stmt_name, params);

        // Describe portal (to get row description if SELECT)
        try self.encodeDescribe(portal);

        // Execute
        try self.encodeExecute(portal, 0);

        // Sync
        try self.encodeSync();
    }

    // ==================== AST to SQL (temporary - will be replaced with binary protocol) ====================

    /// Write AST as SQL to a writer
    fn writeAstToSql(self: *AstEncoder, writer: anytype, cmd: *const QailCmd) !void {
        _ = self;

        // First check for raw_sql (used for pre-generated DDL). Commands
        // that use raw_sql as a nested source fragment handle it below.
        if (cmd.raw_sql) |raw| {
            if (cmd.kind != .create_view and cmd.kind != .create_materialized_view and
                cmd.kind != .add and cmd.kind != .put and cmd.kind != .upsert)
            {
                try writer.writeAll(raw);
                return;
            }
        }

        switch (cmd.kind) {
            .get => try writeSelect(writer, cmd, false),
            .with => try writeSelect(writer, cmd, false),
            .cnt => try writeSelect(writer, cmd, true),
            .set => {
                try validateUpdateShape(cmd);
                try writer.writeAll("UPDATE ");
                if (cmd.only_table) try writer.writeAll("ONLY ");
                try writeTableReferenceOrError(writer, cmd.table);
                if (cmd.table_alias) |alias| {
                    try writer.writeAll(" AS ");
                    try writeIdentifierOrError(writer, alias);
                }
                try writer.writeAll(" SET ");

                for (cmd.assignments, 0..) |assign, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writeIdentifierOrError(writer, assign.column);
                    try writer.writeAll(" = ");
                    try writeValue(writer, &assign.value, cmd);
                }

                if (cmd.from_tables.len > 0) {
                    try writer.writeAll(" FROM ");
                    for (cmd.from_tables, 0..) |table, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeTableReferenceOrError(writer, table);
                    }
                }

                try writeWhereClauses(writer, cmd.where_clauses, cmd);

                if (cmd.returning.len > 0) {
                    try writer.writeAll(" RETURNING ");
                    for (cmd.returning, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col, cmd);
                    }
                }
            },
            .del => {
                try writer.writeAll("DELETE FROM ");
                if (cmd.only_table) try writer.writeAll("ONLY ");
                try writeTableReferenceOrError(writer, cmd.table);
                if (cmd.table_alias) |alias| {
                    try writer.writeAll(" AS ");
                    try writeIdentifierOrError(writer, alias);
                }

                if (cmd.using_tables.len > 0) {
                    try writer.writeAll(" USING ");
                    for (cmd.using_tables, 0..) |table, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeTableReferenceOrError(writer, table);
                    }
                }

                try writeWhereClauses(writer, cmd.where_clauses, cmd);

                if (cmd.returning.len > 0) {
                    try writer.writeAll(" RETURNING ");
                    for (cmd.returning, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col, cmd);
                    }
                }
            },
            .add => try writeInsertCmd(writer, cmd, false),
            .put, .upsert => try writeInsertCmd(writer, cmd, true),
            .merge => try writeMerge(writer, cmd),
            .truncate => {
                try writer.writeAll("TRUNCATE ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .listen => {
                try writer.writeAll("LISTEN ");
                if (cmd.channel) |ch| {
                    try writeRequiredSingleIdentifier(writer, ch);
                } else {
                    return error.InvalidIdentifier;
                }
            },
            .notify => {
                try writer.writeAll("NOTIFY ");
                if (cmd.channel) |ch| {
                    try writeRequiredSingleIdentifier(writer, ch);
                } else {
                    return error.InvalidIdentifier;
                }
                if (cmd.payload) |p| {
                    try writer.writeAll(", '");
                    try writeEscapedSqlString(writer, p);
                    try writer.writeByte('\'');
                }
            },
            .unlisten => {
                try writer.writeAll("UNLISTEN ");
                if (cmd.channel) |ch| {
                    try writeRequiredSingleIdentifier(writer, ch);
                } else {
                    try writer.writeByte('*');
                }
            },
            .begin => try writer.writeAll("BEGIN"),
            .commit => try writer.writeAll("COMMIT"),
            .rollback => try writer.writeAll("ROLLBACK"),
            .savepoint => {
                try writer.writeAll("SAVEPOINT ");
                if (cmd.savepoint_name) |name| {
                    try writeRequiredSingleIdentifier(writer, name);
                } else {
                    return error.InvalidIdentifier;
                }
            },
            .release => {
                try writer.writeAll("RELEASE SAVEPOINT ");
                if (cmd.savepoint_name) |name| {
                    try writeRequiredSingleIdentifier(writer, name);
                } else {
                    return error.InvalidIdentifier;
                }
            },
            .rollback_to => {
                try writer.writeAll("ROLLBACK TO SAVEPOINT ");
                if (cmd.savepoint_name) |name| {
                    try writeRequiredSingleIdentifier(writer, name);
                } else {
                    return error.InvalidIdentifier;
                }
            },
            // DDL Commands
            .make => {
                try writer.writeAll("CREATE TABLE IF NOT EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
                if (cmd.columns.len > 0 or cmd.table_constraints.len > 0) {
                    try writer.writeAll(" (");
                    for (cmd.columns, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col, null);
                    }
                    for (cmd.table_constraints, 0..) |constraint, i| {
                        if (cmd.columns.len > 0 or i > 0) try writer.writeAll(", ");
                        try writeTableConstraint(writer, constraint);
                    }
                    try writer.writeAll(")");
                }
            },
            .drop => {
                try writer.writeAll("DROP TABLE IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .alter => {
                // ALTER TABLE ADD COLUMN
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" ADD COLUMN ");
                    try writeExpr(writer, &col, null);
                }
            },
            .alter_add_constraint => {
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                if (cmd.table_constraints.len > 0) {
                    for (cmd.table_constraints, 0..) |constraint, i| {
                        if (i > 0) try writer.writeAll(",");
                        try writer.writeAll(" ADD ");
                        try writeTableConstraint(writer, constraint);
                    }
                } else {
                    const name = cmd.channel orelse return error.MissingConstraintName;
                    const expr = cmd.payload orelse return error.MissingConstraintExpression;
                    if (!isSafeSqlExprFragment(expr)) return error.UnsafeSqlFragment;

                    try writer.writeAll(" ADD CONSTRAINT ");
                    try writeIdentifierOrError(writer, name);
                    try writer.writeAll(" CHECK (");
                    try writer.writeAll(std.mem.trim(u8, expr, " \t\r\n"));
                    try writer.writeByte(')');
                }
            },
            .alter_drop_constraint => {
                const name = cmd.channel orelse return error.MissingConstraintName;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" DROP CONSTRAINT ");
                try writeIdentifierOrError(writer, name);
            },
            .alter_drop => {
                // ALTER TABLE DROP COLUMN
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" DROP COLUMN ");
                    try writeExpr(writer, &col, null);
                }
            },
            .mod, .alter_type => {
                // ALTER TABLE ALTER COLUMN TYPE
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" ALTER COLUMN ");
                    // Write column name only (not full def)
                    if (col == .column_def) {
                        try writeIdentifierOrError(writer, col.column_def.name);
                        try writer.writeAll(" TYPE ");
                        const data_type = checkedSqlTypeFragment(col.column_def.data_type) orelse "TEXT";
                        try writer.writeAll(data_type);
                    } else if (col == .named) {
                        try writeIdentifierOrError(writer, col.named);
                    }
                }
            },
            .index => {
                // CREATE INDEX
                if (cmd.index_def) |idx| {
                    if (idx.unique) {
                        try writer.writeAll("CREATE UNIQUE INDEX ");
                    } else {
                        try writer.writeAll("CREATE INDEX ");
                    }
                    if (idx.concurrently) {
                        try writer.writeAll("CONCURRENTLY ");
                    }
                    try writeIdentifierOrError(writer, idx.name);
                    try writer.writeAll(" ON ");
                    try writeIdentifierOrError(writer, idx.table);
                    if (idx.index_type) |index_type| {
                        try writer.writeAll(" USING ");
                        try writeIndexMethodOrError(writer, index_type);
                    }
                    try writer.writeAll(" (");
                    for (idx.columns, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeIndexElementOrError(writer, col);
                    }
                    try writer.writeAll(")");
                    if (idx.include.len > 0) {
                        try writer.writeAll(" INCLUDE (");
                        for (idx.include, 0..) |col, i| {
                            if (i > 0) try writer.writeAll(", ");
                            try writeIdentifierOrError(writer, col);
                        }
                        try writer.writeAll(")");
                    }
                    if (idx.where_clause) |where_clause| {
                        try writer.writeAll(" WHERE ");
                        try writeCheckedRawExpression(writer, where_clause);
                    }
                }
            },
            .drop_index => {
                try writer.writeAll("DROP INDEX IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .create_view => {
                try writer.writeAll("CREATE VIEW ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" AS ");
                if (cmd.source_query) |source_query| {
                    try writeNestedQueryableCmd(writer, source_query);
                } else if (cmd.raw_sql) |raw| {
                    const query = checkedReadOnlySubquerySql(raw) orelse "SELECT NULL WHERE FALSE";
                    try writer.writeAll(query);
                } else {
                    return error.MissingViewSourceQuery;
                }
            },
            .drop_view => {
                try writer.writeAll("DROP VIEW IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .create_materialized_view => {
                try writer.writeAll("CREATE MATERIALIZED VIEW ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" AS ");
                if (cmd.source_query) |source_query| {
                    try writeNestedQueryableCmd(writer, source_query);
                } else if (cmd.raw_sql) |raw| {
                    const query = checkedReadOnlySubquerySql(raw) orelse "SELECT NULL WHERE FALSE";
                    try writer.writeAll(query);
                } else {
                    return error.MissingMaterializedViewSourceQuery;
                }
            },
            .refresh_materialized_view => {
                try writer.writeAll("REFRESH MATERIALIZED VIEW ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .drop_materialized_view => {
                try writer.writeAll("DROP MATERIALIZED VIEW IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .create_function => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else if (cmd.payload) |definition| {
                    const checked_definition = checkedFunctionDefinitionPayload(definition) orelse return error.UnsafeSqlFragment;
                    try writer.writeAll("CREATE FUNCTION ");
                    try writeIdentifierOrError(writer, cmd.table);
                    try writer.writeAll(" ");
                    try writer.writeAll(checked_definition);
                } else {
                    return error.MissingFunctionDefinition;
                }
            },
            .drop_function => {
                try writer.writeAll("DROP FUNCTION IF EXISTS ");
                if (cmd.payload) |signature| {
                    try writeFunctionSignature(writer, signature);
                } else {
                    try writeIdentifierOrError(writer, cmd.table);
                    try writer.writeAll("()");
                }
            },
            .create_trigger => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else if (cmd.payload) |definition| {
                    const checked_definition = checkedTriggerDefinitionPayload(definition) orelse return error.UnsafeSqlFragment;
                    try writer.writeAll("CREATE TRIGGER ");
                    try writeIdentifierOrError(writer, cmd.table);
                    try writer.writeByte(' ');
                    try writer.writeAll(checked_definition);
                } else {
                    return error.MissingTriggerDefinition;
                }
            },
            .drop_trigger => {
                try writer.writeAll("DROP TRIGGER IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
                if (cmd.payload) |on_table| {
                    try writer.writeAll(" ON ");
                    try writeIdentifierOrError(writer, on_table);
                }
            },
            .create_extension => {
                try writer.writeAll("CREATE EXTENSION IF NOT EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .drop_extension => {
                try writer.writeAll("DROP EXTENSION IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .create_sequence => {
                try writer.writeAll("CREATE SEQUENCE ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .drop_sequence => {
                try writer.writeAll("DROP SEQUENCE IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .create_enum => {
                try writer.writeAll("CREATE TYPE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" AS ENUM (");

                if (cmd.insert_values.len > 0) {
                    for (cmd.insert_values, 0..) |val, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeValue(writer, &val, null);
                    }
                } else if (cmd.payload) |values_sql| {
                    const values_fragment = checkedEnumValuesFragment(values_sql) orelse return error.UnsafeSqlFragment;
                    try writer.writeAll(values_fragment);
                } else {
                    return error.MissingEnumValues;
                }
                try writer.writeByte(')');
            },
            .drop_enum => {
                try writer.writeAll("DROP TYPE IF EXISTS ");
                try writeIdentifierOrError(writer, cmd.table);
            },
            .alter_enum_add_value => {
                try writer.writeAll("ALTER TYPE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" ADD VALUE ");
                if (cmd.payload) |val| {
                    try writer.writeByte('\'');
                    try writeEscapedSqlString(writer, val);
                    try writer.writeByte('\'');
                } else {
                    return error.MissingEnumValue;
                }
            },
            .drop_col => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" DROP COLUMN ");
                try writeIdentifierOrError(writer, col_name);
            },
            .rename_col => {
                const from = firstColumnName(cmd) orelse return error.MissingColumnName;
                const to = if (cmd.payload) |p| p else columnNameAt(cmd, 1) orelse return error.MissingRenameTarget;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" RENAME COLUMN ");
                try writeIdentifierOrError(writer, from);
                try writer.writeAll(" TO ");
                try writeIdentifierOrError(writer, to);
            },
            .copy_out => {
                try writer.writeAll("COPY (");
                try writeSelect(writer, cmd, false);
                try writer.writeAll(") TO STDOUT");
            },
            .lock_table => {
                try writer.writeAll("LOCK TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                if (cmd.table_lock_mode) |mode| {
                    try writer.writeByte(' ');
                    try writer.writeAll(mode.toSql());
                } else if (cmd.payload) |mode| {
                    try writer.writeByte(' ');
                    const canonical = checkedTableLockMode(mode) orelse return error.UnsafeSqlFragment;
                    try writer.writeAll(canonical);
                }
            },
            .explain => {
                try writer.writeAll("EXPLAIN ");
                if (cmd.source_query) |source_query| {
                    try writeNestedQueryableCmd(writer, source_query);
                } else if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else if (cmd.table.len > 0) {
                    try writer.writeAll("SELECT * FROM ");
                    try writeTableReferenceOrError(writer, cmd.table);
                } else {
                    return error.MissingExplainQuery;
                }
            },
            .explain_analyze => {
                try writer.writeAll("EXPLAIN ANALYZE ");
                if (cmd.source_query) |source_query| {
                    try writeNestedQueryableCmd(writer, source_query);
                } else if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else if (cmd.table.len > 0) {
                    try writer.writeAll("SELECT * FROM ");
                    try writeTableReferenceOrError(writer, cmd.table);
                } else {
                    return error.MissingExplainQuery;
                }
            },
            .comment_on => {
                try writer.writeAll("COMMENT ON ");
                try writeCommentTarget(writer, cmd.table);
                try writer.writeAll(" IS ");
                if (cmd.payload) |comment| {
                    try writer.writeByte('\'');
                    try writeEscapedSqlStringNoNul(writer, comment);
                    try writer.writeByte('\'');
                } else {
                    try writer.writeAll("NULL");
                }
            },
            .search => try writeSelect(writer, cmd, false),
            .scroll => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else {
                    try writer.writeAll("FETCH ");
                    if (cmd.limit_val) |n| {
                        try writer.print("FORWARD {d} ", .{n});
                    } else {
                        try writer.writeAll("NEXT ");
                    }
                    try writer.writeAll("FROM ");
                    try writeIdentifierOrError(writer, cmd.table);
                }
            },
            .over => try writeSelect(writer, cmd, false),
            .json_table => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else {
                    return error.UnsupportedCommandForPostgres;
                }
            },
            .create_collection, .delete_collection, .gen => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else {
                    return error.UnsupportedCommandForPostgres;
                }
            },
            .alter_set_not_null => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writeIdentifierOrError(writer, col_name);
                try writer.writeAll(" SET NOT NULL");
            },
            .alter_drop_not_null => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writeIdentifierOrError(writer, col_name);
                try writer.writeAll(" DROP NOT NULL");
            },
            .alter_set_default => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writeIdentifierOrError(writer, col_name);
                try writer.writeAll(" SET DEFAULT ");
                const default_expr = if (cmd.payload) |payload|
                    checkedSqlExprFragment(payload) orelse "NULL"
                else
                    "NULL";
                try writer.writeAll(default_expr);
            },
            .alter_drop_default => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writeIdentifierOrError(writer, col_name);
                try writer.writeAll(" DROP DEFAULT");
            },
            .alter_enable_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" ENABLE ROW LEVEL SECURITY");
            },
            .alter_disable_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" DISABLE ROW LEVEL SECURITY");
            },
            .alter_force_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" FORCE ROW LEVEL SECURITY");
            },
            .alter_no_force_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" NO FORCE ROW LEVEL SECURITY");
            },
            .call => {
                try writer.writeAll("CALL ");
                try writeCallTarget(writer, cmd.table);
            },
            .do_block => {
                const lang = if (cmd.table.len == 0) "plpgsql" else cmd.table;
                try writer.writeAll("DO ");
                try writeDollarQuotedBlock(writer, cmd.payload orelse "");
                try writer.writeAll(" LANGUAGE ");
                try writeIdentifierMaybeQuoted(writer, lang);
            },
            .session_set => {
                try writer.writeAll("SET ");
                try writeSessionSettingName(writer, cmd.table);
                try writer.writeAll(" = '");
                try writeEscapedSqlString(writer, cmd.payload orelse "");
                try writer.writeByte('\'');
            },
            .session_show => {
                try writer.writeAll("SHOW ");
                try writeSessionSettingName(writer, cmd.table);
            },
            .session_reset => {
                try writer.writeAll("RESET ");
                try writeSessionSettingName(writer, cmd.table);
            },
            .create_database => {
                try writer.writeAll("CREATE DATABASE ");
                try writeIdentifierMaybeQuoted(writer, cmd.table);
            },
            .drop_database => {
                try writer.writeAll("DROP DATABASE IF EXISTS ");
                try writeIdentifierMaybeQuoted(writer, cmd.table);
            },
            .grant => {
                const role = cmd.payload orelse return error.MissingGrantRole;
                if (cmd.table.len == 0) return error.MissingGrantObject;
                if (cmd.privileges.len == 0) return error.MissingGrantPrivileges;

                try writer.writeAll("GRANT ");
                for (cmd.privileges, 0..) |privilege, i| {
                    const canonical = checkedPrivilege(privilege) orelse return error.InvalidGrantPrivilege;
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(canonical);
                }
                try writer.writeAll(" ON ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" TO ");
                try writeIdentifierMaybeQuoted(writer, role);
            },
            .revoke => {
                const role = cmd.payload orelse return error.MissingRevokeRole;
                if (cmd.table.len == 0) return error.MissingRevokeObject;
                if (cmd.privileges.len == 0) return error.MissingRevokePrivileges;

                try writer.writeAll("REVOKE ");
                for (cmd.privileges, 0..) |privilege, i| {
                    const canonical = checkedPrivilege(privilege) orelse return error.InvalidGrantPrivilege;
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(canonical);
                }
                try writer.writeAll(" ON ");
                try writeIdentifierOrError(writer, cmd.table);
                try writer.writeAll(" FROM ");
                try writeIdentifierMaybeQuoted(writer, role);
            },
            .create_policy => {
                const policy = cmd.policy_def orelse return error.MissingPolicyDefinition;
                if (policy.name.len == 0) return error.MissingPolicyName;
                if (policy.table.len == 0) return error.MissingPolicyTable;

                try writer.writeAll("CREATE POLICY ");
                try writeSingleIdentifierOrError(writer, policy.name);
                try writer.writeAll(" ON ");
                try writeIdentifierOrError(writer, policy.table);

                if (policy.permissiveness == .restrictive) {
                    try writer.writeAll(" AS RESTRICTIVE");
                }

                try writer.writeAll(" FOR ");
                try writer.writeAll(policy.target.toSql());

                if (policy.role) |role| {
                    try writer.writeAll(" TO ");
                    try writeSingleIdentifierOrError(writer, role);
                }

                if (policy.using_expr) |using_expr| {
                    try writer.writeAll(" USING (");
                    var expr = using_expr;
                    try writeExpr(writer, &expr, null);
                    try writer.writeByte(')');
                }

                if (policy.with_check_expr) |with_check_expr| {
                    try writer.writeAll(" WITH CHECK (");
                    var expr = with_check_expr;
                    try writeExpr(writer, &expr, null);
                    try writer.writeByte(')');
                }
            },
            .drop_policy => {
                const policy_name = if (cmd.policy_def) |policy|
                    policy.name
                else
                    cmd.payload orelse return error.MissingPolicyName;
                const policy_table = if (cmd.policy_def) |policy|
                    policy.table
                else if (cmd.table.len > 0)
                    cmd.table
                else
                    return error.MissingPolicyTable;

                if (policy_name.len == 0) return error.MissingPolicyName;
                if (policy_table.len == 0) return error.MissingPolicyTable;

                try writer.writeAll("DROP POLICY IF EXISTS ");
                try writeSingleIdentifierOrError(writer, policy_name);
                try writer.writeAll(" ON ");
                try writeIdentifierOrError(writer, policy_table);
            },
            // Raw SQL (for backwards compat - should be avoided!)
            .raw => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                }
            },
        }
    }
};

fn writeSelect(writer: anytype, cmd: *const QailCmd, count_only: bool) !void {
    try validateSelectShape(cmd);
    try writeCtePrefix(writer, cmd);

    try writer.writeAll("SELECT ");

    if (!count_only and cmd.distinct) {
        try writer.writeAll("DISTINCT ");
    }

    if (count_only) {
        try writer.writeAll("COUNT(*)");
    } else if (cmd.columns.len == 0) {
        try writer.writeAll("*");
    } else {
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col, cmd);
        }
    }

    if (cmd.only_table) {
        try writer.writeAll(" FROM ONLY ");
    } else {
        try writer.writeAll(" FROM ");
    }
    try writeTableReferenceOrError(writer, cmd.table);

    if (cmd.sample_method) |method| {
        try writer.print(" TABLESAMPLE {s}(", .{method.toSql()});
        if (cmd.sample_percent) |pct| {
            try writer.print("{d}", .{pct});
        }
        try writer.writeAll(")");
        if (cmd.sample_seed) |seed| {
            try writer.print(" REPEATABLE({d})", .{seed});
        }
    }

    if (cmd.table_alias) |alias| {
        try writer.writeAll(" AS ");
        try writeIdentifierOrError(writer, alias);
    }

    for (cmd.joins) |join| {
        try writer.print(" {s} ", .{join.kind.toSql()});
        try writeTableReferenceOrError(writer, join.table);
        if (join.alias) |alias| {
            try writer.writeAll(" AS ");
            try writeIdentifierOrError(writer, alias);
        }
        try writer.writeAll(" ON ");
        try writeColumnReference(writer, join.on_left, cmd);
        try writer.writeAll(" = ");
        try writeColumnReference(writer, join.on_right, cmd);
    }

    try writeWhereClauses(writer, cmd.where_clauses, cmd);

    if (cmd.group_by.len > 0) {
        try writer.writeAll(" GROUP BY ");
        for (cmd.group_by, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeColumnReference(writer, col, cmd);
        }
    }

    if (cmd.having_clauses.len > 0) {
        try writer.writeAll(" HAVING ");
        for (cmd.having_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writeCondition(writer, &clause.condition, cmd);
        }
    }

    if (cmd.order_by.len > 0) {
        try writer.writeAll(" ORDER BY ");
        for (cmd.order_by, 0..) |order, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeColumnReference(writer, order.column, cmd);
            try writer.print(" {s}", .{order.order.toSql()});
        }
    }

    if (cmd.limit_val) |limit| {
        try writer.print(" LIMIT {d}", .{limit});
    }

    if (cmd.offset_val) |offset| {
        try writer.print(" OFFSET {d}", .{offset});
    }

    try writeSetOps(writer, cmd);

    if (cmd.fetch_count) |count| {
        if (cmd.fetch_with_ties) {
            try writer.print(" FETCH FIRST {d} ROWS WITH TIES", .{count});
        } else {
            try writer.print(" FETCH FIRST {d} ROWS ONLY", .{count});
        }
    }

    if (cmd.lock_mode) |lock| {
        try writer.print(" {s}", .{lock.toSql()});
        if (cmd.skip_locked) try writer.writeAll(" SKIP LOCKED");
    }
}

fn writeNestedQueryableCmd(writer: anytype, cmd: *const QailCmd) anyerror!void {
    return switch (cmd.kind) {
        .get => writeSelect(writer, cmd, false),
        .with => writeSelect(writer, cmd, false),
        .cnt => writeSelect(writer, cmd, true),
        .search => writeSelect(writer, cmd, false),
        .over => writeSelect(writer, cmd, false),
        .raw => try writeCheckedSubquerySql(writer, cmd.raw_sql orelse return error.MissingNestedRawQuery),
        else => error.UnsupportedNestedQueryCommand,
    };
}

fn writeMerge(writer: anytype, cmd: *const QailCmd) !void {
    const merge = cmd.merge orelse return error.MissingMergeSpec;
    try validateMergeShape(&merge);

    try writeCtePrefix(writer, cmd);

    try writer.writeAll("MERGE INTO ");
    try writeTableReferenceOrError(writer, cmd.table);

    if (merge.target_alias) |alias| {
        try writer.writeAll(" AS ");
        try writeIdentifierOrError(writer, alias);
    }

    try writer.writeAll(" USING ");
    try writeMergeSource(writer, &merge.source);

    try writer.writeAll(" ON ");
    try writeConditions(writer, merge.on, cmd);

    for (merge.clauses) |clause| {
        try writer.writeAll(" WHEN ");
        switch (clause.match_kind) {
            .matched => try writer.writeAll("MATCHED"),
            .not_matched_by_target => try writer.writeAll("NOT MATCHED BY TARGET"),
            .not_matched_by_source => try writer.writeAll("NOT MATCHED BY SOURCE"),
        }

        if (clause.condition.len > 0) {
            try writer.writeAll(" AND ");
            try writeConditions(writer, clause.condition, cmd);
        }

        try writer.writeAll(" THEN ");
        try writeMergeAction(writer, &clause.action, cmd);
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col, cmd);
        }
    }
}

fn writeMergeSource(writer: anytype, source: *const ast.cmd.MergeSource) !void {
    switch (source.*) {
        .table => |table| {
            try writeTableReferenceOrError(writer, table.name);
            if (table.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierOrError(writer, alias);
            }
        },
        .query => |query| {
            try writer.writeByte('(');
            try writeNestedQueryableCmd(writer, query.query);
            try writer.writeByte(')');
            if (query.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierOrError(writer, alias);
            }
        },
    }
}

fn writeConditions(writer: anytype, conditions: []const ast.expr.Condition, cmd: ?*const QailCmd) !void {
    if (conditions.len == 0) return error.MissingMergeCondition;
    for (conditions, 0..) |*condition, i| {
        if (i > 0) try writer.writeAll(" AND ");
        try writeCondition(writer, condition, cmd);
    }
}

fn writeMergeAction(writer: anytype, action: *const ast.cmd.MergeAction, cmd: ?*const QailCmd) !void {
    switch (action.*) {
        .update => |assignments| {
            try writer.writeAll("UPDATE SET ");
            for (assignments, 0..) |assignment, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeIdentifierOrError(writer, assignment.column);
                try writer.writeAll(" = ");
                var expr = assignment.expr;
                try writeExpr(writer, &expr, cmd);
            }
        },
        .insert => |insert| {
            try writer.writeAll("INSERT");
            if (insert.columns.len > 0) {
                try writer.writeAll(" (");
                for (insert.columns, 0..) |column, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writeIdentifierOrError(writer, column);
                }
                try writer.writeByte(')');
            }
            try writer.writeAll(" VALUES (");
            for (insert.values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                var expr = value;
                try writeExpr(writer, &expr, cmd);
            }
            try writer.writeByte(')');
        },
        .delete => try writer.writeAll("DELETE"),
        .do_nothing => try writer.writeAll("DO NOTHING"),
    }
}

fn writeSetOps(writer: anytype, cmd: *const QailCmd) anyerror!void {
    for (cmd.set_ops) |set_op| {
        switch (set_op.op) {
            .@"union" => try writer.writeAll(" UNION "),
            .union_all => try writer.writeAll(" UNION ALL "),
            .intersect => try writer.writeAll(" INTERSECT "),
            .intersect_all => try writer.writeAll(" INTERSECT ALL "),
            .except => try writer.writeAll(" EXCEPT "),
            .except_all => try writer.writeAll(" EXCEPT ALL "),
        }

        if (set_op.query) |query| {
            try writeNestedQueryableCmd(writer, query);
        } else {
            return error.MissingSetOpQuery;
        }
    }
}

fn writeCtePrefix(writer: anytype, cmd: *const QailCmd) !void {
    if (cmd.ctes.len == 0) return;

    try writer.writeAll("WITH ");

    var has_recursive = false;
    for (cmd.ctes) |cte| {
        if (cte.recursive) {
            has_recursive = true;
            break;
        }
    }
    if (has_recursive) {
        try writer.writeAll("RECURSIVE ");
    }

    for (cmd.ctes, 0..) |cte, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeSingleIdentifierOrError(writer, cte.name);

        if (cte.columns.len > 0) {
            try writer.writeAll("(");
            for (cte.columns, 0..) |col, j| {
                if (j > 0) try writer.writeAll(", ");
                try writeSingleIdentifierOrError(writer, col);
            }
            try writer.writeAll(")");
        }

        try writer.writeAll(" AS (");
        if (cte.base_query) |query| {
            try writeNestedQueryableCmd(writer, query);
        } else {
            return error.MissingCteQuery;
        }

        if (cte.recursive and cte.recursive_query != null) {
            try writer.writeAll(" UNION ALL ");
            try writeNestedQueryableCmd(writer, cte.recursive_query.?);
        }

        try writer.writeAll(")");
    }

    try writer.writeAll(" ");
}

fn validateMergeShape(merge: *const ast.cmd.Merge) !void {
    if (merge.target_alias) |alias| {
        if (!isBareIdentifier(alias)) return error.InvalidMergeTargetAlias;
    }

    switch (merge.source) {
        .table => |table| {
            if (std.mem.trim(u8, table.name, " \t\r\n").len == 0) return error.MissingMergeSource;
            if (table.alias) |alias| {
                if (!isBareIdentifier(alias)) return error.InvalidMergeSourceAlias;
            }
        },
        .query => |query| {
            if (query.alias) |alias| {
                if (!isBareIdentifier(alias)) return error.InvalidMergeSourceAlias;
            }
            if (!isReadOnlyMergeSource(query.query)) return error.InvalidMergeSourceQuery;
        },
    }

    if (merge.on.len == 0) return error.MissingMergeCondition;
    if (merge.clauses.len == 0) return error.MissingMergeClause;

    for (merge.clauses) |clause| {
        switch (clause.action) {
            .insert => |insert| {
                if (clause.match_kind == .matched) return error.InvalidMergeActionShape;
                if (clause.match_kind == .not_matched_by_source) return error.InvalidMergeActionShape;
                if (insert.values.len == 0) return error.MissingMergeInsertValues;
                if (insert.columns.len > 0 and insert.columns.len != insert.values.len) return error.InvalidMergeInsertShape;
                try validateMergeWriteTargets(insert.columns);
            },
            .update => |assignments| {
                if (clause.match_kind == .not_matched_by_target) return error.InvalidMergeActionShape;
                if (assignments.len == 0) return error.MissingMergeUpdateAssignments;
                try validateMergeAssignments(assignments);
            },
            .delete => {
                if (clause.match_kind == .not_matched_by_target) return error.InvalidMergeActionShape;
            },
            .do_nothing => {},
        }
    }
}

fn validateMergeAssignments(assignments: []const ast.cmd.MergeAssignment) !void {
    for (assignments, 0..) |assignment, i| {
        if (!isBareIdentifier(assignment.column)) return error.InvalidMergeWriteTarget;
        for (assignments[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.column, assignment.column)) return error.DuplicateMergeWriteTarget;
        }
    }
}

fn validateMergeWriteTargets(columns: []const []const u8) !void {
    for (columns, 0..) |column, i| {
        if (!isBareIdentifier(column)) return error.InvalidMergeWriteTarget;
        for (columns[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev, column)) return error.DuplicateMergeWriteTarget;
        }
    }
}

fn isReadOnlyMergeSource(cmd: *const QailCmd) bool {
    switch (cmd.kind) {
        .get, .with, .cnt, .search, .over => {},
        else => return false,
    }

    for (cmd.ctes) |cte| {
        if (cte.base_query) |query| {
            if (!isReadOnlyMergeSource(query)) return false;
        }
        if (cte.recursive_query) |query| {
            if (!isReadOnlyMergeSource(query)) return false;
        }
    }
    for (cmd.set_ops) |set_op| {
        if (set_op.query) |query| {
            if (!isReadOnlyMergeSource(query)) return false;
        }
    }

    return true;
}

fn isBareIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    const first = value[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn firstColumnName(cmd: *const QailCmd) ?[]const u8 {
    if (cmd.columns.len == 0) return null;

    return switch (cmd.columns[0]) {
        .named => |name| name,
        .column_def => |def| def.name,
        .aliased => |a| a.name,
        else => null,
    };
}

fn columnNameAt(cmd: *const QailCmd, idx: usize) ?[]const u8 {
    if (idx >= cmd.columns.len) return null;
    return switch (cmd.columns[idx]) {
        .named => |name| name,
        .column_def => |def| def.name,
        .aliased => |a| a.name,
        else => null,
    };
}

fn validateSelectShape(cmd: *const QailCmd) !void {
    if (cmd.assignments.len != 0) return error.InvalidSelectShape;
    if (cmd.fetch_with_ties and cmd.order_by.len == 0) return error.FetchWithTiesRequiresOrderBy;
    if (cmd.skip_locked and cmd.lock_mode == null) return error.SkipLockedRequiresLockMode;

    if (cmd.sample_method != null and cmd.sample_percent == null) return error.MissingTableSamplePercent;
    if (cmd.sample_percent) |pct| {
        if (!std.math.isFinite(pct) or pct < 0 or pct > 100) return error.InvalidTableSamplePercent;
        if (cmd.sample_method == null) return error.MissingTableSampleMethod;
    }
}

fn validateInsertShape(cmd: *const QailCmd) !void {
    const has_values = cmd.insert_values.len != 0;
    const has_assignments = cmd.assignments.len != 0;
    const has_source = cmd.source_query != null;
    const has_raw_source = cmd.raw_sql != null;

    if (cmd.default_values) {
        if (cmd.columns.len != 0 or has_values or has_assignments or has_source or has_raw_source) {
            return error.InvalidInsertShape;
        }
        try validateOnConflictShape(cmd);
        return;
    }

    if (has_source and (has_raw_source or has_values or has_assignments)) return error.InvalidInsertShape;
    if (has_raw_source and (has_values or has_assignments)) return error.InvalidInsertShape;
    if (has_values and has_assignments) return error.InvalidInsertShape;
    if (!has_source and !has_raw_source and !has_values and !has_assignments) return error.MissingInsertValues;

    if (cmd.columns.len != 0) {
        try validateInsertTargetColumns(cmd.columns);
        const value_count = if (has_values) cmd.insert_values.len else if (has_assignments) cmd.assignments.len else 0;
        if (value_count != 0 and cmd.columns.len != value_count) return error.InvalidInsertShape;
    } else if (has_assignments) {
        try validateAssignmentTargets(cmd.assignments);
    }

    try validateOnConflictShape(cmd);
}

fn validateUpdateShape(cmd: *const QailCmd) !void {
    if (cmd.assignments.len == 0) return error.MissingUpdateAssignments;
    if (cmd.columns.len != 0) return error.InvalidUpdateShape;
    try validateAssignmentTargets(cmd.assignments);
}

fn validateOnConflictShape(cmd: *const QailCmd) !void {
    const conflict = cmd.on_conflict orelse return;

    try validateWriteTargetNames(conflict.columns);
    switch (conflict.action) {
        .do_nothing => {},
        .do_update => {
            if (conflict.columns.len == 0) return error.InvalidOnConflictShape;
            const updates = if (conflict.update_columns.len != 0) conflict.update_columns else cmd.assignments;
            if (updates.len == 0) return error.InvalidOnConflictShape;
            try validateAssignmentTargets(updates);
        },
    }
}

fn validateInsertTargetColumns(columns: []const Expr) !void {
    for (columns, 0..) |column, i| {
        const name = switch (column) {
            .named => |name| name,
            else => return error.InvalidInsertColumn,
        };
        if (!isBareIdentifier(name)) return error.InvalidInsertColumn;

        for (columns[0..i]) |prev| {
            const prev_name = switch (prev) {
                .named => |p| p,
                else => continue,
            };
            if (std.ascii.eqlIgnoreCase(prev_name, name)) return error.DuplicateWriteTarget;
        }
    }
}

fn validateAssignmentTargets(assignments: []const ast.cmd.Assignment) !void {
    for (assignments, 0..) |assignment, i| {
        if (!isBareIdentifier(assignment.column)) return error.InvalidWriteTarget;
        for (assignments[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.column, assignment.column)) return error.DuplicateWriteTarget;
        }
    }
}

fn validateWriteTargetNames(columns: []const []const u8) !void {
    for (columns, 0..) |column, i| {
        if (!isBareIdentifier(column)) return error.InvalidWriteTarget;
        for (columns[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev, column)) return error.DuplicateWriteTarget;
        }
    }
}

fn writeInsertCmd(writer: anytype, cmd: *const QailCmd, include_conflict: bool) !void {
    try validateInsertShape(cmd);

    try writer.writeAll("INSERT INTO ");
    try writeIdentifierOrError(writer, cmd.table);

    // Column list (skip for DEFAULT VALUES and INSERT .. SELECT without explicit target columns)
    if (!cmd.default_values and cmd.columns.len > 0) {
        try writer.writeAll(" (");
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeInsertTargetColumn(writer, &col);
        }
        try writer.writeByte(')');
    } else if (!cmd.default_values and cmd.columns.len == 0 and cmd.assignments.len > 0) {
        try writer.writeAll(" (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeIdentifierOrError(writer, assign.column);
        }
        try writer.writeByte(')');
    }

    if (cmd.overriding) |ovr| {
        try writer.print(" {s}", .{ovr.toSql()});
    }

    if (cmd.default_values) {
        try writer.writeAll(" DEFAULT VALUES");
    } else if (cmd.source_query) |source_query| {
        try writer.writeByte(' ');
        try writeNestedQueryableCmd(writer, source_query);
    } else if (cmd.raw_sql) |source_sql| {
        try writer.writeByte(' ');
        const checked_source = checkedReadOnlySubquerySql(source_sql) orelse "SELECT NULL WHERE FALSE";
        try writer.writeAll(checked_source);
    } else if (cmd.insert_values.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.insert_values, 0..) |val, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeValue(writer, &val, cmd);
        }
        try writer.writeByte(')');
    } else if (cmd.assignments.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeValue(writer, &assign.value, cmd);
        }
        try writer.writeByte(')');
    } else {
        return error.MissingInsertValues;
    }

    if (include_conflict or cmd.on_conflict != null) {
        if (cmd.on_conflict) |conflict| {
            try writer.writeAll(" ON CONFLICT");
            if (conflict.columns.len > 0) {
                try writer.writeAll(" (");
                for (conflict.columns, 0..) |col, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writeIdentifierOrError(writer, col);
                }
                try writer.writeByte(')');
            }

            switch (conflict.action) {
                .do_nothing => try writer.writeAll(" DO NOTHING"),
                .do_update => {
                    const updates = conflict.update_columns;
                    if (updates.len == 0 and cmd.assignments.len == 0) {
                        try writer.writeAll(" DO NOTHING");
                    } else if (updates.len == 0) {
                        try writer.writeAll(" DO UPDATE SET ");
                        for (cmd.assignments, 0..) |assign, i| {
                            if (i > 0) try writer.writeAll(", ");
                            try writeIdentifierOrError(writer, assign.column);
                            try writer.writeAll(" = EXCLUDED.");
                            try writeIdentifierOrError(writer, assign.column);
                        }
                    } else {
                        try writer.writeAll(" DO UPDATE SET ");
                        for (updates, 0..) |assign, i| {
                            if (i > 0) try writer.writeAll(", ");
                            try writeIdentifierOrError(writer, assign.column);
                            try writer.writeAll(" = ");
                            try writeValue(writer, &assign.value, cmd);
                        }
                    }
                },
            }
        } else {
            // PUT/UPSERT defaults to conflict-tolerant behavior when no clause is provided.
            try writer.writeAll(" ON CONFLICT DO NOTHING");
        }
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col, cmd);
        }
    }
}

fn writeWhereClauses(writer: anytype, clauses: []const ast.cmd.WhereClause, cmd: ?*const QailCmd) !void {
    var has_and = false;
    var has_or = false;

    for (clauses) |clause| {
        switch (clause.logical_op) {
            .@"and" => has_and = true,
            .@"or" => has_or = true,
        }
    }

    if (!has_and and !has_or) {
        return;
    }

    try writer.writeAll(" WHERE ");

    var wrote_clause = false;

    if (has_and) {
        for (clauses) |clause| {
            if (clause.logical_op != .@"and") continue;
            if (wrote_clause) {
                try writer.writeAll(" AND ");
            }
            try writeWhereCondition(writer, clause, cmd);
            wrote_clause = true;
        }
    }

    if (has_or) {
        if (wrote_clause) {
            try writer.writeAll(" AND ");
        }
        try writer.writeAll("(");
        var first = true;
        for (clauses) |clause| {
            if (clause.logical_op != .@"or") continue;
            if (!first) {
                try writer.writeAll(" OR ");
            }
            first = false;
            try writeWhereCondition(writer, clause, cmd);
        }
        try writer.writeAll(")");
    }
}

fn writeWhereCondition(writer: anytype, clause: ast.cmd.WhereClause, cmd: ?*const QailCmd) !void {
    try writeCondition(writer, &clause.condition, cmd);
}

fn writeCondition(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) anyerror!void {
    switch (condition.op) {
        .in, .not_in => return writeInCondition(writer, condition, cmd),
        .between, .not_between => return writeBetweenCondition(writer, condition, cmd),
        .exists, .not_exists => return error.InvalidExistsCondition,
        else => {},
    }

    try writeConditionLeft(writer, condition, cmd);

    switch (condition.op) {
        .is_null, .is_not_null => try writer.print(" {s}", .{condition.op.toSql()}),
        else => {
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &condition.value, cmd);
        },
    }
}

fn writeConditionLeft(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) anyerror!void {
    if (condition.column.len != 0) {
        try writeConditionColumnReference(writer, condition.column, cmd);
    } else {
        var left = condition.left;
        try writeExpr(writer, &left, cmd);
    }
}

fn writeConditionColumnReference(writer: anytype, column: []const u8, cmd: ?*const QailCmd) !void {
    const trimmed = std.mem.trim(u8, column, " \t\r\n");
    if (try writeConditionFunctionReference(writer, trimmed, cmd)) return;
    try writeColumnReference(writer, trimmed, cmd);
}

fn writeConditionFunctionReference(writer: anytype, value: []const u8, cmd: ?*const QailCmd) !bool {
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return false;
    if (!std.mem.endsWith(u8, value, ")")) return false;

    const name = std.mem.trim(u8, value[0..open], " \t\r\n");
    if (!isSafeFunctionName(name)) return false;
    const args = std.mem.trim(u8, value[open + 1 .. value.len - 1], " \t\r\n");
    if (std.mem.indexOfScalar(u8, args, '(') != null or std.mem.indexOfScalar(u8, args, ')') != null) {
        return false;
    }

    var validate_parts = std.mem.splitScalar(u8, args, ',');
    while (validate_parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (args.len != 0 and part.len == 0) return false;
    }

    try writer.writeAll(name);
    try writer.writeByte('(');
    if (args.len != 0) {
        var parts = std.mem.splitScalar(u8, args, ',');
        var first = true;
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\r\n");
            if (part.len == 0) return false;
            if (!first) try writer.writeAll(", ");
            first = false;
            try writeIdentifierOrStarWithContext(writer, part, cmd);
        }
    }
    try writer.writeByte(')');
    return true;
}

fn writeInCondition(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) !void {
    switch (condition.value) {
        .array => |values| {
            if (values.len == 0) return error.InvalidInCondition;

            try writeConditionLeft(writer, condition, cmd);
            try writer.print(" {s} (", .{condition.op.toSql()});
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(writer, &value, cmd);
            }
            try writer.writeByte(')');
        },
        .param, .named_param => {
            try writeConditionLeft(writer, condition, cmd);
            try writer.writeAll(if (condition.op == .in) " = ANY(" else " != ALL(");
            try writeValue(writer, &condition.value, cmd);
            try writer.writeByte(')');
        },
        else => return error.InvalidInCondition,
    }
}

fn writeBetweenCondition(writer: anytype, condition: *const ast.expr.Condition, cmd: ?*const QailCmd) !void {
    switch (condition.value) {
        .range => |range| {
            try writeConditionLeft(writer, condition, cmd);
            try writer.print(" {s} {d} AND {d}", .{ condition.op.toSql(), range.low, range.high });
        },
        .array => |values| {
            if (values.len != 2) return error.InvalidBetweenCondition;

            try writeConditionLeft(writer, condition, cmd);
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &values[0], cmd);
            try writer.writeAll(" AND ");
            try writeValue(writer, &values[1], cmd);
        },
        else => return error.InvalidBetweenCondition,
    }
}

fn writeEscapedSqlString(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        if (c == '\'') {
            try writer.writeAll("''");
        } else {
            try writer.writeByte(c);
        }
    }
}

fn writeEscapedSqlStringNoNul(writer: anytype, value: []const u8) !void {
    for (value) |c| {
        if (c == 0) continue;
        if (c == '\'') {
            try writer.writeAll("''");
        } else {
            try writer.writeByte(c);
        }
    }
}

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

fn isSafeSqlExprFragment(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len != 0 and !containsUnquotedStatementDelimiter(trimmed);
}

fn checkedSqlExprFragment(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or containsUnquotedStatementDelimiter(trimmed)) return null;
    return trimmed;
}

fn checkedReadOnlySubquerySql(value: []const u8) ?[]const u8 {
    const checked = checkedSqlExprFragment(value) orelse return null;
    if (!startsWithReadOnlySubqueryKeyword(checked)) return null;
    return checked;
}

fn startsWithReadOnlySubqueryKeyword(value: []const u8) bool {
    return startsWithSqlKeyword(value, "SELECT") or
        startsWithSqlKeyword(value, "VALUES") or
        startsWithSqlKeyword(value, "TABLE");
}

fn startsWithSqlKeyword(value: []const u8, keyword: []const u8) bool {
    if (!startsWithIgnoreCase(value, keyword)) return false;
    if (value.len == keyword.len) return true;
    const next = value[keyword.len];
    return std.ascii.isWhitespace(next) or next == '(';
}

fn writeCheckedRawExpression(writer: anytype, fragment: []const u8) !void {
    const checked = checkedSqlExprFragment(fragment) orelse {
        try writer.writeAll(INVALID_RAW_FRAGMENT);
        return;
    };
    try writer.writeAll(checked);
}

fn writeIndexMethodOrError(writer: anytype, method: []const u8) !void {
    const trimmed = std.mem.trim(u8, method, " \t\r\n");
    if (!isAllowedIndexMethod(trimmed)) {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    }
    try writer.writeAll(trimmed);
}

fn isAllowedIndexMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "btree") or
        std.ascii.eqlIgnoreCase(method, "hash") or
        std.ascii.eqlIgnoreCase(method, "gin") or
        std.ascii.eqlIgnoreCase(method, "gist") or
        std.ascii.eqlIgnoreCase(method, "brin") or
        std.ascii.eqlIgnoreCase(method, "spgist") or
        std.ascii.eqlIgnoreCase(method, "hnsw") or
        std.ascii.eqlIgnoreCase(method, "ivfflat");
}

fn writeIndexElementOrError(writer: anytype, element: []const u8) !void {
    const trimmed = std.mem.trim(u8, element, " \t\r\n");
    if (trimmed.len == 0 or
        containsUnquotedStatementDelimiter(trimmed) or
        std.mem.indexOfScalar(u8, trimmed, '(') != null or
        std.mem.indexOfScalar(u8, trimmed, ')') != null or
        std.mem.indexOfScalar(u8, trimmed, '\'') != null or
        std.mem.indexOfScalar(u8, trimmed, '"') != null)
    {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    }

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const column = tokens.next() orelse {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    };
    if (!isValidQualifiedIdentifier(column)) {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    }

    try writeIdentifierOrError(writer, column);
    while (tokens.next()) |token| {
        if (!isAllowedIndexModifier(token)) {
            try writer.writeAll(" ");
            try writer.writeAll(INVALID_IDENTIFIER);
            return;
        }
        try writer.writeByte(' ');
        try writer.writeAll(token);
    }
}

fn isAllowedIndexModifier(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "asc") or
        std.ascii.eqlIgnoreCase(token, "desc") or
        std.ascii.eqlIgnoreCase(token, "nulls") or
        std.ascii.eqlIgnoreCase(token, "first") or
        std.ascii.eqlIgnoreCase(token, "last") or
        isAllowedIndexOpclass(token);
}

fn isAllowedIndexOpclass(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '_') == null) return false;
    if (token.len == 0 or !std.ascii.isAlphabetic(token[0])) return false;
    for (token[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn writeCheckedSubquerySql(writer: anytype, sql: []const u8) !void {
    const checked = checkedReadOnlySubquerySql(sql) orelse "SELECT NULL WHERE FALSE";
    try writer.writeAll(checked);
}

fn writeIdentifierMaybeQuoted(writer: anytype, ident: []const u8) !void {
    const needs_quotes = blk: {
        if (ident.len == 0) break :blk true;
        if (std.ascii.isDigit(ident[0])) break :blk true;
        for (ident) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk true;
        }
        break :blk false;
    };

    if (!needs_quotes) {
        try writer.writeAll(ident);
        return;
    }

    try writer.writeByte('"');
    for (ident) |c| {
        if (c == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('"');
}

fn isSafeFunctionName(name: []const u8) bool {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return false;

    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }

    return true;
}

fn isSafeRawFunctionValue(value: []const u8) bool {
    return value.len <= MAX_RAW_FUNCTION_VALUE_LEN and
        std.mem.indexOfScalar(u8, value, 0) == null and
        std.mem.indexOfScalar(u8, value, ';') == null and
        std.mem.indexOf(u8, value, "--") == null and
        std.mem.indexOf(u8, value, "/*") == null and
        std.mem.indexOf(u8, value, "*/") == null;
}

fn isSafeSqlKeyword(keyword: []const u8) bool {
    if (keyword.len == 0 or std.mem.indexOfScalar(u8, keyword, 0) != null) return false;
    for (keyword) |c| {
        if (!std.ascii.isAlphabetic(c) and c != '_') return false;
    }
    return true;
}

fn checkedSqlTypeFragment(fragment: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, fragment, " \t\r\n");
    if (trimmed.len == 0 or
        std.mem.indexOfScalar(u8, trimmed, 0) != null or
        std.mem.indexOfScalar(u8, trimmed, ';') != null or
        std.mem.indexOfScalar(u8, trimmed, '\'') != null or
        std.mem.indexOfScalar(u8, trimmed, '"') != null or
        std.mem.indexOf(u8, trimmed, "--") != null or
        std.mem.indexOf(u8, trimmed, "/*") != null or
        std.mem.indexOf(u8, trimmed, "*/") != null)
    {
        return null;
    }

    for (trimmed) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == '_' or c == '.' or c == ' ' or c == '(' or c == ')' or
            c == ',' or c == '[' or c == ']' or c == '%' or c == '+' or c == '-';
        if (!ok) return null;
    }
    return trimmed;
}

fn checkedEnumValuesFragment(fragment: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, fragment, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return null;

    var i: usize = 0;
    var saw_value = false;
    while (i < trimmed.len) {
        while (i < trimmed.len and std.ascii.isWhitespace(trimmed[i])) : (i += 1) {}
        if (i >= trimmed.len or trimmed[i] != '\'') return null;
        i += 1;

        while (i < trimmed.len) {
            const c = trimmed[i];
            if (c == 0) return null;
            if (c == '\'') {
                if (i + 1 < trimmed.len and trimmed[i + 1] == '\'') {
                    i += 2;
                    continue;
                }
                i += 1;
                break;
            }
            i += 1;
        } else return null;

        saw_value = true;
        while (i < trimmed.len and std.ascii.isWhitespace(trimmed[i])) : (i += 1) {}
        if (i == trimmed.len) break;
        if (trimmed[i] != ',') return null;
        i += 1;
    }

    return if (saw_value) trimmed else null;
}

fn checkedTableLockMode(mode: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, mode, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "ACCESS SHARE") or
        std.ascii.eqlIgnoreCase(trimmed, "ACCESS SHARE MODE"))
        return ast.operators.TableLockMode.access_share.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "ROW SHARE") or
        std.ascii.eqlIgnoreCase(trimmed, "ROW SHARE MODE"))
        return ast.operators.TableLockMode.row_share.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "ROW EXCLUSIVE") or
        std.ascii.eqlIgnoreCase(trimmed, "ROW EXCLUSIVE MODE"))
        return ast.operators.TableLockMode.row_exclusive.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "SHARE UPDATE EXCLUSIVE") or
        std.ascii.eqlIgnoreCase(trimmed, "SHARE UPDATE EXCLUSIVE MODE"))
        return ast.operators.TableLockMode.share_update_exclusive.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "SHARE") or
        std.ascii.eqlIgnoreCase(trimmed, "SHARE MODE"))
        return ast.operators.TableLockMode.share.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "SHARE ROW EXCLUSIVE") or
        std.ascii.eqlIgnoreCase(trimmed, "SHARE ROW EXCLUSIVE MODE"))
        return ast.operators.TableLockMode.share_row_exclusive.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "EXCLUSIVE") or
        std.ascii.eqlIgnoreCase(trimmed, "EXCLUSIVE MODE"))
        return ast.operators.TableLockMode.exclusive.toSql();
    if (std.ascii.eqlIgnoreCase(trimmed, "ACCESS EXCLUSIVE") or
        std.ascii.eqlIgnoreCase(trimmed, "ACCESS EXCLUSIVE MODE"))
        return ast.operators.TableLockMode.access_exclusive.toSql();
    return null;
}

fn checkedPrivilege(privilege: []const u8) ?[]const u8 {
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

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn isExplicitCommentTarget(trimmed: []const u8) bool {
    return startsWithIgnoreCase(trimmed, "TABLE ") or
        startsWithIgnoreCase(trimmed, "COLUMN ") or
        startsWithIgnoreCase(trimmed, "FUNCTION ") or
        startsWithIgnoreCase(trimmed, "TYPE ") or
        startsWithIgnoreCase(trimmed, "POLICY ") or
        startsWithIgnoreCase(trimmed, "CONSTRAINT ") or
        startsWithIgnoreCase(trimmed, "INDEX ") or
        startsWithIgnoreCase(trimmed, "SEQUENCE ") or
        startsWithIgnoreCase(trimmed, "VIEW ") or
        startsWithIgnoreCase(trimmed, "MATERIALIZED VIEW ") or
        startsWithIgnoreCase(trimmed, "SCHEMA ");
}

fn writeQuotedIdentifierSkippingNul(writer: anytype, ident: []const u8) !void {
    try writer.writeByte('"');
    for (ident) |c| {
        if (c == 0) continue;
        if (c == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('"');
}

fn writeCommentTarget(writer: anytype, target: []const u8) !void {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (isExplicitCommentTarget(trimmed)) {
        if (containsUnquotedStatementDelimiter(trimmed)) {
            try writer.writeAll("TABLE ");
            try writeQuotedIdentifierSkippingNul(writer, trimmed);
        } else {
            try writer.writeAll(trimmed);
        }
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot| {
        try writer.writeAll("COLUMN ");
        try writeIdentifierOrError(writer, trimmed[0..dot]);
        try writer.writeByte('.');
        try writeIdentifierOrError(writer, trimmed[dot + 1 ..]);
    } else {
        try writer.writeAll("TABLE ");
        try writeIdentifierOrError(writer, trimmed);
    }
}

fn trimTrailingSemicolon(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r\n");
    while (std.mem.endsWith(u8, trimmed, ";")) {
        trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    }
    return trimmed;
}

fn containsRawDelimiter(value: []const u8) bool {
    return value.len == 0 or
        std.mem.indexOfScalar(u8, value, 0) != null or
        std.mem.indexOfScalar(u8, value, ';') != null or
        std.mem.indexOf(u8, value, "--") != null or
        std.mem.indexOf(u8, value, "/*") != null or
        std.mem.indexOf(u8, value, "*/") != null;
}

fn writeCallTarget(writer: anytype, target: []const u8) !void {
    const trimmed = trimTrailingSemicolon(target);
    if (containsRawDelimiter(trimmed)) {
        try writeIdentifierOrError(writer, trimmed);
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '(')) |open| {
        const name = std.mem.trim(u8, trimmed[0..open], " \t\r\n");
        const args = trimmed[open + 1 ..];
        if (std.mem.endsWith(u8, args, ")") and std.mem.indexOfScalar(u8, args[0 .. args.len - 1], '(') == null) {
            try writeIdentifierOrError(writer, name);
            try writer.writeByte('(');
            try writer.writeAll(args[0 .. args.len - 1]);
            try writer.writeByte(')');
            return;
        }
        try writeIdentifierOrError(writer, trimmed);
        return;
    }

    try writeIdentifierOrError(writer, trimmed);
}

fn functionArgsAreSafe(args: []const u8) bool {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (std.mem.indexOfScalar(u8, args, 0) != null or
        std.mem.indexOfScalar(u8, args, ';') != null or
        std.mem.indexOfScalar(u8, args, '\n') != null or
        std.mem.indexOfScalar(u8, args, '\r') != null or
        std.mem.indexOf(u8, args, "--") != null or
        std.mem.indexOf(u8, args, "/*") != null or
        std.mem.indexOf(u8, args, "*/") != null)
    {
        return false;
    }

    var start: usize = 0;
    var depth: usize = 0;
    var bracket_depth: usize = 0;
    for (args, 0..) |ch, idx| {
        switch (ch) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth == 0) return false;
                bracket_depth -= 1;
            },
            ',' => if (depth == 0) {
                const part = std.mem.trim(u8, args[start..idx], " \t\r\n");
                if (part.len == 0 or checkedSqlTypeFragment(part) == null) return false;
                start = idx + 1;
            },
            else => {},
        }
    }
    if (depth != 0 or bracket_depth != 0) return false;

    const tail = std.mem.trim(u8, args[start..], " \t\r\n");
    return tail.len != 0 and checkedSqlTypeFragment(tail) != null;
}

const HeaderKeywordMatch = struct {
    start: usize = 0,
    end: usize = 0,
    count: usize = 0,
};

fn findHeaderKeyword(header: []const u8, keyword: []const u8) ?HeaderKeywordMatch {
    var result = HeaderKeywordMatch{};
    var depth: usize = 0;
    var idx: usize = 0;

    while (idx < header.len) {
        while (idx < header.len and std.ascii.isWhitespace(header[idx])) : (idx += 1) {}
        if (idx >= header.len) break;

        const start = idx;
        const token_depth = depth;
        while (idx < header.len and !std.ascii.isWhitespace(header[idx])) : (idx += 1) {
            switch (header[idx]) {
                '(' => depth += 1,
                ')' => {
                    if (depth == 0) return null;
                    depth -= 1;
                },
                else => {},
            }
        }

        if (token_depth == 0 and std.ascii.eqlIgnoreCase(header[start..idx], keyword)) {
            if (result.count == 0) {
                result.start = start;
                result.end = idx;
            }
            result.count += 1;
        }
    }

    if (depth != 0) return null;
    return result;
}

fn readHeaderToken(header: []const u8, start_idx: usize) ?struct { token: []const u8, end: usize } {
    var idx = start_idx;
    while (idx < header.len and std.ascii.isWhitespace(header[idx])) : (idx += 1) {}
    if (idx >= header.len) return null;
    const start = idx;
    while (idx < header.len and !std.ascii.isWhitespace(header[idx])) : (idx += 1) {}
    return .{ .token = header[start..idx], .end = idx };
}

fn isSafeNativeIdentifier(value: []const u8) bool {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn isVolatilityKeyword(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "IMMUTABLE") or
        std.ascii.eqlIgnoreCase(value, "STABLE") or
        std.ascii.eqlIgnoreCase(value, "VOLATILE");
}

fn functionHeaderIsSafe(header: []const u8) bool {
    const trimmed = std.mem.trim(u8, header, " \t\r\n");
    if (containsRawDelimiter(trimmed)) return false;

    const returns = findHeaderKeyword(trimmed, "RETURNS") orelse return false;
    const language = findHeaderKeyword(trimmed, "LANGUAGE") orelse return false;
    if (returns.count != 1 or language.count != 1) return false;
    if (returns.start != 0 or returns.end >= language.start) return false;

    const returns_type = std.mem.trim(u8, trimmed[returns.end..language.start], " \t\r\n");
    if (checkedSqlTypeFragment(returns_type) == null) return false;

    const language_token = readHeaderToken(trimmed, language.end) orelse return false;
    if (!isSafeNativeIdentifier(language_token.token)) return false;

    const rest = std.mem.trim(u8, trimmed[language_token.end..], " \t\r\n");
    if (rest.len == 0) return true;
    const volatility = readHeaderToken(rest, 0) orelse return false;
    if (!isVolatilityKeyword(volatility.token)) return false;
    return std.mem.trim(u8, rest[volatility.end..], " \t\r\n").len == 0;
}

fn findMatchingFunctionArgParen(value: []const u8) ?usize {
    if (value.len == 0 or value[0] != '(') return null;
    var depth: usize = 1;
    var idx: usize = 1;
    while (idx < value.len) : (idx += 1) {
        switch (value[idx]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }
    return null;
}

fn isDollarQuotedBlock(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 4 or trimmed[0] != '$') return false;
    const close_tag_rel = std.mem.indexOfScalar(u8, trimmed[1..], '$') orelse return false;
    const delimiter = trimmed[0 .. close_tag_rel + 2];
    for (delimiter[1 .. delimiter.len - 1]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }

    const after_open = trimmed[delimiter.len..];
    const close_rel = std.mem.lastIndexOf(u8, after_open, delimiter) orelse return false;
    const tail = std.mem.trim(u8, after_open[close_rel + delimiter.len ..], " \t\r\n");
    return tail.len == 0;
}

fn findDollarQuoteStart(value: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < value.len) : (idx += 1) {
        if (value[idx] != '$') continue;
        const close_tag_rel = std.mem.indexOfScalar(u8, value[idx + 1 ..], '$') orelse continue;
        const delimiter = value[idx .. idx + close_tag_rel + 2];
        var valid = true;
        for (delimiter[1 .. delimiter.len - 1]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
                valid = false;
                break;
            }
        }
        if (valid) return idx;
    }
    return null;
}

fn checkedFunctionDefinitionPayload(payload: []const u8) ?[]const u8 {
    const trimmed = trimTrailingSemicolon(payload);
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return null;
    if (trimmed[0] != '(') return null;

    const close_args = findMatchingFunctionArgParen(trimmed) orelse return null;
    const args = trimmed[1..close_args];
    if (!functionArgsAreSafe(args)) return null;

    const after_args = std.mem.trim(u8, trimmed[close_args + 1 ..], " \t\r\n");
    const dollar_start = findDollarQuoteStart(after_args) orelse return null;
    const header_and_as = std.mem.trim(u8, after_args[0..dollar_start], " \t\r\n");
    const as_match = findHeaderKeyword(header_and_as, "AS") orelse return null;
    if (as_match.count != 1) return null;

    const header = header_and_as[0..as_match.start];
    if (!functionHeaderIsSafe(header)) return null;

    const body = after_args[dollar_start..];
    if (!isDollarQuotedBlock(body)) return null;
    return trimmed;
}

const TokenCursor = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *TokenCursor) ?[]const u8 {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) : (self.pos += 1) {}
        if (self.pos >= self.input.len) return null;
        const start = self.pos;
        while (self.pos < self.input.len and !std.ascii.isWhitespace(self.input[self.pos])) : (self.pos += 1) {}
        return self.input[start..self.pos];
    }

    fn peek(self: *TokenCursor) ?[]const u8 {
        const saved = self.pos;
        defer self.pos = saved;
        return self.next();
    }

    fn done(self: *TokenCursor) bool {
        return self.peek() == null;
    }
};

const TriggerEventSeen = enum {
    insert,
    update,
    delete,
    truncate,
};

fn triggerEventFromToken(token: []const u8) ?TriggerEventSeen {
    if (std.ascii.eqlIgnoreCase(token, "INSERT")) return .insert;
    if (std.ascii.eqlIgnoreCase(token, "UPDATE")) return .update;
    if (std.ascii.eqlIgnoreCase(token, "DELETE")) return .delete;
    if (std.ascii.eqlIgnoreCase(token, "TRUNCATE")) return .truncate;
    return null;
}

fn markTriggerEvent(seen: *[4]bool, event: TriggerEventSeen) bool {
    const idx: usize = switch (event) {
        .insert => 0,
        .update => 1,
        .delete => 2,
        .truncate => 3,
    };
    if (seen[idx]) return false;
    seen[idx] = true;
    return true;
}

fn anyTriggerEvent(seen: *const [4]bool) bool {
    return seen[0] or seen[1] or seen[2] or seen[3];
}

fn isSafeNativeTableRef(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '.');
    var saw_part = false;
    while (parts.next()) |part| {
        if (!isSafeNativeIdentifier(part)) return false;
        saw_part = true;
    }
    return saw_part;
}

fn trimCommaToken(token: []const u8) []const u8 {
    return std.mem.trim(u8, token, ",");
}

fn parseTriggerUpdateColumns(cursor: *TokenCursor) bool {
    var saw_column = false;
    while (cursor.peek()) |raw| {
        if (std.ascii.eqlIgnoreCase(raw, "OR") or
            std.ascii.eqlIgnoreCase(raw, "ON") or
            triggerEventFromToken(raw) != null)
        {
            break;
        }

        _ = cursor.next();
        var columns = std.mem.splitScalar(u8, raw, ',');
        while (columns.next()) |column_raw| {
            const column = trimCommaToken(column_raw);
            if (column.len == 0) continue;
            if (!isSafeNativeIdentifier(column)) return false;
            saw_column = true;
        }
    }
    return saw_column;
}

fn triggerFunctionTargetIsSafe(target: []const u8) bool {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '(')) |open| {
        if (!std.mem.endsWith(u8, trimmed, ")")) return false;
        const name = std.mem.trim(u8, trimmed[0..open], " \t\r\n");
        const args = trimmed[open + 1 .. trimmed.len - 1];
        return isSafeNativeTableRef(name) and (std.mem.trim(u8, args, " \t\r\n").len == 0 or functionArgsAreSafe(args));
    }
    return isSafeNativeTableRef(trimmed);
}

fn checkedTriggerDefinitionPayload(payload: []const u8) ?[]const u8 {
    const trimmed = trimTrailingSemicolon(payload);
    if (containsRawDelimiter(trimmed)) return null;
    var cursor = TokenCursor{ .input = trimmed };

    const timing = cursor.next() orelse return null;
    if (std.ascii.eqlIgnoreCase(timing, "INSTEAD")) {
        const of = cursor.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(of, "OF")) return null;
    } else if (!std.ascii.eqlIgnoreCase(timing, "BEFORE") and !std.ascii.eqlIgnoreCase(timing, "AFTER")) {
        return null;
    }

    var seen_events = [_]bool{ false, false, false, false };
    while (cursor.peek()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "ON")) break;
        _ = cursor.next();
        if (std.ascii.eqlIgnoreCase(token, "OR")) continue;
        const event = triggerEventFromToken(token) orelse return null;
        if (!markTriggerEvent(&seen_events, event)) return null;
        if (event == .update and cursor.peek() != null and std.ascii.eqlIgnoreCase(cursor.peek().?, "OF")) {
            _ = cursor.next();
            if (!parseTriggerUpdateColumns(&cursor)) return null;
        }
    }
    if (!anyTriggerEvent(&seen_events)) return null;

    const on = cursor.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(on, "ON")) return null;
    const table = cursor.next() orelse return null;
    if (!isSafeNativeTableRef(table)) return null;

    if (cursor.peek()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "FOR")) {
            _ = cursor.next();
            const each = cursor.next() orelse return null;
            if (!std.ascii.eqlIgnoreCase(each, "EACH")) return null;
            const granularity = cursor.next() orelse return null;
            if (!std.ascii.eqlIgnoreCase(granularity, "ROW") and !std.ascii.eqlIgnoreCase(granularity, "STATEMENT")) return null;
        }
    }

    const execute = cursor.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(execute, "EXECUTE")) return null;
    const function_kw = cursor.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(function_kw, "FUNCTION") and !std.ascii.eqlIgnoreCase(function_kw, "PROCEDURE")) return null;
    const target = cursor.next() orelse return null;
    if (!triggerFunctionTargetIsSafe(target)) return null;
    if (!cursor.done()) return null;

    return trimmed;
}

fn writeFunctionArgs(writer: anytype, args: []const u8) !void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return;

    var start: usize = 0;
    var depth: usize = 0;
    var first = true;
    for (args, 0..) |ch, idx| {
        switch (ch) {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' => if (depth == 0) {
                const part = checkedSqlTypeFragment(args[start..idx]).?;
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.writeAll(part);
                start = idx + 1;
            },
            else => {},
        }
    }

    const tail = checkedSqlTypeFragment(args[start..]).?;
    if (!first) try writer.writeAll(", ");
    try writer.writeAll(tail);
}

fn writeFunctionSignature(writer: anytype, signature: []const u8) !void {
    const trimmed = trimTrailingSemicolon(signature);
    if (containsRawDelimiter(trimmed)) {
        try writeIdentifierOrError(writer, trimmed);
        return;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '(')) |open| {
        if (!std.mem.endsWith(u8, trimmed, ")")) {
            try writeIdentifierOrError(writer, trimmed);
            return;
        }
        const name = std.mem.trim(u8, trimmed[0..open], " \t\r\n");
        const args = trimmed[open + 1 .. trimmed.len - 1];
        if (!functionArgsAreSafe(args)) {
            try writeIdentifierOrError(writer, trimmed);
            return;
        }
        try writeIdentifierOrError(writer, name);
        try writer.writeByte('(');
        try writeFunctionArgs(writer, args);
        try writer.writeByte(')');
        return;
    }

    try writeIdentifierOrError(writer, trimmed);
}

fn isValidSessionSettingName(name: []const u8) bool {
    if (name.len == 0) return false;
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        const first = part[0];
        if (!std.ascii.isAlphabetic(first) and first != '_') return false;
        for (part[1..]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
    }
    return true;
}

fn writeSessionSettingName(writer: anytype, name: []const u8) !void {
    if (isValidSessionSettingName(name)) {
        try writer.writeAll(name);
    } else {
        try writeIdentifierOrError(writer, name);
    }
}

fn writeDollarQuotedBlock(writer: anytype, body: []const u8) !void {
    var delimiter_buf: [64]u8 = undefined;
    var idx: usize = 0;
    while (idx <= body.len) : (idx += 1) {
        const delimiter = if (idx == 0)
            "$$"
        else
            try std.fmt.bufPrint(&delimiter_buf, "$qail_body_{d}$", .{idx});
        if (std.mem.indexOf(u8, body, delimiter) == null) {
            try writer.writeAll(delimiter);
            try writer.writeByte(' ');
            for (body) |ch| {
                if (ch != 0) try writer.writeByte(ch);
            }
            try writer.writeByte(' ');
            try writer.writeAll(delimiter);
            return;
        }
    }

    try writer.writeByte('\'');
    try writeEscapedSqlStringNoNul(writer, body);
    try writer.writeByte('\'');
}

fn isValidQualifiedIdentifier(value: []const u8) bool {
    return value.len != 0 and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !std.mem.startsWith(u8, value, ".") and
        !std.mem.endsWith(u8, value, ".") and
        std.mem.indexOf(u8, value, "..") == null;
}

fn writeIdentifierOrError(writer: anytype, value: []const u8) !void {
    if (!isValidQualifiedIdentifier(value)) {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    }

    var parts = std.mem.splitScalar(u8, value, '.');
    var first = true;
    while (parts.next()) |part| {
        if (!first) try writer.writeByte('.');
        first = false;
        try writeIdentifierMaybeQuoted(writer, part);
    }
}

fn writeSingleIdentifierOrError(writer: anytype, value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) {
        try writer.writeAll(INVALID_IDENTIFIER);
        return;
    }
    try writeIdentifierMaybeQuoted(writer, value);
}

fn writeRequiredSingleIdentifier(writer: anytype, value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidIdentifier;
    }
    try writeIdentifierMaybeQuoted(writer, value);
}

fn writeInsertTargetColumn(writer: anytype, expr: *const Expr) !void {
    switch (expr.*) {
        .named => |name| try writeIdentifierOrError(writer, name),
        else => try writer.writeAll(INVALID_INSERT_COLUMN),
    }
}

fn writeIdentifierOrStar(writer: anytype, value: []const u8) !void {
    if (std.mem.eql(u8, value, "*")) {
        try writer.writeByte('*');
    } else {
        try writeIdentifierOrError(writer, value);
    }
}

const TableReference = struct {
    table: []const u8,
    alias: ?[]const u8 = null,
    explicit_as: bool = false,
};

const ColumnResolution = struct {
    qualifier: []const u8,
    tail: []const u8,
};

fn splitTableReference(value: []const u8) ?TableReference {
    var parts = std.mem.tokenizeAny(u8, value, " \t\r\n");
    const table = parts.next() orelse return null;
    const second = parts.next();
    const third = parts.next();
    if (parts.next() != null) return null;

    if (second == null) {
        return .{ .table = table };
    }

    if (third == null) {
        if (std.ascii.eqlIgnoreCase(second.?, "as")) return null;
        return .{ .table = table, .alias = second.? };
    }

    if (!std.ascii.eqlIgnoreCase(second.?, "as")) return null;
    return .{ .table = table, .alias = third.?, .explicit_as = true };
}

fn firstPart(value: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, value, '.')) |dot| {
        if (dot == 0 or dot + 1 >= value.len) return null;
        return value[0..dot];
    }
    return value;
}

fn tailAfterFirstPart(value: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse return null;
    if (dot == 0 or dot + 1 >= value.len) return null;
    return value[dot + 1 ..];
}

fn lastPart(value: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, value, '.')) |dot| {
        return value[dot + 1 ..];
    }
    return value;
}

fn identEq(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, left, "\""),
        std.mem.trim(u8, right, "\""),
    );
}

fn resolveAgainstTableReference(value: []const u8, table_value: []const u8, explicit_alias: ?[]const u8) ?ColumnResolution {
    const parsed = splitTableReference(table_value) orelse TableReference{ .table = table_value };
    const alias = explicit_alias orelse parsed.alias;
    const alias_name = alias orelse return null;
    const first = firstPart(value) orelse return null;

    if (identEq(first, alias_name)) {
        return .{ .qualifier = alias_name, .tail = tailAfterFirstPart(value) orelse "" };
    }

    if (value.len > parsed.table.len and
        value[parsed.table.len] == '.' and
        std.ascii.eqlIgnoreCase(value[0..parsed.table.len], parsed.table))
    {
        return .{ .qualifier = alias_name, .tail = value[parsed.table.len + 1 ..] };
    }

    if (identEq(first, lastPart(parsed.table))) {
        return .{ .qualifier = alias_name, .tail = tailAfterFirstPart(value) orelse "" };
    }

    return null;
}

fn resolveKnownColumnReference(value: []const u8, cmd: ?*const QailCmd) ?ColumnResolution {
    const current = cmd orelse return null;
    const first = firstPart(value) orelse return null;

    if (current.table.len > 0) {
        if (resolveAgainstTableReference(value, current.table, current.table_alias)) |resolved| {
            return resolved;
        }
    }

    if (current.merge) |merge| {
        if (merge.target_alias) |alias| {
            if (resolveAgainstTableReference(value, current.table, alias)) |resolved| {
                return resolved;
            }
        }

        switch (merge.source) {
            .table => |table| {
                if (resolveAgainstTableReference(value, table.name, table.alias)) |resolved| {
                    return resolved;
                }
            },
            .query => |query| {
                if (query.alias) |alias| {
                    if (identEq(first, alias)) {
                        return .{ .qualifier = alias, .tail = tailAfterFirstPart(value) orelse "" };
                    }
                }
            },
        }
    }

    for (current.joins) |join| {
        if (resolveAgainstTableReference(value, join.table, join.alias)) |resolved| {
            return resolved;
        }
    }

    for (current.from_tables) |table| {
        if (resolveAgainstTableReference(value, table, null)) |resolved| {
            return resolved;
        }
    }

    for (current.using_tables) |table| {
        if (resolveAgainstTableReference(value, table, null)) |resolved| {
            return resolved;
        }
    }

    return null;
}

fn writeTableReferenceOrError(writer: anytype, value: []const u8) !void {
    const ref = splitTableReference(value) orelse {
        try writeIdentifierOrError(writer, value);
        return;
    };

    try writeIdentifierOrError(writer, ref.table);
    if (ref.alias) |alias| {
        if (ref.explicit_as) {
            try writer.writeAll(" AS ");
        } else {
            try writer.writeByte(' ');
        }
        try writeIdentifierOrError(writer, alias);
    }
}

fn writeColumnReference(writer: anytype, value: []const u8, cmd: ?*const QailCmd) !void {
    if (resolveKnownColumnReference(value, cmd)) |resolved| {
        try writeIdentifierOrError(writer, resolved.qualifier);
        if (resolved.tail.len > 0) {
            try writer.writeByte('.');
            try writeIdentifierOrError(writer, resolved.tail);
        }
        return;
    }

    try writeIdentifierOrError(writer, value);
}

fn writeIdentifierOrStarWithContext(writer: anytype, value: []const u8, cmd: ?*const QailCmd) !void {
    if (std.mem.eql(u8, value, "*")) {
        try writer.writeByte('*');
    } else {
        try writeColumnReference(writer, value, cmd);
    }
}

fn writeExpr(writer: anytype, expr: *const Expr, cmd: ?*const QailCmd) anyerror!void {
    switch (expr.*) {
        .star => try writer.writeAll("*"),
        .named => |name| try writeColumnReference(writer, name, cmd),
        .aliased => |a| {
            try writeColumnReference(writer, a.name, cmd);
            try writer.writeAll(" AS ");
            try writeIdentifierMaybeQuoted(writer, a.alias);
        },
        .aggregate => |agg| {
            try writer.writeAll(agg.func.toSql());
            try writer.writeAll("(");
            if (agg.distinct) try writer.writeAll("DISTINCT ");
            try writeIdentifierOrStarWithContext(writer, agg.column, cmd);
            try writer.writeAll(")");
            if (agg.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .literal => |val| try writeValue(writer, &val, cmd),
        .binary => |b| {
            try writeExpr(writer, b.left, cmd);
            switch (b.op) {
                .is_null, .is_not_null => try writer.print(" {s}", .{b.op.toSql()}),
                else => {
                    try writer.print(" {s} ", .{b.op.toSql()});
                    try writeExpr(writer, b.right, cmd);
                },
            }
            if (b.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .func_call => |fc| {
            if (!isSafeFunctionName(fc.name)) {
                try writer.writeAll(INVALID_FUNCTION_NAME);
                return;
            }
            try writer.writeAll(fc.name);
            try writer.writeAll("(");
            for (fc.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &arg, cmd);
            }
            try writer.writeAll(")");
            if (fc.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .case_expr => |c| {
            try writer.writeAll("CASE");
            for (c.when_clauses) |when_clause| {
                try writer.writeAll(" WHEN ");
                try writeCondition(writer, &when_clause.condition, cmd);
                try writer.writeAll(" THEN ");
                try writeExpr(writer, &when_clause.result, cmd);
            }
            if (c.else_value) |else_expr| {
                try writer.writeAll(" ELSE ");
                try writeExpr(writer, else_expr, cmd);
            }
            try writer.writeAll(" END");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subquery => |sq| {
            try writer.writeByte('(');
            try writeCheckedSubquerySql(writer, sq.sql);
            try writer.writeByte(')');
            if (sq.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .coalesce => |c| {
            try writer.writeAll("COALESCE(");
            for (c.exprs, 0..) |ex_inner, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &ex_inner, cmd);
            }
            try writer.writeAll(")");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .cast => |c| {
            const target_type = checkedSqlTypeFragment(c.target_type) orelse {
                try writer.writeAll(INVALID_CAST_TARGET);
                return;
            };
            try writeExpr(writer, c.expr, cmd);
            try writer.writeAll("::");
            try writer.writeAll(target_type);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .json_access => |ja| {
            try writeColumnReference(writer, ja.column, cmd);
            for (ja.path) |seg| {
                if (seg.as_text) {
                    try writer.writeAll("->>'");
                } else {
                    try writer.writeAll("->'");
                }
                try writeEscapedSqlString(writer, seg.key);
                try writer.writeByte('\'');
            }
            if (ja.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .raw => |raw| try writeCheckedRawExpression(writer, raw),
        .column_def => |def| try writeColumnDefExpr(writer, def),
        .window => |w| try writeWindowExpr(writer, w, cmd),
        .col_mod => |m| {
            // +col or -col for ALTER TABLE
            if (m.kind == .add) {
                try writer.writeByte('+');
            } else {
                try writer.writeByte('-');
            }
            try writeExpr(writer, m.col, cmd);
        },
        .special_func => |sf| {
            // SUBSTRING(expr FROM pos FOR len), EXTRACT(YEAR FROM date), etc.
            if (!isSafeFunctionName(sf.name)) {
                try writer.writeAll(INVALID_FUNCTION_NAME);
                return;
            }
            try writer.writeAll(sf.name);
            try writer.writeByte('(');
            for (sf.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(" ");
                if (arg.keyword) |kw| {
                    if (!isSafeSqlKeyword(kw)) {
                        try writer.writeAll(INVALID_FUNCTION_KEYWORD);
                        return;
                    }
                    try writer.writeAll(kw);
                    try writer.writeAll(" ");
                }
                try writeExpr(writer, arg.expr, cmd);
            }
            try writer.writeByte(')');
            if (sf.alias) |a| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, a);
            }
        },
        .array_constructor => |a| {
            try writer.writeAll("ARRAY[");
            for (a.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &elem, cmd);
            }
            try writer.writeByte(']');
            if (a.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .row_constructor => |r| {
            try writer.writeAll("ROW(");
            for (r.elements, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeExpr(writer, &elem, cmd);
            }
            try writer.writeByte(')');
            if (r.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subscript => |s| {
            try writeExpr(writer, s.base, cmd);
            try writer.writeByte('[');
            try writeExpr(writer, s.index, cmd);
            try writer.writeByte(']');
            if (s.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .collate => |c| {
            try writeExpr(writer, c.expr, cmd);
            try writer.writeAll(" COLLATE ");
            try writeIdentifierOrError(writer, c.collation);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .field_access => |f| {
            try writer.writeByte('(');
            try writeExpr(writer, f.expr, cmd);
            try writer.writeAll(").");
            try writeIdentifierOrError(writer, f.field);
            if (f.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .exists_subquery => |sq| {
            if (sq.negated) {
                try writer.writeAll("NOT EXISTS (");
            } else {
                try writer.writeAll("EXISTS (");
            }
            try writeCheckedSubquerySql(writer, sq.sql);
            try writer.writeByte(')');
            if (sq.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .unary => |u| {
            switch (u.op) {
                .not => try writer.writeAll("NOT "),
                else => try writer.writeAll(u.op.toSql()),
            }
            try writeExpr(writer, u.operand, cmd);
        },
    }
}

fn writeColumnDefExpr(writer: anytype, def: ColumnDef) !void {
    const Constraint = @import("../ast/expr.zig").Constraint;

    try writeIdentifierOrError(writer, def.name);
    try writer.writeAll(" ");
    const data_type = checkedSqlTypeFragment(def.data_type) orelse {
        try writer.writeAll(INVALID_COLUMN_TYPE);
        return;
    };
    try writer.writeAll(data_type);

    const has_pk = def.is_primary_key or Constraint.hasPrimaryKey(def.constraints);
    const has_unique = def.is_unique or Constraint.hasUnique(def.constraints);
    const has_nullable = Constraint.hasNullable(def.constraints);
    const has_not_null = def.is_not_null or Constraint.hasNotNull(def.constraints);
    const is_not_null = has_not_null and !has_nullable;

    if (has_pk) {
        try writer.writeAll(" PRIMARY KEY");
    } else {
        if (is_not_null) {
            try writer.writeAll(" NOT NULL");
        }
        if (has_unique) {
            try writer.writeAll(" UNIQUE");
        }
    }

    if (def.default_value) |dv| {
        try writer.writeAll(" DEFAULT ");
        try writeSqlExprFragmentOrError(writer, dv);
    } else if (Constraint.getDefault(def.constraints)) |dv| {
        try writer.writeAll(" DEFAULT ");
        try writeSqlExprFragmentOrError(writer, dv);
    }

    if (def.references) |ref| {
        try writer.writeAll(" REFERENCES ");
        try writeSqlExprFragmentOrError(writer, ref);
    } else {
        for (def.constraints) |c| {
            if (c == .references) {
                try writer.writeAll(" REFERENCES ");
                try writeSqlExprFragmentOrError(writer, c.references);
            }
        }
    }

    for (def.constraints) |c| {
        if (c == .check) {
            for (c.check) |fragment| {
                try writer.writeAll(" CHECK (");
                try writeSqlExprFragmentOrError(writer, fragment);
                try writer.writeByte(')');
            }
        }
    }
}

fn writeIdentifierList(writer: anytype, values: []const []const u8) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeIdentifierOrError(writer, value);
    }
}

fn checkedForeignKeyAction(action: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, action, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "CASCADE")) return "CASCADE";
    if (std.ascii.eqlIgnoreCase(trimmed, "SET NULL")) return "SET NULL";
    if (std.ascii.eqlIgnoreCase(trimmed, "SET DEFAULT")) return "SET DEFAULT";
    if (std.ascii.eqlIgnoreCase(trimmed, "RESTRICT")) return "RESTRICT";
    if (std.ascii.eqlIgnoreCase(trimmed, "NO ACTION")) return "NO ACTION";
    return null;
}

fn checkedForeignKeyDeferrable(mode: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, mode, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "DEFERRABLE")) return "DEFERRABLE";
    if (std.ascii.eqlIgnoreCase(trimmed, "DEFERRABLE INITIALLY DEFERRED")) return "DEFERRABLE INITIALLY DEFERRED";
    if (std.ascii.eqlIgnoreCase(trimmed, "DEFERRABLE INITIALLY IMMEDIATE")) return "DEFERRABLE INITIALLY IMMEDIATE";
    if (std.ascii.eqlIgnoreCase(trimmed, "NOT DEFERRABLE")) return "NOT DEFERRABLE";
    return null;
}

fn writeForeignKeyOptions(writer: anytype, on_delete: ?[]const u8, on_update: ?[]const u8, deferrable: ?[]const u8) !void {
    if (on_delete) |action| {
        const checked = checkedForeignKeyAction(action) orelse return error.UnsafeSqlFragment;
        try writer.print(" ON DELETE {s}", .{checked});
    }
    if (on_update) |action| {
        const checked = checkedForeignKeyAction(action) orelse return error.UnsafeSqlFragment;
        try writer.print(" ON UPDATE {s}", .{checked});
    }
    if (deferrable) |mode| {
        const checked = checkedForeignKeyDeferrable(mode) orelse return error.UnsafeSqlFragment;
        try writer.print(" {s}", .{checked});
    }
}

fn writeTableConstraint(writer: anytype, constraint: TableConstraint) !void {
    switch (constraint) {
        .unique => |columns| {
            try writer.writeAll("UNIQUE (");
            try writeIdentifierList(writer, columns);
            try writer.writeByte(')');
        },
        .primary_key => |columns| {
            try writer.writeAll("PRIMARY KEY (");
            try writeIdentifierList(writer, columns);
            try writer.writeByte(')');
        },
        .foreign_key => |fk| {
            if (fk.name) |name| {
                try writer.writeAll("CONSTRAINT ");
                try writeIdentifierOrError(writer, name);
                try writer.writeByte(' ');
            }
            try writer.writeAll("FOREIGN KEY (");
            try writeIdentifierList(writer, fk.columns);
            try writer.writeAll(") REFERENCES ");
            try writeIdentifierOrError(writer, fk.ref_table);
            try writer.writeByte('(');
            try writeIdentifierList(writer, fk.ref_columns);
            try writer.writeByte(')');
            try writeForeignKeyOptions(writer, fk.on_delete, fk.on_update, fk.deferrable);
        },
        .check => |expr| {
            if (!isSafeSqlExprFragment(expr)) return error.UnsafeSqlFragment;
            try writer.writeAll("CHECK (");
            try writer.writeAll(std.mem.trim(u8, expr, " \t\r\n"));
            try writer.writeByte(')');
        },
    }
}

fn writeSqlExprFragmentOrError(writer: anytype, fragment: []const u8) !void {
    const checked = checkedSqlExprFragment(fragment) orelse {
        try writer.writeAll(INVALID_COLUMN_FRAGMENT);
        return;
    };
    try writer.writeAll(checked);
}

fn writeWindowExpr(writer: anytype, w: WindowExpr, cmd: ?*const QailCmd) !void {
    if (!isSafeFunctionName(w.func)) {
        try writer.writeAll(INVALID_WINDOW_FUNCTION_NAME);
        return;
    }

    try writer.writeAll(w.func);
    try writer.writeAll("() OVER (");
    if (w.partition.len > 0) {
        try writer.writeAll("PARTITION BY ");
        for (w.partition, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeColumnReference(writer, col, cmd);
        }
    }
    if (w.order.len > 0) {
        if (w.partition.len > 0) try writer.writeAll(" ");
        try writer.writeAll("ORDER BY ");
        for (w.order, 0..) |o, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeColumnReference(writer, o.column, cmd);
            try writer.writeAll(if (o.direction == .asc) " ASC" else " DESC");
        }
    }
    if (w.frame) |frame| {
        if (w.partition.len > 0 or w.order.len > 0) try writer.writeByte(' ');
        try writer.writeAll(if (frame.kind == .rows) "ROWS" else "RANGE");
        try writer.writeAll(" BETWEEN ");
        try writeFrameBound(writer, frame.start_bound);
        if (frame.end_bound) |end| {
            try writer.writeAll(" AND ");
            try writeFrameBound(writer, end);
        }
    }
    try writer.writeByte(')');
    const alias_opt: ?[]const u8 = if (w.alias) |alias| alias else if (w.name.len > 0) w.name else null;
    if (alias_opt) |a| {
        try writer.writeAll(" AS ");
        try writeIdentifierMaybeQuoted(writer, a);
    }
}

fn writeFrameBound(writer: anytype, bound: ast.expr.FrameBound) !void {
    switch (bound) {
        .unbounded_preceding => try writer.writeAll("UNBOUNDED PRECEDING"),
        .unbounded_following => try writer.writeAll("UNBOUNDED FOLLOWING"),
        .current_row => try writer.writeAll("CURRENT ROW"),
        .preceding => |n| try writer.print("{d} PRECEDING", .{n}),
        .following => |n| try writer.print("{d} FOLLOWING", .{n}),
    }
}

fn writeValue(writer: anytype, val: *const Value, cmd: ?*const QailCmd) !void {
    try val.validateFinite();
    switch (val.*) {
        .column => |column| try writeColumnReference(writer, column, cmd),
        .named_param => return error.UnresolvedNamedParameter,
        .function => |function| {
            if (!isSafeRawFunctionValue(function)) return error.UnsafeSqlFragment;
            try writer.writeAll(function);
        },
        .string, .uuid, .timestamp, .json => |text| {
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NullByte;
            try val.format(writer);
        },
        .array => |values| {
            try writer.writeAll("ARRAY[");
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(writer, &value, cmd);
            }
            try writer.writeByte(']');
        },
        else => try val.format(writer),
    }
}

// ==================== Tests ====================

test "ast encoder select" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{ Expr.col("id"), Expr.col("name") };
    const cmd = QailCmd.get("users").select(&cols).limit(10);

    try encoder.encodeQuery(&cmd);
    const bytes = encoder.getWritten();

    // Should have Parse, Bind, Describe, Execute, Sync messages
    try std.testing.expect(bytes.len > 20);

    // First byte should be 'P' (Parse)
    try std.testing.expectEqual(@as(u8, 'P'), bytes[0]);
}

test "ast encoder aggregates" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{ Expr.count(), Expr.sum("amount") };
    const cmd = QailCmd.get("orders").select(&cols);

    try encoder.encodeQuery(&cmd);
    const bytes = encoder.getWritten();

    try std.testing.expect(bytes.len > 20);
}

test "ast encoder quotes condition columns and preserves safe function shorthand" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{ Expr.col("status"), Expr.count() };
    const groups = [_][]const u8{"status"};
    const having = [_]ast.cmd.WhereClause{.{
        .condition = .{ .column = "COUNT(*)", .op = .gt, .value = .{ .int = 5 } },
    }};
    const grouped = QailCmd.get("orders").select(&cols).groupBy(&groups).havingClauses(&having);

    var grouped_buf: [256]u8 = undefined;
    var grouped_writer = io.FixedBufferWriter.init(&grouped_buf);
    try encoder.writeAstToSql(grouped_writer.writer(), &grouped);
    try std.testing.expectEqualStrings(
        "SELECT status, COUNT(*) FROM orders GROUP BY status HAVING COUNT(*) > 5",
        grouped_writer.getWritten(),
    );

    const values = [_]Value{ Value.fromString("active"), Value.fromString("paused") };
    const between_values = [_]Value{ Value.fromInt(1), Value.fromInt(9) };
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("id; DROP TABLE users; --", .eq, Value.fromInt(7)),
        ast.cmd.filter("status; DROP TABLE users; --", .in, .{ .array = &values }),
        ast.cmd.filter("score; DROP TABLE users; --", .between, .{ .array = &between_values }),
    };
    const unsafe = QailCmd.get("users").where(&wheres);

    var unsafe_buf: [512]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe);
    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE \"id; DROP TABLE users; --\" = 7 AND \"status; DROP TABLE users; --\" IN ('active', 'paused') AND \"score; DROP TABLE users; --\" BETWEEN 1 AND 9",
        unsafe_writer.getWritten(),
    );
}

test "ast encoder select shape validation fails closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const fetch_ties = QailCmd.get("events").fetchWithTies(5);
    var fetch_buf: [512]u8 = undefined;
    var fetch_writer = io.FixedBufferWriter.init(&fetch_buf);
    try std.testing.expectError(error.FetchWithTiesRequiresOrderBy, encoder.writeAstToSql(fetch_writer.writer(), &fetch_ties));

    const sample = QailCmd.get("events").tablesampleSystem(std.math.nan(f64));
    var sample_buf: [512]u8 = undefined;
    var sample_writer = io.FixedBufferWriter.init(&sample_buf);
    try std.testing.expectError(error.InvalidTableSamplePercent, encoder.writeAstToSql(sample_writer.writer(), &sample));

    const payload = QailCmd.get("events").setValue("status", .{ .string = "closed" });
    var payload_buf: [512]u8 = undefined;
    var payload_writer = io.FixedBufferWriter.init(&payload_buf);
    try std.testing.expectError(error.InvalidSelectShape, encoder.writeAstToSql(payload_writer.writer(), &payload));

    const skip_locked = QailCmd.get("events").skipLocked();
    var skip_locked_buf: [512]u8 = undefined;
    var skip_locked_writer = io.FixedBufferWriter.init(&skip_locked_buf);
    try std.testing.expectError(error.SkipLockedRequiresLockMode, encoder.writeAstToSql(skip_locked_writer.writer(), &skip_locked));
}

test "ast encoder select renders table modifiers and sort nulls" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{Expr.col("id")};
    const order = [_]ast.cmd.OrderBy{.{ .column = "created_at", .order = .asc_nulls_last }};
    const cmd = QailCmd.get("events")
        .only()
        .tablesampleSystem(12.5)
        .repeatable(7)
        .select(&cols)
        .orderBy(&order)
        .forKeyShare()
        .skipLocked();

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT id FROM ONLY events TABLESAMPLE SYSTEM(12.5) REPEATABLE(7) ORDER BY created_at ASC NULLS LAST FOR KEY SHARE SKIP LOCKED",
        writer.getWritten(),
    );
}

test "ast encoder renders table references without raw injection" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{Expr.col("u.id")};
    const groups = [_][]const u8{"u.id"};
    const orders = [_]ast.cmd.OrderBy{.{ .column = "u.id", .order = .desc }};
    const joins = [_]ast.cmd.Join{.{
        .kind = .left,
        .table = "public.profiles AS p",
        .on_left = "u.id",
        .on_right = "p.user_id",
    }};
    const safe = QailCmd.get("public.users AS u")
        .select(&cols)
        .join(&joins)
        .groupBy(&groups)
        .orderBy(&orders);

    var safe_buf: [512]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe);
    try std.testing.expectEqualStrings(
        "SELECT u.id FROM public.users AS u LEFT JOIN public.profiles AS p ON u.id = p.user_id GROUP BY u.id ORDER BY u.id DESC",
        safe_writer.getWritten(),
    );

    const unsafe = QailCmd.get("users WHERE tenant_id <> 'tenant-a'; DROP TABLE users; --");
    var unsafe_buf: [512]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe);
    try std.testing.expectEqualStrings(
        "SELECT * FROM \"users WHERE tenant_id <> 'tenant-a'; DROP TABLE users; --\"",
        unsafe_writer.getWritten(),
    );
}

test "ast encoder resolves schema-qualified references through aliases" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{
        Expr.col("public.orders.id"),
        .{ .aggregate = .{ .func = .sum, .column = "public.orders.total", .alias = "total" } },
        .{ .json_access = .{
            .column = "public.orders.payload",
            .path = &[_]ast.expr.JsonPathSegment{.{ .key = "tier", .as_text = true }},
            .alias = "tier",
        } },
    };
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("public.orders.status", .eq, Value.fromColumn("public.orders.previous_status")),
    };
    const groups = [_][]const u8{ "public.orders.id", "public.orders.payload" };
    const orders = [_]ast.cmd.OrderBy{.{ .column = "public.orders.created_at", .order = .desc }};
    const joins = [_]ast.cmd.Join{.{
        .kind = .left,
        .table = "crm.users AS u",
        .on_left = "public.orders.user_id",
        .on_right = "crm.users.id",
    }};
    const cmd = QailCmd.get("public.orders")
        .alias("o")
        .select(&cols)
        .join(&joins)
        .where(&wheres)
        .groupBy(&groups)
        .orderBy(&orders);

    var sql_buf: [1024]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT o.id, SUM(o.total) AS total, o.payload->>'tier' AS tier FROM public.orders AS o LEFT JOIN crm.users AS u ON o.user_id = u.id WHERE o.status = o.previous_status GROUP BY o.id, o.payload ORDER BY o.created_at DESC",
        writer.getWritten(),
    );
}

test "ast encoder renders mutation targets without raw injection" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const update_cmd = QailCmd.set("users u").setValue("email", .{ .string = "new@example.com" });
    var update_buf: [256]u8 = undefined;
    var update_writer = io.FixedBufferWriter.init(&update_buf);
    try encoder.writeAstToSql(update_writer.writer(), &update_cmd);
    try std.testing.expectEqualStrings(
        "UPDATE users u SET email = 'new@example.com'",
        update_writer.getWritten(),
    );

    const delete_cmd = QailCmd.del("users; DROP TABLE users; --");
    var delete_buf: [256]u8 = undefined;
    var delete_writer = io.FixedBufferWriter.init(&delete_buf);
    try encoder.writeAstToSql(delete_writer.writer(), &delete_cmd);
    try std.testing.expectEqualStrings(
        "DELETE FROM \"users; DROP TABLE users; --\"",
        delete_writer.getWritten(),
    );
}

test "ast encoder renders update from and delete using aliases" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const update_assignments = [_]ast.cmd.Assignment{.{
        .column = "status",
        .value = Value.fromColumn("billing.payments.status"),
    }};
    const update_wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("public.orders.payment_id", .eq, Value.fromColumn("billing.payments.id")),
    };
    var update_cmd = QailCmd.set("public.orders").alias("o");
    update_cmd.assignments = &update_assignments;
    update_cmd.from_tables = &.{"billing.payments p"};
    update_cmd.where_clauses = &update_wheres;

    var update_buf: [512]u8 = undefined;
    var update_writer = io.FixedBufferWriter.init(&update_buf);
    try encoder.writeAstToSql(update_writer.writer(), &update_cmd);
    try std.testing.expectEqualStrings(
        "UPDATE public.orders AS o SET status = p.status FROM billing.payments p WHERE o.payment_id = p.id",
        update_writer.getWritten(),
    );

    const delete_wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("public.sessions.user_id", .eq, Value.fromColumn("auth.users.id")),
    };
    const returning = [_]Expr{Expr.col("public.sessions.id")};
    var delete_cmd = QailCmd.del("public.sessions").alias("s");
    delete_cmd.using_tables = &.{"auth.users u"};
    delete_cmd.where_clauses = &delete_wheres;
    delete_cmd.returning = &returning;

    var delete_buf: [512]u8 = undefined;
    var delete_writer = io.FixedBufferWriter.init(&delete_buf);
    try encoder.writeAstToSql(delete_writer.writer(), &delete_cmd);
    try std.testing.expectEqualStrings(
        "DELETE FROM public.sessions AS s USING auth.users u WHERE s.user_id = u.id RETURNING s.id",
        delete_writer.getWritten(),
    );
}

test "ast encoder quotes condition column shorthand instead of emitting raw text" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("id; DROP TABLE users; --", .eq, Value.fromInt(7)),
    };
    const cmd = QailCmd.get("users").where(&wheres);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE \"id; DROP TABLE users; --\" = 7",
        writer.getWritten(),
    );
}

test "ast encoder where groups and + or clauses like qail.rs or_filter semantics" {
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.filter("is_active", .eq, .{ .bool = true }),
        ast.cmd.orFilter("topic", .ilike, .{ .string = "%test%" }),
        ast.cmd.orFilter("question", .ilike, .{ .string = "%test%" }),
    };
    const cmd = QailCmd.get("kb").where(&wheres);

    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var sql_buf: [4096]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);
    const sql = writer.getWritten();

    try std.testing.expectEqualStrings(
        "SELECT * FROM kb WHERE is_active = true AND (topic ILIKE '%test%' OR question ILIKE '%test%')",
        sql,
    );
}

test "ast encoder where supports pure or-filter groups" {
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.orFilter("name", .ilike, .{ .string = "%coffee%" }),
        ast.cmd.orFilter("description", .ilike, .{ .string = "%coffee%" }),
    };
    const cmd = QailCmd.get("products").where(&wheres);

    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var sql_buf: [4096]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);
    const sql = writer.getWritten();

    try std.testing.expectEqualStrings(
        "SELECT * FROM products WHERE (name ILIKE '%coffee%' OR description ILIKE '%coffee%')",
        sql,
    );
}

test "ast encoder update with or-filter grouping" {
    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "archived", .value = .{ .bool = true } },
    };
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.orFilter("topic", .ilike, .{ .string = "%test%" }),
        ast.cmd.orFilter("question", .ilike, .{ .string = "%test%" }),
    };
    const cmd = QailCmd.set("kb").values(&assigns).where(&wheres);

    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var sql_buf: [4096]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);
    const sql = writer.getWritten();

    try std.testing.expectEqualStrings(
        "UPDATE kb SET archived = true WHERE (topic ILIKE '%test%' OR question ILIKE '%test%')",
        sql,
    );
}

test "ast encoder update shape validation fails closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const empty = QailCmd.set("kb");
    var empty_buf: [512]u8 = undefined;
    var empty_writer = io.FixedBufferWriter.init(&empty_buf);
    try std.testing.expectError(error.MissingUpdateAssignments, encoder.writeAstToSql(empty_writer.writer(), &empty));

    const cols = [_]Expr{Expr.col("archived")};
    const assigns = [_]ast.cmd.Assignment{.{ .column = "archived", .value = .{ .bool = true } }};
    const ambiguous = QailCmd.set("kb").select(&cols).values(&assigns);
    var ambiguous_buf: [512]u8 = undefined;
    var ambiguous_writer = io.FixedBufferWriter.init(&ambiguous_buf);
    try std.testing.expectError(error.InvalidUpdateShape, encoder.writeAstToSql(ambiguous_writer.writer(), &ambiguous));

    const dup_assigns = [_]ast.cmd.Assignment{
        .{ .column = "status", .value = .{ .string = "ready" } },
        .{ .column = "STATUS", .value = .{ .string = "closed" } },
    };
    const duplicate = QailCmd.set("kb").values(&dup_assigns);
    var duplicate_buf: [512]u8 = undefined;
    var duplicate_writer = io.FixedBufferWriter.init(&duplicate_buf);
    try std.testing.expectError(error.DuplicateWriteTarget, encoder.writeAstToSql(duplicate_writer.writer(), &duplicate));
}

test "ast encoder update and delete render only table" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const assigns = [_]ast.cmd.Assignment{.{ .column = "archived", .value = .{ .bool = true } }};
    const update = QailCmd.set("kb").only().values(&assigns);

    var update_buf: [512]u8 = undefined;
    var update_writer = io.FixedBufferWriter.init(&update_buf);
    try encoder.writeAstToSql(update_writer.writer(), &update);
    try std.testing.expectEqualStrings("UPDATE ONLY kb SET archived = true", update_writer.getWritten());

    const delete = QailCmd.del("kb").only();
    var delete_buf: [512]u8 = undefined;
    var delete_writer = io.FixedBufferWriter.init(&delete_buf);
    try encoder.writeAstToSql(delete_writer.writer(), &delete);
    try std.testing.expectEqualStrings("DELETE FROM ONLY kb", delete_writer.getWritten());
}

test "ast encoder lock table uses typed mode" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cmd = QailCmd.lockTable("users").lockTableMode(.access_exclusive);

    var sql_buf: [256]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings("LOCK TABLE users ACCESS EXCLUSIVE MODE", writer.getWritten());
}

test "ast encoder create table keeps unspecified columns nullable" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const defs = [_]Expr{
        .{ .column_def = .{ .name = "id", .data_type = "serial", .is_primary_key = true } },
        .{ .column_def = .{ .name = "nickname", .data_type = "text" } },
        .{ .column_def = .{ .name = "email", .data_type = "text", .is_not_null = true } },
    };
    const cmd = QailCmd.make("users").select(&defs);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS users (id serial PRIMARY KEY, nickname text, email text NOT NULL)",
        writer.getWritten(),
    );
}

test "ast encoder column definition fragments fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const safe_check_values = [_][]const u8{"note <> 'semi;inside'"};
    const safe_constraints = [_]ast.expr.Constraint{ .{ .default = "'semi;inside'" }, .{ .check = &safe_check_values } };
    const safe_defs = [_]Expr{Expr.defWithConstraints("note", "text", &safe_constraints)};
    const safe_cmd = QailCmd.make("events").select(&safe_defs);

    var safe_buf: [512]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS events (note text DEFAULT 'semi;inside' CHECK (note <> 'semi;inside'))",
        safe_writer.getWritten(),
    );

    const bad_check_values = [_][]const u8{"score > 0; DROP TABLE users; --"};
    const bad_constraints = [_]ast.expr.Constraint{ .{ .default = "0; DROP TABLE users; --" }, .{ .check = &bad_check_values } };
    const bad_defs = [_]Expr{Expr.defWithConstraints("score", "integer", &bad_constraints)};
    const bad_cmd = QailCmd.make("events").select(&bad_defs);

    var bad_buf: [512]u8 = undefined;
    var bad_writer = io.FixedBufferWriter.init(&bad_buf);
    try encoder.writeAstToSql(bad_writer.writer(), &bad_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS events (score integer DEFAULT /* ERROR: Invalid column definition fragment */ CHECK (/* ERROR: Invalid column definition fragment */))",
        bad_writer.getWritten(),
    );

    const ref_defs = [_]Expr{.{ .column_def = .{
        .name = "user_id",
        .data_type = "uuid",
        .references = "users(id); DROP TABLE users; --",
    } }};
    const ref_cmd = QailCmd.make("events").select(&ref_defs);

    var ref_buf: [512]u8 = undefined;
    var ref_writer = io.FixedBufferWriter.init(&ref_buf);
    try encoder.writeAstToSql(ref_writer.writer(), &ref_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS events (user_id uuid REFERENCES /* ERROR: Invalid column definition fragment */)",
        ref_writer.getWritten(),
    );
}

test "ast encoder view payload fragments fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var safe_view = QailCmd.createView("notes_view");
    safe_view.raw_sql = "SELECT 'semi;inside' AS note";
    var safe_buf: [256]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe_view);
    try std.testing.expectEqualStrings(
        "CREATE VIEW notes_view AS SELECT 'semi;inside' AS note",
        safe_writer.getWritten(),
    );

    var unsafe_view = QailCmd.createView("active_users");
    unsafe_view.raw_sql = "SELECT id FROM users; DROP TABLE users; --";
    var unsafe_buf: [256]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe_view);
    try std.testing.expectEqualStrings(
        "CREATE VIEW active_users AS SELECT NULL WHERE FALSE",
        unsafe_writer.getWritten(),
    );

    var mutating_view = QailCmd.createView("deleted_users");
    mutating_view.raw_sql = "DELETE FROM users RETURNING id";
    var mutating_view_buf: [256]u8 = undefined;
    var mutating_view_writer = io.FixedBufferWriter.init(&mutating_view_buf);
    try encoder.writeAstToSql(mutating_view_writer.writer(), &mutating_view);
    try std.testing.expectEqualStrings(
        "CREATE VIEW deleted_users AS SELECT NULL WHERE FALSE",
        mutating_view_writer.getWritten(),
    );

    var unsafe_materialized = QailCmd.createMaterializedView("booking_stats");
    unsafe_materialized.raw_sql = "SELECT COUNT(*) FROM bookings; DROP TABLE bookings; --";
    var materialized_buf: [256]u8 = undefined;
    var materialized_writer = io.FixedBufferWriter.init(&materialized_buf);
    try encoder.writeAstToSql(materialized_writer.writer(), &unsafe_materialized);
    try std.testing.expectEqualStrings(
        "CREATE MATERIALIZED VIEW booking_stats AS SELECT NULL WHERE FALSE",
        materialized_writer.getWritten(),
    );

    var mutating_materialized = QailCmd.createMaterializedView("deleted_booking_stats");
    mutating_materialized.raw_sql = "WITH deleted AS (DELETE FROM bookings RETURNING id) SELECT id FROM deleted";
    var mutating_materialized_buf: [256]u8 = undefined;
    var mutating_materialized_writer = io.FixedBufferWriter.init(&mutating_materialized_buf);
    try encoder.writeAstToSql(mutating_materialized_writer.writer(), &mutating_materialized);
    try std.testing.expectEqualStrings(
        "CREATE MATERIALIZED VIEW deleted_booking_stats AS SELECT NULL WHERE FALSE",
        mutating_materialized_writer.getWritten(),
    );
}

test "ast encoder alter expression fragments fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const safe_cols = [_]Expr{Expr.col("note")};
    const safe_default = QailCmd{
        .kind = .alter_set_default,
        .table = "events",
        .columns = &safe_cols,
        .payload = "'semi;inside'",
    };
    var safe_buf: [256]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe_default);
    try std.testing.expectEqualStrings(
        "ALTER TABLE events ALTER COLUMN note SET DEFAULT 'semi;inside'",
        safe_writer.getWritten(),
    );

    const unsafe_cols = [_]Expr{Expr.col("score")};
    const unsafe_default = QailCmd{
        .kind = .alter_set_default,
        .table = "events",
        .columns = &unsafe_cols,
        .payload = "0; DROP TABLE events; --",
    };
    var unsafe_buf: [256]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe_default);
    try std.testing.expectEqualStrings(
        "ALTER TABLE events ALTER COLUMN score SET DEFAULT NULL",
        unsafe_writer.getWritten(),
    );
}

test "ast encoder alter type fragments fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const safe_defs = [_]Expr{.{ .column_def = .{ .name = "label", .data_type = "public.citext" } }};
    const safe_cmd = QailCmd{
        .kind = .alter_type,
        .table = "events",
        .columns = &safe_defs,
    };
    var safe_buf: [256]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe_cmd);
    try std.testing.expectEqualStrings(
        "ALTER TABLE events ALTER COLUMN label TYPE public.citext",
        safe_writer.getWritten(),
    );

    const unsafe_defs = [_]Expr{.{ .column_def = .{ .name = "unsafe_type", .data_type = "text); DROP TABLE users; --" } }};
    const unsafe_cmd = QailCmd{
        .kind = .alter_type,
        .table = "events",
        .columns = &unsafe_defs,
    };
    var unsafe_buf: [256]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe_cmd);
    try std.testing.expectEqualStrings(
        "ALTER TABLE events ALTER COLUMN unsafe_type TYPE TEXT",
        unsafe_writer.getWritten(),
    );
}

test "ast encoder insert uses typed source query" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const target_cols = [_]Expr{ Expr.col("id"), Expr.col("email") };
    const source_cols = [_]Expr{ Expr.col("id"), Expr.col("email") };
    const source = QailCmd.get("users_archive").select(&source_cols);
    const cmd = QailCmd.add("users").select(&target_cols).withSourceQuery(&source);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "INSERT INTO users (id, email) SELECT id, email FROM users_archive",
        writer.getWritten(),
    );
}

test "ast encoder insert renders targets and raw sources defensively" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const values = [_]Value{.{ .int = 1 }};
    var unsafe_target = QailCmd.add("users; DROP TABLE users; --").select(&.{Expr.col("id")});
    unsafe_target.insert_values = &values;

    var target_buf: [256]u8 = undefined;
    var target_writer = io.FixedBufferWriter.init(&target_buf);
    try encoder.writeAstToSql(target_writer.writer(), &unsafe_target);
    try std.testing.expectEqualStrings(
        "INSERT INTO \"users; DROP TABLE users; --\" (id) VALUES (1)",
        target_writer.getWritten(),
    );

    var safe_source = QailCmd.add("events");
    safe_source.raw_sql = "SELECT 'semi;inside' AS note";
    var safe_buf: [256]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe_source);
    try std.testing.expectEqualStrings(
        "INSERT INTO events SELECT 'semi;inside' AS note",
        safe_writer.getWritten(),
    );

    var unsafe_source = QailCmd.add("events");
    unsafe_source.raw_sql = "SELECT id FROM users; DROP TABLE users; --";
    var unsafe_buf: [256]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe_source);
    try std.testing.expectEqualStrings(
        "INSERT INTO events SELECT NULL WHERE FALSE",
        unsafe_writer.getWritten(),
    );

    var mutating_source = QailCmd.add("events");
    mutating_source.raw_sql = "DELETE FROM users RETURNING id";
    var mutating_buf: [256]u8 = undefined;
    var mutating_writer = io.FixedBufferWriter.init(&mutating_buf);
    try encoder.writeAstToSql(mutating_writer.writer(), &mutating_source);
    try std.testing.expectEqualStrings(
        "INSERT INTO events SELECT NULL WHERE FALSE",
        mutating_writer.getWritten(),
    );
}

test "ast encoder insert target expressions fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const target_cols = [_]Expr{ Expr.int(1), Expr.col("email") };
    const values = [_]Value{ .{ .int = 1 }, .{ .string = "alice@example.com" } };
    var cmd = QailCmd.add("users").select(&target_cols);
    cmd.insert_values = &values;

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try std.testing.expectError(error.InvalidInsertColumn, encoder.writeAstToSql(writer.writer(), &cmd));
}

test "ast encoder insert shape validation fails closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cols = [_]Expr{ Expr.col("id"), Expr.col("email") };
    const values = [_]Value{.{ .int = 1 }};
    var mismatch = QailCmd.add("users").select(&cols);
    mismatch.insert_values = &values;

    var mismatch_buf: [512]u8 = undefined;
    var mismatch_writer = io.FixedBufferWriter.init(&mismatch_buf);
    try std.testing.expectError(error.InvalidInsertShape, encoder.writeAstToSql(mismatch_writer.writer(), &mismatch));

    var empty = QailCmd.add("users");
    var empty_buf: [512]u8 = undefined;
    var empty_writer = io.FixedBufferWriter.init(&empty_buf);
    try std.testing.expectError(error.MissingInsertValues, encoder.writeAstToSql(empty_writer.writer(), &empty));

    const defaults_cols = [_]Expr{Expr.col("id")};
    var defaults = QailCmd.add("users").defaultValues().select(&defaults_cols);
    var defaults_buf: [512]u8 = undefined;
    var defaults_writer = io.FixedBufferWriter.init(&defaults_buf);
    try std.testing.expectError(error.InvalidInsertShape, encoder.writeAstToSql(defaults_writer.writer(), &defaults));

    const source_cols = [_]Expr{Expr.col("id")};
    const source = QailCmd.get("users_archive").select(&source_cols);
    var ambiguous = QailCmd.add("users").withSourceQuery(&source);
    ambiguous.insert_values = &values;
    var ambiguous_buf: [512]u8 = undefined;
    var ambiguous_writer = io.FixedBufferWriter.init(&ambiguous_buf);
    try std.testing.expectError(error.InvalidInsertShape, encoder.writeAstToSql(ambiguous_writer.writer(), &ambiguous));
}

test "ast encoder conflict update shape validation fails closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const assignments = [_]ast.cmd.Assignment{.{ .column = "email", .value = .{ .string = "a@example.com" } }};
    const no_target_conflict = ast.cmd.OnConflict{
        .columns = &.{},
        .action = .do_update,
        .update_columns = &assignments,
    };
    var no_target = QailCmd.add("users").onConflictDo(no_target_conflict);
    no_target.assignments = &assignments;

    var no_target_buf: [512]u8 = undefined;
    var no_target_writer = io.FixedBufferWriter.init(&no_target_buf);
    try std.testing.expectError(error.InvalidOnConflictShape, encoder.writeAstToSql(no_target_writer.writer(), &no_target));

    const target_cols = [_][]const u8{"id"};
    const no_assign_conflict = ast.cmd.OnConflict{
        .columns = &target_cols,
        .action = .do_update,
        .update_columns = &.{},
    };
    var no_assign = QailCmd.add("users").onConflictDo(no_assign_conflict);
    const values = [_]Value{.{ .int = 1 }};
    no_assign.insert_values = &values;

    var no_assign_buf: [512]u8 = undefined;
    var no_assign_writer = io.FixedBufferWriter.init(&no_assign_buf);
    try std.testing.expectError(error.InvalidOnConflictShape, encoder.writeAstToSql(no_assign_writer.writer(), &no_assign));
}

test "ast encoder create view uses typed source query" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const source_cols = [_]Expr{ Expr.col("id"), Expr.col("email") };
    const source = QailCmd.get("users").select(&source_cols);
    const cmd = QailCmd.createViewFromQuery("user_emails", &source);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "CREATE VIEW user_emails AS SELECT id, email FROM users",
        writer.getWritten(),
    );
}

test "ast encoder create materialized view uses typed source query constructor" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const source_cols = [_]Expr{Expr.col("id")};
    const source = QailCmd.get("users").select(&source_cols);
    const cmd = QailCmd.createMaterializedViewFromQuery("mv_user_ids", &source);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "CREATE MATERIALIZED VIEW mv_user_ids AS SELECT id FROM users",
        writer.getWritten(),
    );
}

test "ast encoder cte uses typed base query" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const source_cols = [_]Expr{Expr.col("user_id")};
    const outer_cols = [_]Expr{Expr.col("user_id")};
    const source = QailCmd.get("orders").select(&source_cols);
    const ctes = [_]ast.cmd.CTEDef{ast.cmd.CTEDef.fromQuery("active_orders", &source)};
    const cmd = QailCmd.get("active_orders").select(&outer_cols).withCtes(&ctes);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "WITH active_orders AS (SELECT user_id FROM orders) SELECT user_id FROM active_orders",
        writer.getWritten(),
    );
}

test "ast encoder cte supports raw nested query compatibility via nested raw command" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var raw = ast.raw_cmd.command("SELECT 1");
    const ctes = [_]ast.cmd.CTEDef{ast.cmd.CTEDef.fromQuery("legacy", &raw)};
    const cmd = QailCmd.get("legacy").withCtes(&ctes);

    var sql_buf: [256]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "WITH legacy AS (SELECT 1) SELECT * FROM legacy",
        writer.getWritten(),
    );
}

test "ast encoder recursive cte uses typed recursive query" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const base_cols = [_]Expr{Expr.col("id")};
    const recursive_cols = [_]Expr{Expr.col("id")};
    const outer_cols = [_]Expr{Expr.col("id")};
    const base = QailCmd.get("users").select(&base_cols);
    const recursive = QailCmd.get("active_users").select(&recursive_cols);
    const ctes = [_]ast.cmd.CTEDef{
        ast.cmd.CTEDef.fromQuery("active_users", &base).recursiveUnionAll(&recursive),
    };
    const cmd = QailCmd.get("active_users").select(&outer_cols).withCtes(&ctes);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "WITH RECURSIVE active_users AS (SELECT id FROM users UNION ALL SELECT id FROM active_users) SELECT id FROM active_users",
        writer.getWritten(),
    );
}

test "ast encoder set ops use typed queries" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const left_cols = [_]Expr{Expr.col("id")};
    const right_cols = [_]Expr{Expr.col("id")};
    const rhs = QailCmd.get("admins").select(&right_cols);
    const set_ops = [_]ast.cmd.SetOpDef{ast.cmd.SetOpDef.fromQuery(.union_all, &rhs)};
    const cmd = QailCmd.get("users").select(&left_cols).withSetOps(&set_ops);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT id FROM users UNION ALL SELECT id FROM admins",
        writer.getWritten(),
    );
}

test "ast encoder set ops support raw nested query compatibility via nested raw command" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const left_cols = [_]Expr{Expr.col("id")};
    var raw = ast.raw_cmd.command("SELECT id FROM legacy_admins");
    const set_ops = [_]ast.cmd.SetOpDef{ast.cmd.SetOpDef.fromQuery(.union_all, &raw)};
    const cmd = QailCmd.get("users").select(&left_cols).withSetOps(&set_ops);

    var sql_buf: [256]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT id FROM users UNION ALL SELECT id FROM legacy_admins",
        writer.getWritten(),
    );
}

test "ast encoder delete with or-filter grouping" {
    const wheres = [_]ast.cmd.WhereClause{
        ast.cmd.orFilter("topic", .ilike, .{ .string = "%test%" }),
        ast.cmd.orFilter("question", .ilike, .{ .string = "%test%" }),
    };
    const cmd = QailCmd.del("kb").where(&wheres);

    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var sql_buf: [4096]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);
    const sql = writer.getWritten();

    try std.testing.expectEqualStrings(
        "DELETE FROM kb WHERE (topic ILIKE '%test%' OR question ILIKE '%test%')",
        sql,
    );
}

test "ast encoder put defaults to conflict do nothing" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "id", .value = Value.fromInt(1) },
        .{ .column = "name", .value = Value.fromString("alpha") },
    };
    const cmd = QailCmd.put("users").values(&assigns);

    try encoder.encodeQuery(&cmd);
    const bytes = encoder.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "ON CONFLICT DO NOTHING") != null);
}

test "ast encoder create enum from insert values" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const values = [_]Value{
        Value.fromString("todo"),
        Value.fromString("done"),
    };
    var cmd = QailCmd{
        .kind = .create_enum,
        .table = "task_status",
        .insert_values = &values,
    };

    try encoder.encodeQuery(&cmd);
    const bytes = encoder.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "CREATE TYPE task_status AS ENUM") != null);
}

test "ast encoder comment targets are sanitized" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var table_comment = QailCmd.commentOn("users");
    table_comment.payload = "owner's note";
    var table_buf: [256]u8 = undefined;
    var table_writer = io.FixedBufferWriter.init(&table_buf);
    try encoder.writeAstToSql(table_writer.writer(), &table_comment);
    try std.testing.expectEqualStrings("COMMENT ON TABLE users IS 'owner''s note'", table_writer.getWritten());

    var column_comment = QailCmd.commentOn("users.email");
    column_comment.payload = "email column";
    var column_buf: [256]u8 = undefined;
    var column_writer = io.FixedBufferWriter.init(&column_buf);
    try encoder.writeAstToSql(column_writer.writer(), &column_comment);
    try std.testing.expectEqualStrings("COMMENT ON COLUMN users.email IS 'email column'", column_writer.getWritten());

    var function_comment = QailCmd.commentOn("FUNCTION public.cleanup(numeric(10,2), text)");
    function_comment.payload = "cleanup helper";
    var function_buf: [256]u8 = undefined;
    var function_writer = io.FixedBufferWriter.init(&function_buf);
    try encoder.writeAstToSql(function_writer.writer(), &function_comment);
    try std.testing.expectEqualStrings(
        "COMMENT ON FUNCTION public.cleanup(numeric(10,2), text) IS 'cleanup helper'",
        function_writer.getWritten(),
    );

    var unsafe_comment = QailCmd.commentOn("TABLE users; DROP TABLE users; --");
    unsafe_comment.payload = "owner's note\x00";
    var unsafe_buf: [256]u8 = undefined;
    var unsafe_writer = io.FixedBufferWriter.init(&unsafe_buf);
    try encoder.writeAstToSql(unsafe_writer.writer(), &unsafe_comment);
    try std.testing.expectEqualStrings(
        "COMMENT ON TABLE \"TABLE users; DROP TABLE users; --\" IS 'owner''s note'",
        unsafe_writer.getWritten(),
    );
}

test "ast encoder procedural targets are sanitized" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const valid_call = QailCmd.callProc("maintenance.refresh()");
    var valid_call_buf: [256]u8 = undefined;
    var valid_call_writer = io.FixedBufferWriter.init(&valid_call_buf);
    try encoder.writeAstToSql(valid_call_writer.writer(), &valid_call);
    try std.testing.expectEqualStrings("CALL maintenance.refresh()", valid_call_writer.getWritten());

    const malicious_call = QailCmd.callProc("refresh(); DROP TABLE users; --");
    var malicious_call_buf: [256]u8 = undefined;
    var malicious_call_writer = io.FixedBufferWriter.init(&malicious_call_buf);
    try encoder.writeAstToSql(malicious_call_writer.writer(), &malicious_call);
    try std.testing.expectEqualStrings("CALL \"refresh(); DROP TABLE users; --\"", malicious_call_writer.getWritten());

    const do_cmd = QailCmd{
        .kind = .do_block,
        .table = "plpgsql",
        .payload = "BEGIN RAISE NOTICE $$boom$$; END;",
    };
    var do_buf: [256]u8 = undefined;
    var do_writer = io.FixedBufferWriter.init(&do_buf);
    try encoder.writeAstToSql(do_writer.writer(), &do_cmd);
    try std.testing.expectEqualStrings(
        "DO $qail_body_1$ BEGIN RAISE NOTICE $$boom$$; END; $qail_body_1$ LANGUAGE plpgsql",
        do_writer.getWritten(),
    );
}

test "ast encoder function signatures and session settings are sanitized" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var valid_drop = QailCmd.dropFunction("");
    valid_drop.payload = "public.price_quote(numeric(12,2), text[])";
    var valid_drop_buf: [256]u8 = undefined;
    var valid_drop_writer = io.FixedBufferWriter.init(&valid_drop_buf);
    try encoder.writeAstToSql(valid_drop_writer.writer(), &valid_drop);
    try std.testing.expectEqualStrings(
        "DROP FUNCTION IF EXISTS public.price_quote(numeric(12,2), text[])",
        valid_drop_writer.getWritten(),
    );

    try std.testing.expect(functionArgsAreSafe("numeric(12,2), text[]"));
    try std.testing.expect(!functionArgsAreSafe("numeric(12,2), text["));
    try std.testing.expect(!functionArgsAreSafe("numeric(12,2), text]"));
    try std.testing.expect(!functionArgsAreSafe("int\x00"));
    try std.testing.expect(!functionArgsAreSafe("int\ntext"));

    var malicious_drop = QailCmd.dropFunction("");
    malicious_drop.payload = "public.cleanup(int); DROP TABLE users; --";
    var malicious_drop_buf: [256]u8 = undefined;
    var malicious_drop_writer = io.FixedBufferWriter.init(&malicious_drop_buf);
    try encoder.writeAstToSql(malicious_drop_writer.writer(), &malicious_drop);
    try std.testing.expectEqualStrings(
        "DROP FUNCTION IF EXISTS public.\"cleanup(int); DROP TABLE users; --\"",
        malicious_drop_writer.getWritten(),
    );

    var invalid_args_drop = QailCmd.dropFunction("");
    invalid_args_drop.payload = "public.cleanup(text[)";
    var invalid_args_buf: [256]u8 = undefined;
    var invalid_args_writer = io.FixedBufferWriter.init(&invalid_args_buf);
    try encoder.writeAstToSql(invalid_args_writer.writer(), &invalid_args_drop);
    try std.testing.expectEqualStrings(
        "DROP FUNCTION IF EXISTS public.\"cleanup(text[)\"",
        invalid_args_writer.getWritten(),
    );

    var session_set = QailCmd.sessionSet("app.current_tenant");
    session_set.payload = "tenant-1";
    var session_buf: [256]u8 = undefined;
    var session_writer = io.FixedBufferWriter.init(&session_buf);
    try encoder.writeAstToSql(session_writer.writer(), &session_set);
    try std.testing.expectEqualStrings("SET app.current_tenant = 'tenant-1'", session_writer.getWritten());

    const session_reset = QailCmd.sessionReset("app.current; DROP TABLE users; --");
    var reset_buf: [256]u8 = undefined;
    var reset_writer = io.FixedBufferWriter.init(&reset_buf);
    try encoder.writeAstToSql(reset_writer.writer(), &session_reset);
    try std.testing.expectEqualStrings("RESET app.\"current; DROP TABLE users; --\"", reset_writer.getWritten());
}

test "ast encoder validates trusted function and trigger payloads" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var function_cmd = QailCmd.createFunction("touch_users");
    function_cmd.payload = "() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM 1 AS one; END; $$";
    var function_buf: [512]u8 = undefined;
    var function_writer = io.FixedBufferWriter.init(&function_buf);
    try encoder.writeAstToSql(function_writer.writer(), &function_cmd);
    try std.testing.expectEqualStrings(
        "CREATE FUNCTION touch_users () RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM 1 AS one; END; $$",
        function_writer.getWritten(),
    );

    var bad_language = QailCmd.createFunction("touch_users");
    bad_language.payload = "() RETURNS void LANGUAGE bad-lang AS $$ BEGIN NULL; END; $$";
    var bad_language_buf: [512]u8 = undefined;
    var bad_language_writer = io.FixedBufferWriter.init(&bad_language_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(bad_language_writer.writer(), &bad_language));

    var duplicate_language = QailCmd.createFunction("touch_users");
    duplicate_language.payload = "() RETURNS void LANGUAGE sql LANGUAGE plpgsql AS $$ SELECT 1 $$";
    var duplicate_language_buf: [512]u8 = undefined;
    var duplicate_language_writer = io.FixedBufferWriter.init(&duplicate_language_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(duplicate_language_writer.writer(), &duplicate_language));

    var trailing_function = QailCmd.createFunction("touch_users");
    trailing_function.payload = "() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$ DROP TABLE users";
    var trailing_function_buf: [512]u8 = undefined;
    var trailing_function_writer = io.FixedBufferWriter.init(&trailing_function_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(trailing_function_writer.writer(), &trailing_function));

    var trigger_cmd = QailCmd.createTrigger("touch_users_updated");
    trigger_cmd.payload = "BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION touch_users()";
    var trigger_buf: [512]u8 = undefined;
    var trigger_writer = io.FixedBufferWriter.init(&trigger_buf);
    try encoder.writeAstToSql(trigger_writer.writer(), &trigger_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TRIGGER touch_users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION touch_users()",
        trigger_writer.getWritten(),
    );

    var qualified_trigger = QailCmd.createTrigger("touch_users_updated");
    qualified_trigger.payload = "BEFORE UPDATE OF updated_at,email ON app.users FOR EACH ROW EXECUTE FUNCTION util.touch()";
    var qualified_trigger_buf: [512]u8 = undefined;
    var qualified_trigger_writer = io.FixedBufferWriter.init(&qualified_trigger_buf);
    try encoder.writeAstToSql(qualified_trigger_writer.writer(), &qualified_trigger);
    try std.testing.expectEqualStrings(
        "CREATE TRIGGER touch_users_updated BEFORE UPDATE OF updated_at,email ON app.users FOR EACH ROW EXECUTE FUNCTION util.touch()",
        qualified_trigger_writer.getWritten(),
    );

    var unsafe_trigger = QailCmd.createTrigger("touch_users_updated");
    unsafe_trigger.payload = "BEFORE UPDATE ON users; DROP TABLE users; --";
    var unsafe_trigger_buf: [512]u8 = undefined;
    var unsafe_trigger_writer = io.FixedBufferWriter.init(&unsafe_trigger_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(unsafe_trigger_writer.writer(), &unsafe_trigger));

    var duplicate_event = QailCmd.createTrigger("touch_users_updated");
    duplicate_event.payload = "BEFORE UPDATE OR UPDATE ON users EXECUTE FUNCTION touch_users()";
    var duplicate_event_buf: [512]u8 = undefined;
    var duplicate_event_writer = io.FixedBufferWriter.init(&duplicate_event_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(duplicate_event_writer.writer(), &duplicate_event));

    var invalid_update_column = QailCmd.createTrigger("touch_users_updated");
    invalid_update_column.payload = "BEFORE UPDATE OF bad-name ON users EXECUTE FUNCTION touch_users()";
    var invalid_update_column_buf: [512]u8 = undefined;
    var invalid_update_column_writer = io.FixedBufferWriter.init(&invalid_update_column_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(invalid_update_column_writer.writer(), &invalid_update_column));

    var invalid_table = QailCmd.createTrigger("touch_users_updated");
    invalid_table.payload = "BEFORE UPDATE ON bad-table EXECUTE FUNCTION touch_users()";
    var invalid_table_buf: [512]u8 = undefined;
    var invalid_table_writer = io.FixedBufferWriter.init(&invalid_table_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(invalid_table_writer.writer(), &invalid_table));

    var trailing_trigger = QailCmd.createTrigger("touch_users_updated");
    trailing_trigger.payload = "BEFORE UPDATE ON users EXECUTE FUNCTION touch_users() garbage";
    var trailing_trigger_buf: [512]u8 = undefined;
    var trailing_trigger_writer = io.FixedBufferWriter.init(&trailing_trigger_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(trailing_trigger_writer.writer(), &trailing_trigger));
}

test "ast encoder explain analyze" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var cmd = QailCmd{
        .kind = .explain_analyze,
        .table = "users",
    };

    try encoder.encodeQuery(&cmd);
    const bytes = encoder.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "EXPLAIN ANALYZE SELECT * FROM users") != null);
}

test "ast encoder grant and revoke" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const privs = [_][]const u8{ "SELECT", "INSERT" };
    const grant_cmd = QailCmd.grant("users", &privs, "app_role");
    try encoder.encodeQuery(&grant_cmd);
    try std.testing.expect(std.mem.indexOf(u8, encoder.getWritten(), "GRANT SELECT, INSERT ON users TO app_role") != null);

    const revoke_cmd = QailCmd.revoke("users", &privs, "app_role");
    try encoder.encodeQuery(&revoke_cmd);
    try std.testing.expect(std.mem.indexOf(u8, encoder.getWritten(), "REVOKE SELECT, INSERT ON users FROM app_role") != null);
}

test "ast encoder grant privileges are canonicalized and validated" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const privs = [_][]const u8{ "select", "all privileges", "temp" };
    const grant_cmd = QailCmd.grant("users", &privs, "app_role");

    var sql_buf: [256]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &grant_cmd);
    try std.testing.expectEqualStrings(
        "GRANT SELECT, ALL PRIVILEGES, TEMPORARY ON users TO app_role",
        writer.getWritten(),
    );

    const object_privs = [_][]const u8{"select"};
    const qualified_grant = QailCmd.grant("public.users", &object_privs, "app_role");
    var qualified_buf: [256]u8 = undefined;
    var qualified_writer = io.FixedBufferWriter.init(&qualified_buf);
    try encoder.writeAstToSql(qualified_writer.writer(), &qualified_grant);
    try std.testing.expectEqualStrings("GRANT SELECT ON public.users TO app_role", qualified_writer.getWritten());

    const bad_privs = [_][]const u8{"UPDATE; DROP TABLE users; --"};
    const bad_revoke = QailCmd.revoke("users", &bad_privs, "app_role");
    var bad_buf: [256]u8 = undefined;
    var bad_writer = io.FixedBufferWriter.init(&bad_buf);
    try std.testing.expectError(error.InvalidGrantPrivilege, encoder.writeAstToSql(bad_writer.writer(), &bad_revoke));
}

test "ast encoder escapes notify payload" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const cmd = QailCmd.notifyChannel("events", "x'); DROP TABLE users; --");

    var sql_buf: [256]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "NOTIFY events, 'x''); DROP TABLE users; --'",
        writer.getWritten(),
    );
}

test "ast encoder quotes pubsub channels and savepoints defensively" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const notify_cmd = QailCmd.notifyChannel("events; DROP TABLE users; --", "ok");
    var notify_buf: [256]u8 = undefined;
    var notify_writer = io.FixedBufferWriter.init(&notify_buf);
    try encoder.writeAstToSql(notify_writer.writer(), &notify_cmd);
    try std.testing.expectEqualStrings(
        "NOTIFY \"events; DROP TABLE users; --\", 'ok'",
        notify_writer.getWritten(),
    );

    const savepoint_cmd = QailCmd.savepoint("sp; DROP TABLE users; --");
    var savepoint_buf: [256]u8 = undefined;
    var savepoint_writer = io.FixedBufferWriter.init(&savepoint_buf);
    try encoder.writeAstToSql(savepoint_writer.writer(), &savepoint_cmd);
    try std.testing.expectEqualStrings(
        "SAVEPOINT \"sp; DROP TABLE users; --\"",
        savepoint_writer.getWritten(),
    );
}

test "ast encoder rejects invalid pubsub channels and savepoints" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var listen_buf: [128]u8 = undefined;
    var listen_writer = io.FixedBufferWriter.init(&listen_buf);
    try std.testing.expectError(
        error.InvalidIdentifier,
        encoder.writeAstToSql(listen_writer.writer(), &QailCmd.listen("")),
    );

    var notify_buf: [128]u8 = undefined;
    var notify_writer = io.FixedBufferWriter.init(&notify_buf);
    try std.testing.expectError(
        error.InvalidIdentifier,
        encoder.writeAstToSql(notify_writer.writer(), &QailCmd.notifyChannel("bad\x00channel", "ok")),
    );

    var unlisten_buf: [128]u8 = undefined;
    var unlisten_writer = io.FixedBufferWriter.init(&unlisten_buf);
    try std.testing.expectError(
        error.InvalidIdentifier,
        encoder.writeAstToSql(unlisten_writer.writer(), &QailCmd.unlisten("")),
    );

    var savepoint_buf: [128]u8 = undefined;
    var savepoint_writer = io.FixedBufferWriter.init(&savepoint_buf);
    try std.testing.expectError(
        error.InvalidIdentifier,
        encoder.writeAstToSql(savepoint_writer.writer(), &QailCmd.savepoint("sp\x00shadow")),
    );

    var release_buf: [128]u8 = undefined;
    var release_writer = io.FixedBufferWriter.init(&release_buf);
    try std.testing.expectError(
        error.InvalidIdentifier,
        encoder.writeAstToSql(release_writer.writer(), &QailCmd.releaseSavepoint("")),
    );

    var rollback_buf: [128]u8 = undefined;
    var rollback_writer = io.FixedBufferWriter.init(&rollback_buf);
    try std.testing.expectError(
        error.InvalidIdentifier,
        encoder.writeAstToSql(rollback_writer.writer(), &QailCmd.rollbackTo("sp\x00shadow")),
    );
}

test "ast encoder hardens ddl identifier lists and constrained fragments" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const make_cmd = QailCmd.make("users; DROP TABLE users; --");
    var make_buf: [256]u8 = undefined;
    var make_writer = io.FixedBufferWriter.init(&make_buf);
    try encoder.writeAstToSql(make_writer.writer(), &make_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS \"users; DROP TABLE users; --\"",
        make_writer.getWritten(),
    );

    const idx = ast.cmd.IndexDef{
        .name = "idx_users_name",
        .table = "users",
        .columns = &.{"name; DROP TABLE users; --"},
    };
    const index_cmd = QailCmd.createIndex("users").withIndex(idx);
    var index_buf: [256]u8 = undefined;
    var index_writer = io.FixedBufferWriter.init(&index_buf);
    try encoder.writeAstToSql(index_writer.writer(), &index_cmd);
    try std.testing.expectEqualStrings(
        "CREATE INDEX idx_users_name ON users (/* ERROR: Invalid identifier */)",
        index_writer.getWritten(),
    );

    const rich_idx = ast.cmd.IndexDef{
        .name = "idx_users_active_email",
        .table = "users",
        .columns = &.{ "email", "created_at DESC NULLS LAST", "embedding vector_l2_ops" },
        .unique = true,
        .index_type = "gin",
        .include = &.{ "name", "created_at" },
        .concurrently = true,
        .where_clause = "deleted_at IS NULL",
    };
    const rich_index_cmd = QailCmd.createIndex("users").withIndex(rich_idx);
    var rich_index_buf: [512]u8 = undefined;
    var rich_index_writer = io.FixedBufferWriter.init(&rich_index_buf);
    try encoder.writeAstToSql(rich_index_writer.writer(), &rich_index_cmd);
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX CONCURRENTLY idx_users_active_email ON users USING gin (email, created_at DESC NULLS LAST, embedding vector_l2_ops) INCLUDE (name, created_at) WHERE deleted_at IS NULL",
        rich_index_writer.getWritten(),
    );

    const expr_idx = ast.cmd.IndexDef{
        .name = "idx_users_lower_email",
        .table = "users",
        .columns = &.{"lower(email)"},
    };
    const expr_index_cmd = QailCmd.createIndex("users").withIndex(expr_idx);
    var expr_index_buf: [256]u8 = undefined;
    var expr_index_writer = io.FixedBufferWriter.init(&expr_index_buf);
    try encoder.writeAstToSql(expr_index_writer.writer(), &expr_index_cmd);
    try std.testing.expectEqualStrings(
        "CREATE INDEX idx_users_lower_email ON users (/* ERROR: Invalid identifier */)",
        expr_index_writer.getWritten(),
    );

    var enum_cmd = QailCmd{ .kind = .create_enum, .table = "mood", .payload = "'semi;inside', 'sad'" };
    var enum_buf: [256]u8 = undefined;
    var enum_writer = io.FixedBufferWriter.init(&enum_buf);
    try encoder.writeAstToSql(enum_writer.writer(), &enum_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TYPE mood AS ENUM ('semi;inside', 'sad')",
        enum_writer.getWritten(),
    );

    var unsafe_enum = QailCmd{ .kind = .create_enum, .table = "mood", .payload = "'ok'); DROP TABLE users; --" };
    var unsafe_enum_buf: [256]u8 = undefined;
    var unsafe_enum_writer = io.FixedBufferWriter.init(&unsafe_enum_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(unsafe_enum_writer.writer(), &unsafe_enum));

    var lock_cmd = QailCmd.lockTable("users");
    lock_cmd.payload = "ACCESS EXCLUSIVE";
    var lock_buf: [256]u8 = undefined;
    var lock_writer = io.FixedBufferWriter.init(&lock_buf);
    try encoder.writeAstToSql(lock_writer.writer(), &lock_cmd);
    try std.testing.expectEqualStrings(
        "LOCK TABLE users ACCESS EXCLUSIVE MODE",
        lock_writer.getWritten(),
    );

    var unsafe_lock = QailCmd.lockTable("users");
    unsafe_lock.payload = "ACCESS EXCLUSIVE; DROP TABLE users; --";
    var unsafe_lock_buf: [256]u8 = undefined;
    var unsafe_lock_writer = io.FixedBufferWriter.init(&unsafe_lock_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(unsafe_lock_writer.writer(), &unsafe_lock));
}

test "ast encoder create and drop database quote hyphenated names" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const create_cmd = QailCmd.createDatabase("qail-engine-db_shadow");
    try encoder.encodeQuery(&create_cmd);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoder.getWritten(),
        "CREATE DATABASE \"qail-engine-db_shadow\"",
    ) != null);

    const drop_cmd = QailCmd.dropDatabase("qail-engine-db_shadow");
    try encoder.encodeQuery(&drop_cmd);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoder.getWritten(),
        "DROP DATABASE IF EXISTS \"qail-engine-db_shadow\"",
    ) != null);
}

test "ast encoder create and drop policy" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const policy = ast.trusted_policy_sql.usingAndCheckSql(
        ast.cmd.PolicyDef.create("orders_tenant_isolation", "orders")
            .restrictive()
            .toRole("app_user"),
        "tenant_id = current_setting('app.tenant_id')::uuid",
        "tenant_id = current_setting('app.tenant_id')::uuid",
    );

    const create_cmd = QailCmd.createPolicy(policy);
    try encoder.encodeQuery(&create_cmd);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoder.getWritten(),
        "CREATE POLICY orders_tenant_isolation ON orders AS RESTRICTIVE FOR ALL TO app_user USING (tenant_id = current_setting('app.tenant_id')::uuid) WITH CHECK (tenant_id = current_setting('app.tenant_id')::uuid)",
    ) != null);

    const drop_cmd = QailCmd.dropPolicy("orders_tenant_isolation", "orders");
    try encoder.encodeQuery(&drop_cmd);
    try std.testing.expect(std.mem.indexOf(u8, encoder.getWritten(), "DROP POLICY IF EXISTS orders_tenant_isolation ON orders") != null);
}

test "ast encoder create policy with typed predicates" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = ast.cmd.PolicyDef.create("orders_tenant_isolation", "orders")
        .restrictive()
        .toRole("app_user")
        .usingExpr(predicate)
        .withCheckExpr(predicate);
    const create_cmd = QailCmd.createPolicy(policy);

    try encoder.encodeQuery(&create_cmd);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoder.getWritten(),
        "CREATE POLICY orders_tenant_isolation ON orders AS RESTRICTIVE FOR ALL TO app_user USING (tenant_id = 42) WITH CHECK (tenant_id = 42)",
    ) != null);
}

test "ast encoder quotes cte and policy identifiers defensively" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const source_cols = [_]Expr{Expr.col("id")};
    const source = QailCmd.get("users").select(&source_cols);
    const cte_columns = [_][]const u8{"id; DROP TABLE users; --"};
    const ctes = [_]ast.cmd.CTEDef{ast.cmd.CTEDef.fromQueryColumns(
        "active; DROP TABLE users; --",
        &cte_columns,
        &source,
    )};
    const cmd = QailCmd.get("active; DROP TABLE users; --").withCtes(&ctes);
    var cte_buf: [512]u8 = undefined;
    var cte_writer = io.FixedBufferWriter.init(&cte_buf);
    try encoder.writeAstToSql(cte_writer.writer(), &cmd);
    try std.testing.expectEqualStrings(
        "WITH \"active; DROP TABLE users; --\"(\"id; DROP TABLE users; --\") AS (SELECT id FROM users) SELECT * FROM \"active; DROP TABLE users; --\"",
        cte_writer.getWritten(),
    );

    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = ast.cmd.PolicyDef.create(
        "tenant; DROP TABLE users; --",
        "orders; DROP TABLE orders; --",
    )
        .toRole("app; DROP ROLE app; --")
        .usingExpr(predicate);
    const policy_cmd = QailCmd.createPolicy(policy);
    var policy_buf: [512]u8 = undefined;
    var policy_writer = io.FixedBufferWriter.init(&policy_buf);
    try encoder.writeAstToSql(policy_writer.writer(), &policy_cmd);
    try std.testing.expectEqualStrings(
        "CREATE POLICY \"tenant; DROP TABLE users; --\" ON \"orders; DROP TABLE orders; --\" FOR ALL TO \"app; DROP ROLE app; --\" USING (tenant_id = 42)",
        policy_writer.getWritten(),
    );

    const drop_cmd = QailCmd.dropPolicy("tenant; DROP TABLE users; --", "orders; DROP TABLE orders; --");
    var drop_buf: [256]u8 = undefined;
    var drop_writer = io.FixedBufferWriter.init(&drop_buf);
    try encoder.writeAstToSql(drop_writer.writer(), &drop_cmd);
    try std.testing.expectEqualStrings(
        "DROP POLICY IF EXISTS \"tenant; DROP TABLE users; --\" ON \"orders; DROP TABLE orders; --\"",
        drop_writer.getWritten(),
    );
}

test "ast encoder merge renders update and insert clauses" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const on = [_]ast.expr.Condition{.{
        .left = Expr.col("u.id"),
        .op = .eq,
        .value = Value.fromColumn("s.id"),
    }};
    const update_assignments = [_]ast.cmd.MergeAssignment{.{
        .column = "name",
        .expr = Expr.col("s.name"),
    }};
    const insert_values = [_]Expr{ Expr.col("s.id"), Expr.col("s.name") };
    const clauses = [_]ast.cmd.MergeClause{
        .{
            .match_kind = .matched,
            .action = .{ .update = &update_assignments },
        },
        .{
            .match_kind = .not_matched_by_target,
            .action = .{ .insert = .{
                .columns = &.{ "id", "name" },
                .values = &insert_values,
            } },
        },
    };
    const merge = ast.cmd.Merge{
        .target_alias = "u",
        .source = ast.cmd.MergeSource.fromTableAs("staging_users", "s"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("users").withMerge(merge);

    var sql_buf: [1024]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "MERGE INTO users AS u USING staging_users AS s ON u.id = s.id WHEN MATCHED THEN UPDATE SET name = s.name WHEN NOT MATCHED BY TARGET THEN INSERT (id, name) VALUES (s.id, s.name)",
        writer.getWritten(),
    );
}

test "ast encoder merge renders table references defensively" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const on = [_]ast.expr.Condition{.{
        .left = Expr.col("u.id"),
        .op = .eq,
        .value = Value.fromColumn("s.id"),
    }};
    const clauses = [_]ast.cmd.MergeClause{.{
        .match_kind = .not_matched_by_target,
        .action = .do_nothing,
    }};
    const merge = ast.cmd.Merge{
        .target_alias = "u",
        .source = ast.cmd.MergeSource.fromTable("public.staging_users s"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("users; DROP TABLE users; --").withMerge(merge);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "MERGE INTO \"users; DROP TABLE users; --\" AS u USING public.staging_users s ON u.id = s.id WHEN NOT MATCHED BY TARGET THEN DO NOTHING",
        writer.getWritten(),
    );
}

test "ast encoder merge resolves schema-qualified aliases" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const on = [_]ast.expr.Condition{.{
        .left = Expr.col("public.orders.id"),
        .op = .eq,
        .value = Value.fromColumn("staging.orders.order_id"),
    }};
    const update_assignments = [_]ast.cmd.MergeAssignment{.{
        .column = "status",
        .expr = Expr.col("staging.orders.status"),
    }};
    const insert_values = [_]Expr{
        Expr.col("staging.orders.id"),
        Expr.col("staging.orders.status"),
    };
    const clauses = [_]ast.cmd.MergeClause{
        .{
            .match_kind = .matched,
            .action = .{ .update = &update_assignments },
        },
        .{
            .match_kind = .not_matched_by_target,
            .action = .{ .insert = .{
                .columns = &.{ "id", "status" },
                .values = &insert_values,
            } },
        },
    };
    const returning = [_]Expr{Expr.col("public.orders.id")};
    const merge = ast.cmd.Merge{
        .target_alias = "o",
        .source = ast.cmd.MergeSource.fromTableAs("staging.orders", "s"),
        .on = &on,
        .clauses = &clauses,
    };
    var cmd = QailCmd.mergeInto("public.orders").withMerge(merge);
    cmd.returning = &returning;

    var sql_buf: [1024]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "MERGE INTO public.orders AS o USING staging.orders AS s ON o.id = s.order_id WHEN MATCHED THEN UPDATE SET status = s.status WHEN NOT MATCHED BY TARGET THEN INSERT (id, status) VALUES (s.id, s.status) RETURNING o.id",
        writer.getWritten(),
    );
}

test "ast encoder merge rejects invalid action shape" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const on = [_]ast.expr.Condition{.{
        .left = Expr.col("users.id"),
        .op = .eq,
        .value = Value.fromColumn("s.id"),
    }};
    const values = [_]Expr{Expr.col("s.id")};
    const clauses = [_]ast.cmd.MergeClause{.{
        .match_kind = .matched,
        .action = .{ .insert = .{
            .columns = &.{"id"},
            .values = &values,
        } },
    }};
    const merge = ast.cmd.Merge{
        .source = ast.cmd.MergeSource.fromTableAs("staging_users", "s"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("users").withMerge(merge);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try std.testing.expectError(error.InvalidMergeActionShape, encoder.writeAstToSql(writer.writer(), &cmd));
}

test "ast encoder alter constraint checks expression fragments" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const safe = QailCmd.alterAddConstraint("events", "events_kind_check", "kind <> 'semi;inside'");
    var sql_buf: [256]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &safe);
    try std.testing.expectEqualStrings(
        "ALTER TABLE events ADD CONSTRAINT events_kind_check CHECK (kind <> 'semi;inside')",
        writer.getWritten(),
    );

    const unsafe = QailCmd.alterAddConstraint("users", "users_active_check", "active); DROP TABLE users; --");
    var bad_buf: [256]u8 = undefined;
    var bad_writer = io.FixedBufferWriter.init(&bad_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(bad_writer.writer(), &unsafe));
}

test "ast encoder condition shape operators render safely" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const roles = [_]Value{ Value.fromString("admin"), Value.fromString("user") };
    const wheres = [_]ast.cmd.WhereClause{
        .{
            .condition = .{
                .column = "role",
                .op = .in,
                .value = .{ .array = &roles },
            },
        },
        .{
            .condition = .{
                .column = "age",
                .op = .not_between,
                .value = .{ .range = .{ .low = 18, .high = 65 } },
            },
        },
    };
    const cmd = QailCmd.get("users").where(&wheres);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE role IN ('admin', 'user') AND age NOT BETWEEN 18 AND 65",
        writer.getWritten(),
    );
}

test "ast encoder in parameters use array operators" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const wheres = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .in,
            .value = .{ .param = 1 },
        },
    }};
    const cmd = QailCmd.get("users").where(&wheres);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE id = ANY($1)",
        writer.getWritten(),
    );

    const named_wheres = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "role",
            .op = .not_in,
            .value = .{ .named_param = "roles" },
        },
    }};
    const named_cmd = QailCmd.get("users").where(&named_wheres);

    var named_buf: [256]u8 = undefined;
    var named_writer = io.FixedBufferWriter.init(&named_buf);
    try std.testing.expectError(error.UnresolvedNamedParameter, encoder.writeAstToSql(named_writer.writer(), &named_cmd));
}

test "ast encoder malformed condition shapes fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const empty = [_]Value{};
    const empty_in = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "role",
            .op = .not_in,
            .value = .{ .array = &empty },
        },
    }};
    const empty_in_cmd = QailCmd.get("users").where(&empty_in);

    var in_buf: [256]u8 = undefined;
    var in_writer = io.FixedBufferWriter.init(&in_buf);
    try std.testing.expectError(error.InvalidInCondition, encoder.writeAstToSql(in_writer.writer(), &empty_in_cmd));

    const bad_exists = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .exists,
            .value = .{ .int = 1 },
        },
    }};
    const bad_exists_cmd = QailCmd.get("users").where(&bad_exists);

    var exists_buf: [256]u8 = undefined;
    var exists_writer = io.FixedBufferWriter.init(&exists_buf);
    try std.testing.expectError(error.InvalidExistsCondition, encoder.writeAstToSql(exists_writer.writer(), &bad_exists_cmd));

    const one_between_value = [_]Value{Value.fromInt(1)};
    const bad_between = [_]ast.cmd.WhereClause{.{
        .condition = .{
            .column = "age",
            .op = .between,
            .value = .{ .array = &one_between_value },
        },
    }};
    const bad_between_cmd = QailCmd.get("users").where(&bad_between);

    var between_buf: [256]u8 = undefined;
    var between_writer = io.FixedBufferWriter.init(&between_buf);
    try std.testing.expectError(error.InvalidBetweenCondition, encoder.writeAstToSql(between_writer.writer(), &bad_between_cmd));
}

test "ast encoder expression fragments fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const name = Expr.col("name");
    const bad_function_cols = [_]Expr{.{ .func_call = .{
        .name = "lower); DROP TABLE users; --",
        .args = &[_]Expr{name},
    } }};
    const bad_function_cmd = QailCmd.get("users").select(&bad_function_cols);

    var function_buf: [256]u8 = undefined;
    var function_writer = io.FixedBufferWriter.init(&function_buf);
    try encoder.writeAstToSql(function_writer.writer(), &bad_function_cmd);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid function name */ FROM users",
        function_writer.getWritten(),
    );

    const bad_cast_cols = [_]Expr{.{ .cast = .{
        .expr = &name,
        .target_type = "text); DROP TABLE users; --",
    } }};
    const bad_cast_cmd = QailCmd.get("users").select(&bad_cast_cols);

    var cast_buf: [256]u8 = undefined;
    var cast_writer = io.FixedBufferWriter.init(&cast_buf);
    try encoder.writeAstToSql(cast_writer.writer(), &bad_cast_cmd);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid cast target type */ FROM users",
        cast_writer.getWritten(),
    );

    const raw_cols = [_]Expr{.{ .raw = "pg_sleep(1); DROP TABLE users; --" }};
    const raw_cmd = QailCmd.get("users").select(&raw_cols);
    var raw_buf: [256]u8 = undefined;
    var raw_writer = io.FixedBufferWriter.init(&raw_buf);
    try encoder.writeAstToSql(raw_writer.writer(), &raw_cmd);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid raw SQL fragment */ FROM users",
        raw_writer.getWritten(),
    );

    const unsafe_value_cols = [_]Expr{.{ .literal = .{ .function = "now(); DROP TABLE users; --" } }};
    const unsafe_value_cmd = QailCmd.get("users").select(&unsafe_value_cols);
    var unsafe_value_buf: [256]u8 = undefined;
    var unsafe_value_writer = io.FixedBufferWriter.init(&unsafe_value_buf);
    try std.testing.expectError(error.UnsafeSqlFragment, encoder.writeAstToSql(unsafe_value_writer.writer(), &unsafe_value_cmd));

    const nul_value_cols = [_]Expr{.{ .literal = .{ .string = "bad\x00value" } }};
    const nul_value_cmd = QailCmd.get("users").select(&nul_value_cols);
    var nul_value_buf: [256]u8 = undefined;
    var nul_value_writer = io.FixedBufferWriter.init(&nul_value_buf);
    try std.testing.expectError(error.NullByte, encoder.writeAstToSql(nul_value_writer.writer(), &nul_value_cmd));

    const safe_subquery_cols = [_]Expr{.{ .subquery = .{
        .sql = "SELECT count(*) FROM pg_class",
        .alias = "class_count",
    } }};
    const safe_subquery_cmd = QailCmd.get("users").select(&safe_subquery_cols);
    var safe_subquery_buf: [256]u8 = undefined;
    var safe_subquery_writer = io.FixedBufferWriter.init(&safe_subquery_buf);
    try encoder.writeAstToSql(safe_subquery_writer.writer(), &safe_subquery_cmd);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT count(*) FROM pg_class) AS class_count FROM users",
        safe_subquery_writer.getWritten(),
    );

    const subquery_cols = [_]Expr{.{ .subquery = .{
        .sql = "SELECT 1; DROP TABLE users; --",
        .alias = "safe_alias",
    } }};
    const subquery_cmd = QailCmd.get("users").select(&subquery_cols);
    var subquery_buf: [256]u8 = undefined;
    var subquery_writer = io.FixedBufferWriter.init(&subquery_buf);
    try encoder.writeAstToSql(subquery_writer.writer(), &subquery_cmd);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT NULL WHERE FALSE) AS safe_alias FROM users",
        subquery_writer.getWritten(),
    );

    const mutating_subquery_cols = [_]Expr{.{ .subquery = .{
        .sql = "DELETE FROM users RETURNING id",
        .alias = "deleted_id",
    } }};
    const mutating_subquery_cmd = QailCmd.get("users").select(&mutating_subquery_cols);
    var mutating_subquery_buf: [256]u8 = undefined;
    var mutating_subquery_writer = io.FixedBufferWriter.init(&mutating_subquery_buf);
    try encoder.writeAstToSql(mutating_subquery_writer.writer(), &mutating_subquery_cmd);
    try std.testing.expectEqualStrings(
        "SELECT (SELECT NULL WHERE FALSE) AS deleted_id FROM users",
        mutating_subquery_writer.getWritten(),
    );

    const exists_cols = [_]Expr{.{ .exists_subquery = .{
        .sql = "SELECT 1; DROP TABLE users; --",
        .alias = "safe_exists",
    } }};
    const exists_cmd = QailCmd.get("users").select(&exists_cols);
    var exists_buf: [256]u8 = undefined;
    var exists_writer = io.FixedBufferWriter.init(&exists_buf);
    try encoder.writeAstToSql(exists_writer.writer(), &exists_cmd);
    try std.testing.expectEqualStrings(
        "SELECT EXISTS (SELECT NULL WHERE FALSE) AS safe_exists FROM users",
        exists_writer.getWritten(),
    );

    const mutating_cte_exists_cols = [_]Expr{.{ .exists_subquery = .{
        .sql = "WITH deleted AS (DELETE FROM users RETURNING id) SELECT id FROM deleted",
        .alias = "safe_cte",
    } }};
    const mutating_cte_exists_cmd = QailCmd.get("users").select(&mutating_cte_exists_cols);
    var mutating_cte_exists_buf: [256]u8 = undefined;
    var mutating_cte_exists_writer = io.FixedBufferWriter.init(&mutating_cte_exists_buf);
    try encoder.writeAstToSql(mutating_cte_exists_writer.writer(), &mutating_cte_exists_cmd);
    try std.testing.expectEqualStrings(
        "SELECT EXISTS (SELECT NULL WHERE FALSE) AS safe_cte FROM users",
        mutating_cte_exists_writer.getWritten(),
    );
}

test "ast encoder quotes expression identifiers and escapes json paths" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const name = Expr.col("name");
    const profile = Expr.col("profile");
    const cols = [_]Expr{
        Expr.col("name; DROP TABLE users; --"),
        Expr.colAs("email; DROP TABLE users; --", "safe_alias"),
        .{ .aggregate = .{ .func = .sum, .column = "amount; DROP TABLE users; --" } },
        .{ .json_access = .{
            .column = "data; DROP TABLE users; --",
            .path = &[_]ast.expr.JsonPathSegment{.{ .key = "a' || pg_sleep(1) --", .as_text = true }},
        } },
        .{ .collate = .{
            .expr = &name,
            .collation = "C\"; DROP TABLE users; --",
        } },
        .{ .field_access = .{
            .expr = &profile,
            .field = "field; DROP TABLE users; --",
        } },
    };
    const cmd = QailCmd.get("users").select(&cols);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);
    const sql = writer.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, sql, "\"name; DROP TABLE users; --\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"email; DROP TABLE users; --\" AS safe_alias") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SUM(\"amount; DROP TABLE users; --\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"data; DROP TABLE users; --\"->>'a'' || pg_sleep(1) --'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "COLLATE \"C\"\"; DROP TABLE users; --\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, ").\"field; DROP TABLE users; --\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT name; DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "SUM(amount; DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "COLLATE \"C\"; DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, ").field; DROP") == null);
}

test "ast encoder hardens window expressions" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const bad_window_cols = [_]Expr{.{ .window = .{
        .name = "rn",
        .func = "row_number); DROP TABLE users; --",
    } }};
    const bad_window_cmd = QailCmd.get("users").select(&bad_window_cols);

    var bad_buf: [256]u8 = undefined;
    var bad_writer = io.FixedBufferWriter.init(&bad_buf);
    try encoder.writeAstToSql(bad_writer.writer(), &bad_window_cmd);
    try std.testing.expectEqualStrings(
        "SELECT /* ERROR: Invalid window function name */ FROM users",
        bad_writer.getWritten(),
    );

    const window_cols = [_]Expr{.{ .window = .{
        .name = "rn",
        .func = "row_number",
        .partition = &.{"tenant.id"},
        .order = &[_]ast.expr.OrderByExpr{.{ .column = "name\"; DROP TABLE users; --" }},
    } }};
    const window_cmd = QailCmd.get("users").select(&window_cols);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &window_cmd);
    try std.testing.expectEqualStrings(
        "SELECT row_number() OVER (PARTITION BY tenant.id ORDER BY \"name\"\"; DROP TABLE users; --\" ASC) AS rn FROM users",
        writer.getWritten(),
    );
}

test "ast encoder privilege and policy validation" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var grant_missing_role = QailCmd{
        .kind = .grant,
        .table = "users",
    };
    try std.testing.expectError(error.MissingGrantRole, encoder.encodeQuery(&grant_missing_role));

    var grant_missing_privileges = QailCmd{
        .kind = .grant,
        .table = "users",
        .payload = "app_role",
    };
    try std.testing.expectError(error.MissingGrantPrivileges, encoder.encodeQuery(&grant_missing_privileges));

    const drop_missing_table = QailCmd{
        .kind = .drop_policy,
        .payload = "orders_tenant_isolation",
    };
    try std.testing.expectError(error.MissingPolicyTable, encoder.encodeQuery(&drop_missing_table));

    const create_missing_def = QailCmd{
        .kind = .create_policy,
    };
    try std.testing.expectError(error.MissingPolicyDefinition, encoder.encodeQuery(&create_missing_def));
}

test "ast encoder rejects non-postgres command without raw sql" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    var cmd = QailCmd{
        .kind = .create_collection,
        .table = "vec_docs",
    };

    try std.testing.expectError(error.UnsupportedCommandForPostgres, encoder.encodeQuery(&cmd));
}

test "ast encoder prepare named rejects oversized sql payload" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_sql = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.MessageTooLarge, encoder.encodePrepareNamed("stmt", huge_sql));
}

test "ast encoder execute named rejects oversized parameter payload" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_param = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];
    const params = [_]?[]const u8{huge_param};

    try std.testing.expectError(error.MessageTooLarge, encoder.executeNamedStatement("stmt", &params));
}

test "ast encoder rejects embedded nul in rendered sql cstring" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const where = [_]ast.cmd.WhereClause{
        .{
            .condition = .{
                .column = "datname",
                .op = .eq,
                .value = .{ .string = "po\x00stgres" },
            },
        },
    };
    const cmd = QailCmd.get("pg_database")
        .select(&.{Expr.col("datname")})
        .where(&where)
        .limit(1);

    try std.testing.expectError(error.NullByte, encoder.encodeQuery(&cmd));
}

test "ast encoder rejects non-finite value rendering" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const assigns = [_]ast.cmd.Assignment{
        .{ .column = "score", .value = .{ .float = std.math.inf(f64) } },
    };
    const cmd = QailCmd.add("events").values(&assigns);

    try std.testing.expectError(error.NonFiniteSqlValue, encoder.encodeQuery(&cmd));
}
