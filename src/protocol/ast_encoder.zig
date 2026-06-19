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
const ColumnDef = @TypeOf(@as(Expr, undefined).column_def);
const WindowExpr = @TypeOf(@as(Expr, undefined).window);
const FrontendMessage = wire.FrontendMessage;
const PROTOCOL_VERSION = wire.PROTOCOL_VERSION;
const max_wire_message_len: usize = std.math.maxInt(i32);

const INVALID_EXISTS_CONDITION =
    "FALSE /* ERROR: EXISTS condition requires subquery value */";
const INVALID_IN_CONDITION =
    "FALSE /* ERROR: IN condition requires a non-empty array, subquery, or array parameter */";
const INVALID_BETWEEN_CONDITION =
    "FALSE /* ERROR: BETWEEN condition requires exactly two array values */";
const INVALID_FUNCTION_NAME = "/* ERROR: Invalid function name */";
const INVALID_FUNCTION_KEYWORD = "/* ERROR: Invalid function keyword */";
const INVALID_WINDOW_FUNCTION_NAME = "/* ERROR: Invalid window function name */";
const INVALID_CAST_TARGET = "/* ERROR: Invalid cast target type */";
const INVALID_IDENTIFIER = "/* ERROR: Invalid identifier */";
const INVALID_INSERT_COLUMN = "/* ERROR: Invalid insert column */";
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

        // First check for raw_sql (used for pre-generated DDL)
        if (cmd.raw_sql) |raw| {
            try writer.writeAll(raw);
            return;
        }

        switch (cmd.kind) {
            .get => try writeSelect(writer, cmd, false),
            .with => try writeSelect(writer, cmd, false),
            .cnt => try writeSelect(writer, cmd, true),
            .set => {
                try writer.writeAll("UPDATE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" SET ");

                for (cmd.assignments, 0..) |assign, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writeIdentifierOrError(writer, assign.column);
                    try writer.writeAll(" = ");
                    try writeValue(writer, &assign.value);
                }

                try writeWhereClauses(writer, cmd.where_clauses);

                if (cmd.returning.len > 0) {
                    try writer.writeAll(" RETURNING ");
                    for (cmd.returning, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                }
            },
            .del => {
                try writer.writeAll("DELETE FROM ");
                try writer.writeAll(cmd.table);

                try writeWhereClauses(writer, cmd.where_clauses);

                if (cmd.returning.len > 0) {
                    try writer.writeAll(" RETURNING ");
                    for (cmd.returning, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                }
            },
            .add => try writeInsertCmd(writer, cmd, false),
            .put, .upsert => try writeInsertCmd(writer, cmd, true),
            .merge => try writeMerge(writer, cmd),
            .truncate => {
                try writer.writeAll("TRUNCATE ");
                try writer.writeAll(cmd.table);
            },
            .listen => {
                try writer.writeAll("LISTEN ");
                if (cmd.channel) |ch| try writer.writeAll(ch);
            },
            .notify => {
                try writer.writeAll("NOTIFY ");
                if (cmd.channel) |ch| try writer.writeAll(ch);
                if (cmd.payload) |p| {
                    try writer.writeAll(", '");
                    try writeEscapedSqlString(writer, p);
                    try writer.writeByte('\'');
                }
            },
            .unlisten => {
                try writer.writeAll("UNLISTEN ");
                if (cmd.channel) |ch| {
                    try writer.writeAll(ch);
                } else {
                    try writer.writeByte('*');
                }
            },
            .begin => try writer.writeAll("BEGIN"),
            .commit => try writer.writeAll("COMMIT"),
            .rollback => try writer.writeAll("ROLLBACK"),
            .savepoint => {
                try writer.writeAll("SAVEPOINT ");
                if (cmd.savepoint_name) |name| try writer.writeAll(name);
            },
            .release => {
                try writer.writeAll("RELEASE SAVEPOINT ");
                if (cmd.savepoint_name) |name| try writer.writeAll(name);
            },
            .rollback_to => {
                try writer.writeAll("ROLLBACK TO SAVEPOINT ");
                if (cmd.savepoint_name) |name| try writer.writeAll(name);
            },
            // DDL Commands
            .make => {
                try writer.writeAll("CREATE TABLE IF NOT EXISTS ");
                try writer.writeAll(cmd.table);
                if (cmd.columns.len > 0) {
                    try writer.writeAll(" (");
                    for (cmd.columns, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                    try writer.writeAll(")");
                }
            },
            .drop => {
                try writer.writeAll("DROP TABLE IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .alter => {
                // ALTER TABLE ADD COLUMN
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" ADD COLUMN ");
                    try writeExpr(writer, &col);
                }
            },
            .alter_add_constraint => {
                const name = cmd.channel orelse return error.MissingConstraintName;
                const expr = cmd.payload orelse return error.MissingConstraintExpression;
                if (!isSafeSqlExprFragment(expr)) return error.UnsafeSqlFragment;

                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" ADD CONSTRAINT ");
                try writer.writeAll(name);
                try writer.writeAll(" CHECK (");
                try writer.writeAll(std.mem.trim(u8, expr, " \t\r\n"));
                try writer.writeByte(')');
            },
            .alter_drop_constraint => {
                const name = cmd.channel orelse return error.MissingConstraintName;
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" DROP CONSTRAINT ");
                try writer.writeAll(name);
            },
            .alter_drop => {
                // ALTER TABLE DROP COLUMN
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" DROP COLUMN ");
                    try writeExpr(writer, &col);
                }
            },
            .mod, .alter_type => {
                // ALTER TABLE ALTER COLUMN TYPE
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" ALTER COLUMN ");
                    // Write column name only (not full def)
                    if (col == .column_def) {
                        try writer.writeAll(col.column_def.name);
                        try writer.writeAll(" TYPE ");
                        try writer.writeAll(col.column_def.data_type);
                    } else if (col == .named) {
                        try writer.writeAll(col.named);
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
                    try writer.writeAll(idx.name);
                    try writer.writeAll(" ON ");
                    try writer.writeAll(idx.table);
                    try writer.writeAll(" (");
                    for (idx.columns, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(col);
                    }
                    try writer.writeAll(")");
                }
            },
            .drop_index => {
                try writer.writeAll("DROP INDEX IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .create_view => {
                try writer.writeAll("CREATE VIEW ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" AS ");
                if (cmd.source_query) |source_query| {
                    try writeNestedQueryableCmd(writer, source_query);
                } else if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else {
                    return error.MissingViewSourceQuery;
                }
            },
            .drop_view => {
                try writer.writeAll("DROP VIEW IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .create_materialized_view => {
                try writer.writeAll("CREATE MATERIALIZED VIEW ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" AS ");
                if (cmd.source_query) |source_query| {
                    try writeNestedQueryableCmd(writer, source_query);
                } else if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else {
                    return error.MissingMaterializedViewSourceQuery;
                }
            },
            .refresh_materialized_view => {
                try writer.writeAll("REFRESH MATERIALIZED VIEW ");
                try writer.writeAll(cmd.table);
            },
            .drop_materialized_view => {
                try writer.writeAll("DROP MATERIALIZED VIEW IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .create_function => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else if (cmd.payload) |definition| {
                    try writer.writeAll("CREATE FUNCTION ");
                    try writer.writeAll(cmd.table);
                    try writer.writeAll(" ");
                    try writer.writeAll(definition);
                } else {
                    return error.MissingFunctionDefinition;
                }
            },
            .drop_function => {
                try writer.writeAll("DROP FUNCTION IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .create_trigger => {
                if (cmd.raw_sql) |raw| {
                    try writer.writeAll(raw);
                } else if (cmd.payload) |definition| {
                    try writer.writeAll("CREATE TRIGGER ");
                    try writer.writeAll(cmd.table);
                    try writer.writeByte(' ');
                    try writer.writeAll(definition);
                } else {
                    return error.MissingTriggerDefinition;
                }
            },
            .drop_trigger => {
                try writer.writeAll("DROP TRIGGER IF EXISTS ");
                try writer.writeAll(cmd.table);
                if (cmd.payload) |on_table| {
                    try writer.writeAll(" ON ");
                    try writer.writeAll(on_table);
                }
            },
            .create_extension => {
                try writer.writeAll("CREATE EXTENSION IF NOT EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .drop_extension => {
                try writer.writeAll("DROP EXTENSION IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .create_sequence => {
                try writer.writeAll("CREATE SEQUENCE ");
                try writer.writeAll(cmd.table);
            },
            .drop_sequence => {
                try writer.writeAll("DROP SEQUENCE IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .create_enum => {
                try writer.writeAll("CREATE TYPE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" AS ENUM (");

                if (cmd.insert_values.len > 0) {
                    for (cmd.insert_values, 0..) |val, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeValue(writer, &val);
                    }
                } else if (cmd.payload) |values_sql| {
                    try writer.writeAll(values_sql);
                } else {
                    return error.MissingEnumValues;
                }
                try writer.writeByte(')');
            },
            .drop_enum => {
                try writer.writeAll("DROP TYPE IF EXISTS ");
                try writer.writeAll(cmd.table);
            },
            .alter_enum_add_value => {
                try writer.writeAll("ALTER TYPE ");
                try writer.writeAll(cmd.table);
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
                try writer.writeAll(cmd.table);
                try writer.writeAll(" DROP COLUMN ");
                try writer.writeAll(col_name);
            },
            .rename_col => {
                const from = firstColumnName(cmd) orelse return error.MissingColumnName;
                const to = if (cmd.payload) |p| p else columnNameAt(cmd, 1) orelse return error.MissingRenameTarget;
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" RENAME COLUMN ");
                try writer.writeAll(from);
                try writer.writeAll(" TO ");
                try writer.writeAll(to);
            },
            .copy_out => {
                try writer.writeAll("COPY (");
                try writeSelect(writer, cmd, false);
                try writer.writeAll(") TO STDOUT");
            },
            .lock_table => {
                try writer.writeAll("LOCK TABLE ");
                try writer.writeAll(cmd.table);
                if (cmd.table_lock_mode) |mode| {
                    try writer.writeByte(' ');
                    try writer.writeAll(mode.toSql());
                } else if (cmd.payload) |mode| {
                    try writer.writeByte(' ');
                    try writer.writeAll(mode);
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
                    try writer.writeAll(cmd.table);
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
                    try writer.writeAll(cmd.table);
                } else {
                    return error.MissingExplainQuery;
                }
            },
            .comment_on => {
                try writer.writeAll("COMMENT ON ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" IS ");
                if (cmd.payload) |comment| {
                    try writer.writeByte('\'');
                    try writeEscapedSqlString(writer, comment);
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
                    try writer.writeAll(cmd.table);
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
                try writer.writeAll(cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writer.writeAll(col_name);
                try writer.writeAll(" SET NOT NULL");
            },
            .alter_drop_not_null => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writer.writeAll(col_name);
                try writer.writeAll(" DROP NOT NULL");
            },
            .alter_set_default => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writer.writeAll(col_name);
                try writer.writeAll(" SET DEFAULT ");
                try writer.writeAll(cmd.payload orelse "NULL");
            },
            .alter_drop_default => {
                const col_name = firstColumnName(cmd) orelse return error.MissingColumnName;
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" ALTER COLUMN ");
                try writer.writeAll(col_name);
                try writer.writeAll(" DROP DEFAULT");
            },
            .alter_enable_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" ENABLE ROW LEVEL SECURITY");
            },
            .alter_disable_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" DISABLE ROW LEVEL SECURITY");
            },
            .alter_force_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" FORCE ROW LEVEL SECURITY");
            },
            .alter_no_force_rls => {
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" NO FORCE ROW LEVEL SECURITY");
            },
            .call => {
                try writer.writeAll("CALL ");
                try writer.writeAll(cmd.table);
            },
            .do_block => {
                const lang = if (cmd.table.len == 0) "plpgsql" else cmd.table;
                try writer.writeAll("DO $$ ");
                try writer.writeAll(cmd.payload orelse "");
                try writer.writeAll(" $$ LANGUAGE ");
                try writer.writeAll(lang);
            },
            .session_set => {
                try writer.writeAll("SET ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" = '");
                try writeEscapedSqlString(writer, cmd.payload orelse "");
                try writer.writeByte('\'');
            },
            .session_show => {
                try writer.writeAll("SHOW ");
                try writer.writeAll(cmd.table);
            },
            .session_reset => {
                try writer.writeAll("RESET ");
                try writer.writeAll(cmd.table);
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
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(privilege);
                }
                try writer.writeAll(" ON ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" TO ");
                try writer.writeAll(role);
            },
            .revoke => {
                const role = cmd.payload orelse return error.MissingRevokeRole;
                if (cmd.table.len == 0) return error.MissingRevokeObject;
                if (cmd.privileges.len == 0) return error.MissingRevokePrivileges;

                try writer.writeAll("REVOKE ");
                for (cmd.privileges, 0..) |privilege, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(privilege);
                }
                try writer.writeAll(" ON ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" FROM ");
                try writer.writeAll(role);
            },
            .create_policy => {
                const policy = cmd.policy_def orelse return error.MissingPolicyDefinition;
                if (policy.name.len == 0) return error.MissingPolicyName;
                if (policy.table.len == 0) return error.MissingPolicyTable;

                try writer.writeAll("CREATE POLICY ");
                try writer.writeAll(policy.name);
                try writer.writeAll(" ON ");
                try writer.writeAll(policy.table);

                if (policy.permissiveness == .restrictive) {
                    try writer.writeAll(" AS RESTRICTIVE");
                }

                try writer.writeAll(" FOR ");
                try writer.writeAll(policy.target.toSql());

                if (policy.role) |role| {
                    try writer.writeAll(" TO ");
                    try writer.writeAll(role);
                }

                if (policy.using_expr) |using_expr| {
                    try writer.writeAll(" USING (");
                    var expr = using_expr;
                    try writeExpr(writer, &expr);
                    try writer.writeByte(')');
                }

                if (policy.with_check_expr) |with_check_expr| {
                    try writer.writeAll(" WITH CHECK (");
                    var expr = with_check_expr;
                    try writeExpr(writer, &expr);
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
                try writer.writeAll(policy_name);
                try writer.writeAll(" ON ");
                try writer.writeAll(policy_table);
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
            try writeExpr(writer, &col);
        }
    }

    if (cmd.only_table) {
        try writer.writeAll(" FROM ONLY ");
    } else {
        try writer.writeAll(" FROM ");
    }
    try writer.writeAll(cmd.table);

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
        try writer.writeAll(alias);
    }

    for (cmd.joins) |join| {
        try writer.print(" {s} ", .{join.kind.toSql()});
        try writer.writeAll(join.table);
        if (join.alias) |alias| {
            try writer.writeAll(" AS ");
            try writer.writeAll(alias);
        }
        try writer.writeAll(" ON ");
        try writer.writeAll(join.on_left);
        try writer.writeAll(" = ");
        try writer.writeAll(join.on_right);
    }

    try writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.group_by.len > 0) {
        try writer.writeAll(" GROUP BY ");
        for (cmd.group_by, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(col);
        }
    }

    if (cmd.having_clauses.len > 0) {
        try writer.writeAll(" HAVING ");
        for (cmd.having_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try writeCondition(writer, &clause.condition);
        }
    }

    if (cmd.order_by.len > 0) {
        try writer.writeAll(" ORDER BY ");
        for (cmd.order_by, 0..) |order, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(order.column);
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
    }
}

