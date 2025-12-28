// AST-Native Wire Encoder
//
// Encodes QAIL AST (QailCmd) directly to PostgreSQL wire protocol bytes.
// NO SQL STRING GENERATION - this is the core of QAIL's philosophy.

const std = @import("std");
const ast = struct {
    pub const cmd = @import("../ast/cmd.zig");
    pub const expr = @import("../ast/expr.zig");
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
const FrontendMessage = wire.FrontendMessage;
const PROTOCOL_VERSION = wire.PROTOCOL_VERSION;

/// AST-to-Wire encoder
/// Directly encodes QailCmd AST to PostgreSQL Extended Query Protocol bytes
pub const AstEncoder = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    param_count: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) AstEncoder {
        return .{
            .buffer = .{},
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
        try self.buffer.appendSlice(self.allocator, str);
        try self.buffer.append(self.allocator, 0);
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

    /// Encode Parse message with AST-generated query structure
    fn encodeParse(self: *AstEncoder, stmt_name: []const u8, cmd: *const QailCmd) !void {
        // For now, we generate SQL from AST
        // TODO: In future, encode directly to binary protocol where possible

        // Calculate SQL from AST
        var sql_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&sql_buf);
        try self.writeAstToSql(fbs.writer(), cmd);
        const sql = fbs.getWritten();

        const msg_len: u32 = 4 + @as(u32, @intCast(stmt_name.len)) + 1 + @as(u32, @intCast(sql.len)) + 1 + 2;

        try self.writeByte(@intFromEnum(FrontendMessage.parse));
        try self.writeU32(msg_len);
        try self.writeCString(stmt_name);
        try self.writeCString(sql);
        try self.writeU16(0); // No parameter types
    }

    /// Encode Bind message
    fn encodeBind(self: *AstEncoder, portal: []const u8, stmt_name: []const u8, params: []const ?[]const u8) !void {
        var params_size: u32 = 0;
        for (params) |param| {
            params_size += 4;
            if (param) |p| {
                params_size += @intCast(p.len);
            }
        }

        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + @as(u32, @intCast(stmt_name.len)) + 1 + 2 + 2 + params_size + 2;

        try self.writeByte(@intFromEnum(FrontendMessage.bind));
        try self.writeU32(msg_len);
        try self.writeCString(portal);
        try self.writeCString(stmt_name);
        try self.writeU16(0); // No format codes
        try self.writeU16(@intCast(params.len));

        for (params) |param| {
            if (param) |p| {
                try self.writeI32(@intCast(p.len));
                try self.writeBytes(p);
            } else {
                try self.writeI32(-1);
            }
        }

        try self.writeU16(0); // No result format codes
    }

    /// Encode Describe message
    fn encodeDescribe(self: *AstEncoder, portal: []const u8) !void {
        const msg_len: u32 = 4 + 1 + @as(u32, @intCast(portal.len)) + 1;
        try self.writeByte(@intFromEnum(FrontendMessage.describe));
        try self.writeU32(msg_len);
        try self.writeByte('P');
        try self.writeCString(portal);
    }

    /// Encode Execute message
    fn encodeExecute(self: *AstEncoder, portal: []const u8, max_rows: u32) !void {
        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + 4;
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
            .get => {
                try writer.writeAll("SELECT ");

                if (cmd.distinct) {
                    try writer.writeAll("DISTINCT ");
                }

                // Columns
                if (cmd.columns.len == 0) {
                    try writer.writeAll("*");
                } else {
                    for (cmd.columns, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                }

                try writer.writeAll(" FROM ");
                try writer.writeAll(cmd.table);

                if (cmd.table_alias) |alias| {
                    try writer.writeAll(" AS ");
                    try writer.writeAll(alias);
                }

                // JOINs
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

                // WHERE
                if (cmd.where_clauses.len > 0) {
                    try writer.writeAll(" WHERE ");
                    for (cmd.where_clauses, 0..) |clause, i| {
                        if (i > 0) {
                            try writer.print(" {s} ", .{clause.logical_op.toSql()});
                        }
                        try writer.writeAll(clause.condition.column);
                        try writer.print(" {s} ", .{clause.condition.op.toSql()});
                        try writeValue(writer, &clause.condition.value);
                    }
                }

                // GROUP BY
                if (cmd.group_by.len > 0) {
                    try writer.writeAll(" GROUP BY ");
                    for (cmd.group_by, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(col);
                    }
                }

                // ORDER BY
                if (cmd.order_by.len > 0) {
                    try writer.writeAll(" ORDER BY ");
                    for (cmd.order_by, 0..) |order, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(order.column);
                        try writer.print(" {s}", .{order.order.toSql()});
                    }
                }

                // LIMIT
                if (cmd.limit_val) |limit| {
                    try writer.print(" LIMIT {d}", .{limit});
                }

                // OFFSET
                if (cmd.offset_val) |offset| {
                    try writer.print(" OFFSET {d}", .{offset});
                }

                // FOR UPDATE
                if (cmd.for_update) {
                    try writer.writeAll(" FOR UPDATE");
                }
            },
            .set => {
                try writer.writeAll("UPDATE ");
                try writer.writeAll(cmd.table);
                try writer.writeAll(" SET ");

                for (cmd.assignments, 0..) |assign, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(assign.column);
                    try writer.writeAll(" = ");
                    try writeValue(writer, &assign.value);
                }

                if (cmd.where_clauses.len > 0) {
                    try writer.writeAll(" WHERE ");
                    for (cmd.where_clauses, 0..) |clause, i| {
                        if (i > 0) {
                            try writer.print(" {s} ", .{clause.logical_op.toSql()});
                        }
                        try writer.writeAll(clause.condition.column);
                        try writer.print(" {s} ", .{clause.condition.op.toSql()});
                        try writeValue(writer, &clause.condition.value);
                    }
                }

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

                if (cmd.where_clauses.len > 0) {
                    try writer.writeAll(" WHERE ");
                    for (cmd.where_clauses, 0..) |clause, i| {
                        if (i > 0) {
                            try writer.print(" {s} ", .{clause.logical_op.toSql()});
                        }
                        try writer.writeAll(clause.condition.column);
                        try writer.print(" {s} ", .{clause.condition.op.toSql()});
                        try writeValue(writer, &clause.condition.value);
                    }
                }

                if (cmd.returning.len > 0) {
                    try writer.writeAll(" RETURNING ");
                    for (cmd.returning, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                }
            },
            .add => {
                try writer.writeAll("INSERT INTO ");
                try writer.writeAll(cmd.table);

                // Option 1: columns + insert_values (AST-native like qail.rs)
                if (cmd.columns.len > 0 and cmd.insert_values.len > 0) {
                    try writer.writeAll(" (");
                    for (cmd.columns, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                    try writer.writeAll(") VALUES (");
                    for (cmd.insert_values, 0..) |val, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeValue(writer, &val);
                    }
                    try writer.writeAll(")");
                }
                // Option 2: assignments (legacy pattern)
                else if (cmd.assignments.len > 0) {
                    try writer.writeAll(" (");
                    for (cmd.assignments, 0..) |assign, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(assign.column);
                    }
                    try writer.writeAll(") VALUES (");
                    for (cmd.assignments, 0..) |assign, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeValue(writer, &assign.value);
                    }
                    try writer.writeAll(")");
                }

                if (cmd.returning.len > 0) {
                    try writer.writeAll(" RETURNING ");
                    for (cmd.returning, 0..) |col, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writeExpr(writer, &col);
                    }
                }
            },
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
                    try writer.writeAll(p);
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
            .alter_drop => {
                // ALTER TABLE DROP COLUMN
                try writer.writeAll("ALTER TABLE ");
                try writer.writeAll(cmd.table);
                for (cmd.columns) |col| {
                    try writer.writeAll(" DROP COLUMN ");
                    try writeExpr(writer, &col);
                }
            },
            .mod => {
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
            else => {},
        }
    }
};