fn writeNestedQueryableCmd(writer: anytype, cmd: *const QailCmd) anyerror!void {
    return switch (cmd.kind) {
        .get => writeSelect(writer, cmd, false),
        .with => writeSelect(writer, cmd, false),
        .cnt => writeSelect(writer, cmd, true),
        .search => writeSelect(writer, cmd, false),
        .over => writeSelect(writer, cmd, false),
        .raw => try writer.writeAll(cmd.raw_sql orelse return error.MissingNestedRawQuery),
        else => error.UnsupportedNestedQueryCommand,
    };
}

fn writeMerge(writer: anytype, cmd: *const QailCmd) !void {
    const merge = cmd.merge orelse return error.MissingMergeSpec;
    try validateMergeShape(&merge);

    try writeCtePrefix(writer, cmd);

    try writer.writeAll("MERGE INTO ");
    try writer.writeAll(cmd.table);

    if (merge.target_alias) |alias| {
        try writer.writeAll(" AS ");
        try writer.writeAll(alias);
    }

    try writer.writeAll(" USING ");
    try writeMergeSource(writer, &merge.source);

    try writer.writeAll(" ON ");
    try writeConditions(writer, merge.on);

    for (merge.clauses) |clause| {
        try writer.writeAll(" WHEN ");
        switch (clause.match_kind) {
            .matched => try writer.writeAll("MATCHED"),
            .not_matched_by_target => try writer.writeAll("NOT MATCHED BY TARGET"),
            .not_matched_by_source => try writer.writeAll("NOT MATCHED BY SOURCE"),
        }

        if (clause.condition.len > 0) {
            try writer.writeAll(" AND ");
            try writeConditions(writer, clause.condition);
        }

        try writer.writeAll(" THEN ");
        try writeMergeAction(writer, &clause.action);
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeExpr(writer, &col);
        }
    }
}

fn writeMergeSource(writer: anytype, source: *const ast.cmd.MergeSource) !void {
    switch (source.*) {
        .table => |table| {
            try writer.writeAll(table.name);
            if (table.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        .query => |query| {
            try writer.writeByte('(');
            try writeNestedQueryableCmd(writer, query.query);
            try writer.writeByte(')');
            if (query.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
    }
}

fn writeConditions(writer: anytype, conditions: []const ast.expr.Condition) !void {
    if (conditions.len == 0) return error.MissingMergeCondition;
    for (conditions, 0..) |*condition, i| {
        if (i > 0) try writer.writeAll(" AND ");
        try writeCondition(writer, condition);
    }
}

fn writeMergeAction(writer: anytype, action: *const ast.cmd.MergeAction) !void {
    switch (action.*) {
        .update => |assignments| {
            try writer.writeAll("UPDATE SET ");
            for (assignments, 0..) |assignment, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeIdentifierOrError(writer, assignment.column);
                try writer.writeAll(" = ");
                var expr = assignment.expr;
                try writeExpr(writer, &expr);
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
                try writeExpr(writer, &expr);
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
        try writer.writeAll(cte.name);

        if (cte.columns.len > 0) {
            try writer.writeAll("(");
            for (cte.columns, 0..) |col, j| {
                if (j > 0) try writer.writeAll(", ");
                try writer.writeAll(col);
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

fn writeInsertCmd(writer: anytype, cmd: *const QailCmd, include_conflict: bool) !void {
    try writer.writeAll("INSERT INTO ");
    try writer.writeAll(cmd.table);

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
        try writer.writeAll(source_sql);
    } else if (cmd.insert_values.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.insert_values, 0..) |val, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeValue(writer, &val);
        }
        try writer.writeByte(')');
    } else if (cmd.assignments.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeValue(writer, &assign.value);
        }
        try writer.writeByte(')');
    } else {
        return error.MissingInsertValues;
    }

    if (include_conflict) {
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
                            try writeValue(writer, &assign.value);
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
            try writeExpr(writer, &col);
        }
    }
}

fn writeWhereClauses(writer: anytype, clauses: []const ast.cmd.WhereClause) !void {
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
            try writeWhereCondition(writer, clause);
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
            try writeWhereCondition(writer, clause);
        }
        try writer.writeAll(")");
    }
}

fn writeWhereCondition(writer: anytype, clause: ast.cmd.WhereClause) !void {
    try writeCondition(writer, &clause.condition);
}

fn writeCondition(writer: anytype, condition: *const ast.expr.Condition) anyerror!void {
    switch (condition.op) {
        .in, .not_in => return writeInCondition(writer, condition),
        .between, .not_between => return writeBetweenCondition(writer, condition),
        .exists, .not_exists => return writer.writeAll(INVALID_EXISTS_CONDITION),
        else => {},
    }

    try writeConditionLeft(writer, condition);

    switch (condition.op) {
        .is_null, .is_not_null => try writer.print(" {s}", .{condition.op.toSql()}),
        else => {
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &condition.value);
        },
    }
}

fn writeConditionLeft(writer: anytype, condition: *const ast.expr.Condition) anyerror!void {
    if (condition.column.len != 0) {
        try writer.writeAll(condition.column);
    } else {
        var left = condition.left;
        try writeExpr(writer, &left);
    }
}

fn writeInCondition(writer: anytype, condition: *const ast.expr.Condition) !void {
    switch (condition.value) {
        .array => |values| {
            if (values.len == 0) return writer.writeAll(INVALID_IN_CONDITION);

            try writeConditionLeft(writer, condition);
            try writer.print(" {s} (", .{condition.op.toSql()});
            for (values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(writer, &value);
            }
            try writer.writeByte(')');
        },
        .param, .named_param => {
            try writeConditionLeft(writer, condition);
            try writer.writeAll(if (condition.op == .in) " = ANY(" else " != ALL(");
            try writeValue(writer, &condition.value);
            try writer.writeByte(')');
        },
        else => try writer.writeAll(INVALID_IN_CONDITION),
    }
}

fn writeBetweenCondition(writer: anytype, condition: *const ast.expr.Condition) !void {
    switch (condition.value) {
        .range => |range| {
            try writeConditionLeft(writer, condition);
            try writer.print(" {s} {d} AND {d}", .{ condition.op.toSql(), range.low, range.high });
        },
        .array => |values| {
            if (values.len != 2) return writer.writeAll(INVALID_BETWEEN_CONDITION);

            try writeConditionLeft(writer, condition);
            try writer.print(" {s} ", .{condition.op.toSql()});
            try writeValue(writer, &values[0]);
            try writer.writeAll(" AND ");
            try writeValue(writer, &values[1]);
        },
        else => try writer.writeAll(INVALID_BETWEEN_CONDITION),
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

fn writeExpr(writer: anytype, expr: *const Expr) anyerror!void {
    switch (expr.*) {
        .star => try writer.writeAll("*"),
        .named => |name| try writeIdentifierOrError(writer, name),
        .aliased => |a| {
            try writeIdentifierOrError(writer, a.name);
            try writer.writeAll(" AS ");
            try writeIdentifierMaybeQuoted(writer, a.alias);
        },
        .aggregate => |agg| {
            try writer.writeAll(agg.func.toSql());
            try writer.writeAll("(");
            if (agg.distinct) try writer.writeAll("DISTINCT ");
            try writeIdentifierOrStar(writer, agg.column);
            try writer.writeAll(")");
            if (agg.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .literal => |val| try writeValue(writer, &val),
        .binary => |b| {
            try writeExpr(writer, b.left);
            switch (b.op) {
                .is_null, .is_not_null => try writer.print(" {s}", .{b.op.toSql()}),
                else => {
                    try writer.print(" {s} ", .{b.op.toSql()});
                    try writeExpr(writer, b.right);
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
                try writeExpr(writer, &arg);
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
                try writeCondition(writer, &when_clause.condition);
                try writer.writeAll(" THEN ");
                try writeExpr(writer, &when_clause.result);
            }
            if (c.else_value) |else_expr| {
                try writer.writeAll(" ELSE ");
                try writeExpr(writer, else_expr);
            }
            try writer.writeAll(" END");
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subquery => |sq| {
            try writer.writeByte('(');
            try writer.writeAll(sq.sql);
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
                try writeExpr(writer, &ex_inner);
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
            try writeExpr(writer, c.expr);
            try writer.writeAll("::");
            try writer.writeAll(target_type);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .json_access => |ja| {
            try writeIdentifierOrError(writer, ja.column);
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
        .raw => |raw| try writer.writeAll(raw),
        .column_def => |def| try writeColumnDefExpr(writer, def),
        .window => |w| try writeWindowExpr(writer, w),
        .col_mod => |m| {
            // +col or -col for ALTER TABLE
            if (m.kind == .add) {
                try writer.writeByte('+');
            } else {
                try writer.writeByte('-');
            }
            try writeExpr(writer, m.col);
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
                try writeExpr(writer, arg.expr);
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
                try writeExpr(writer, &elem);
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
                try writeExpr(writer, &elem);
            }
            try writer.writeByte(')');
            if (r.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .subscript => |s| {
            try writeExpr(writer, s.base);
            try writer.writeByte('[');
            try writeExpr(writer, s.index);
            try writer.writeByte(']');
            if (s.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .collate => |c| {
            try writeExpr(writer, c.expr);
            try writer.writeAll(" COLLATE ");
            try writeIdentifierOrError(writer, c.collation);
            if (c.alias) |alias| {
                try writer.writeAll(" AS ");
                try writeIdentifierMaybeQuoted(writer, alias);
            }
        },
        .field_access => |f| {
            try writer.writeByte('(');
            try writeExpr(writer, f.expr);
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
            try writer.writeAll(sq.sql);
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
            try writeExpr(writer, u.operand);
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
}

fn writeSqlExprFragmentOrError(writer: anytype, fragment: []const u8) !void {
    const checked = checkedSqlExprFragment(fragment) orelse {
        try writer.writeAll(INVALID_COLUMN_FRAGMENT);
        return;
    };
    try writer.writeAll(checked);
}

fn writeWindowExpr(writer: anytype, w: WindowExpr) !void {
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
            try writeIdentifierOrError(writer, col);
        }
    }
    if (w.order.len > 0) {
        if (w.partition.len > 0) try writer.writeAll(" ");
        try writer.writeAll("ORDER BY ");
        for (w.order, 0..) |o, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeIdentifierOrError(writer, o.column);
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

fn writeValue(writer: anytype, val: *const Value) !void {
    try val.format(writer);
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

    const safe_constraints = [_]ast.expr.Constraint{.{ .default = "'semi;inside'" }};
    const safe_defs = [_]Expr{Expr.defWithConstraints("note", "text", &safe_constraints)};
    const safe_cmd = QailCmd.make("events").select(&safe_defs);

    var safe_buf: [512]u8 = undefined;
    var safe_writer = io.FixedBufferWriter.init(&safe_buf);
    try encoder.writeAstToSql(safe_writer.writer(), &safe_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS events (note text DEFAULT 'semi;inside')",
        safe_writer.getWritten(),
    );

    const bad_constraints = [_]ast.expr.Constraint{.{ .default = "0; DROP TABLE users; --" }};
    const bad_defs = [_]Expr{Expr.defWithConstraints("score", "integer", &bad_constraints)};
    const bad_cmd = QailCmd.make("events").select(&bad_defs);

    var bad_buf: [512]u8 = undefined;
    var bad_writer = io.FixedBufferWriter.init(&bad_buf);
    try encoder.writeAstToSql(bad_writer.writer(), &bad_cmd);
    try std.testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS events (score integer DEFAULT /* ERROR: Invalid column definition fragment */)",
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

test "ast encoder insert target expressions fail closed" {
    var encoder = AstEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const target_cols = [_]Expr{ Expr.int(1), Expr.col("email") };
    const values = [_]Value{ .{ .int = 1 }, .{ .string = "alice@example.com" } };
    var cmd = QailCmd.add("users").select(&target_cols);
    cmd.insert_values = &values;

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "INSERT INTO users (/* ERROR: Invalid insert column */, email) VALUES (1, 'alice@example.com')",
        writer.getWritten(),
    );
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

    const wheres = [_]ast.cmd.WhereClause{
        .{
            .condition = .{
                .column = "id",
                .op = .in,
                .value = .{ .param = 1 },
            },
        },
        .{
            .condition = .{
                .column = "role",
                .op = .not_in,
                .value = .{ .named_param = "roles" },
            },
        },
    };
    const cmd = QailCmd.get("users").where(&wheres);

    var sql_buf: [512]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&sql_buf);
    try encoder.writeAstToSql(writer.writer(), &cmd);

    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE id = ANY($1) AND role != ALL(:roles)",
        writer.getWritten(),
    );
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
    try encoder.writeAstToSql(in_writer.writer(), &empty_in_cmd);
    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE FALSE /* ERROR: IN condition requires a non-empty array, subquery, or array parameter */",
        in_writer.getWritten(),
    );

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
    try encoder.writeAstToSql(exists_writer.writer(), &bad_exists_cmd);
    try std.testing.expectEqualStrings(
        "SELECT * FROM users WHERE FALSE /* ERROR: EXISTS condition requires subquery value */",
        exists_writer.getWritten(),
    );
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