fn writeExpr(writer: anytype, expr: *const Expr) !void {
    switch (expr.*) {
        .star => try writer.writeAll("*"),
        .named => |name| try writer.writeAll(name),
        .aliased => |a| {
            try writer.writeAll(a.name);
            try writer.writeAll(" AS ");
            try writer.writeAll(a.alias);
        },
        .aggregate => |agg| {
            try writer.writeAll(agg.func.toSql());
            try writer.writeAll("(");
            if (agg.distinct) try writer.writeAll("DISTINCT ");
            try writer.writeAll(agg.column);
            try writer.writeAll(")");
            if (agg.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        .literal => |val| try writeValue(writer, &val),
        .column_def => |def| {
            const Constraint = @import("../ast/expr.zig").Constraint;
            // Column definition for DDL: name TYPE [constraints]
            try writer.writeAll(def.name);
            try writer.writeAll(" ");
            try writer.writeAll(def.data_type);

            // Check constraints using helper methods
            if (Constraint.hasPrimaryKey(def.constraints)) {
                try writer.writeAll(" PRIMARY KEY");
            } else {
                // Default to NOT NULL unless Nullable constraint is present
                if (!Constraint.hasNullable(def.constraints)) {
                    try writer.writeAll(" NOT NULL");
                }
                if (Constraint.hasUnique(def.constraints)) {
                    try writer.writeAll(" UNIQUE");
                }
            }

            // Handle DEFAULT value
            if (Constraint.getDefault(def.constraints)) |dv| {
                try writer.writeAll(" DEFAULT ");
                try writer.writeAll(dv);
            }

            // Handle REFERENCES
            for (def.constraints) |c| {
                if (c == .references) {
                    try writer.writeAll(" REFERENCES ");
                    try writer.writeAll(c.references);
                }
            }
        },
        else => {},
    }
}

fn writeValue(writer: anytype, val: *const Value) !void {
    switch (val.*) {
        .null => try writer.writeAll("NULL"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('\'');
            for (s) |c| {
                if (c == '\'') {
                    try writer.writeAll("''");
                } else {
                    try writer.writeByte(c);
                }
            }
            try writer.writeByte('\'');
        },
        .param => |p| try writer.print("${d}", .{p}),
        else => {},
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
