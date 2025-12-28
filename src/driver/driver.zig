// PostgreSQL Driver (Zig 0.16 API)
//
// Main driver struct for executing QAIL AST queries.
// Uses new std.Io interface for pluggable async I/O backends.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const protocol = @import("../protocol/mod.zig");
const conn_mod = @import("connection.zig");
const row_mod = @import("row.zig");

const Io = std.Io;
const QailCmd = ast.QailCmd;
const AstEncoder = protocol.AstEncoder;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const FieldDescription = protocol.wire.FieldDescription;
const Connection = conn_mod.Connection;
const PgRow = row_mod.PgRow;

/// Query options for per-query configuration
pub const QueryOpts = struct {
    /// Timeout in milliseconds (null = no timeout)
    timeout_ms: ?u32 = null,
    /// Whether to populate column names in results
    column_names: bool = true,
    /// Custom allocator for this query (null = use driver allocator)
    allocator: ?std.mem.Allocator = null,
};

/// PostgreSQL driver - executes QAIL AST queries
/// Zig 0.16: Now accepts Io interface for pluggable async backends
pub const PgDriver = struct {
    conn: Connection,
    allocator: std.mem.Allocator,
    io: Io,
    encoder: AstEncoder,

    pub fn init(conn: Connection, allocator: std.mem.Allocator, io: Io) PgDriver {
        return .{
            .conn = conn,
            .allocator = allocator,
            .io = io,
            .encoder = AstEncoder.init(allocator),
        };
    }

    pub fn deinit(self: *PgDriver) void {
        self.encoder.deinit();
        self.conn.close();
    }

    /// Connect to PostgreSQL using provided Io interface
    /// Caller creates Io (e.g., via std.Io.Threaded.init(allocator).io())
    pub fn connect(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16, user: []const u8, database: []const u8) !PgDriver {
        var conn = try Connection.connect(allocator, io, host, port);
        errdefer conn.close();

        try conn.startup(user, database, null);

        return PgDriver.init(conn, allocator, io);
    }

    /// Connect with password
    pub fn connectWithPassword(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16, user: []const u8, database: []const u8, password: []const u8) !PgDriver {
        var conn = try Connection.connect(allocator, io, host, port);
        errdefer conn.close();

        try conn.startup(user, database, password);

        return PgDriver.init(conn, allocator, io);
    }

    // ==================== AST-Native Query Execution ====================

    /// Execute a QAIL AST command and fetch all rows
    pub fn fetchAll(self: *PgDriver, cmd: *const QailCmd) ![]PgRow {
        // Encode AST to wire protocol
        try self.encoder.encodeQuery(cmd);
        try self.conn.send(self.encoder.getWritten());

        // Collect results
        var rows: std.ArrayList(PgRow) = .{};
        errdefer {
            for (rows.items) |*row| {
                row.deinit();
            }
            rows.deinit(self.allocator);
        }

        var field_descriptions: []FieldDescription = &.{};
        var field_names: [][]const u8 = &.{};

        // Read responses
        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .parse_complete, .bind_complete => {},
                .row_description => {
                    var decoder = Decoder.init(msg.payload);
                    field_descriptions = try decoder.parseRowDescription(self.allocator);
                    defer self.allocator.free(field_descriptions); // Free after extracting names

                    // Extract field names (names are already allocated separately in FieldDescription)
                    field_names = try self.allocator.alloc([]const u8, field_descriptions.len);
                    for (field_descriptions, 0..) |fd, i| {
                        field_names[i] = fd.name;
                    }
                },
                .data_row => {
                    var decoder = Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRow(self.allocator);

                    try rows.append(self.allocator, PgRow{
                        .columns = columns,
                        .field_names = field_names,
                        .allocator = self.allocator,
                    });
                },
                .command_complete => {},
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Query error: {s}\n", .{err.message orelse "unknown"});
                    return error.QueryError;
                },
                .no_data => {},
                else => {},
            }
        }

        return try rows.toOwnedSlice(self.allocator);
    }

    /// Execute a QAIL AST command and fetch one row
    pub fn fetchOne(self: *PgDriver, cmd: *const QailCmd) !?PgRow {
        const rows = try self.fetchAll(cmd);
        defer {
            for (rows[1..]) |*row| {
                row.deinit();
            }
            self.allocator.free(rows);
        }

        if (rows.len == 0) return null;
        return rows[0];
    }

    /// a single 'Q' message instead of Parse+Bind+Describe+Execute+Sync.
    pub fn fetchAllSimple(self: *PgDriver, cmd: *const QailCmd) ![]PgRow {
        // Encode AST to Simple Query wire protocol
        try self.encoder.encodeSimpleQuery(cmd);
        try self.conn.send(self.encoder.getWritten());

        // Collect results
        var rows: std.ArrayList(PgRow) = .{};
        errdefer {
            for (rows.items) |*row| {
                row.deinit();
            }
            rows.deinit(self.allocator);
        }

        var field_names: [][]const u8 = &.{};

        // Read responses (Simple Query returns: RowDescription, DataRow*, CommandComplete, ReadyForQuery)
        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .row_description => {
                    var decoder = Decoder.init(msg.payload);
                    const descriptions = try decoder.parseRowDescription(self.allocator);

                    // Extract field names for rows
                    field_names = try self.allocator.alloc([]const u8, descriptions.len);
                    for (descriptions, 0..) |desc, i| {
                        field_names[i] = desc.name;
                    }
                    self.allocator.free(descriptions);
                },
                .data_row => {
                    var decoder = Decoder.init(msg.payload);
                    try rows.append(self.allocator, PgRow{
                        .columns = try decoder.parseDataRow(self.allocator),
                        .field_names = field_names,
                        .allocator = self.allocator,
                    });
                },
                .command_complete => {},
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Query error: {s}\n", .{err.message orelse "unknown"});
                    return error.QueryError;
                },
                else => {},
            }
        }

        return try rows.toOwnedSlice(self.allocator);
    }

    /// Execute a QAIL AST command (for mutations) - returns affected row count
    pub fn execute(self: *PgDriver, cmd: *const QailCmd) !u64 {
        try self.encoder.encodeQuery(cmd);
        try self.conn.send(self.encoder.getWritten());

        var affected_rows: u64 = 0;

        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .parse_complete, .bind_complete => {},
                .command_complete => {
                    var decoder = Decoder.init(msg.payload);
                    const tag = try decoder.parseCommandComplete();

                    // Parse affected rows from tag like "UPDATE 5"
                    var parts = std.mem.splitBackwardsScalar(u8, tag, ' ');
                    if (parts.next()) |last| {
                        affected_rows = std.fmt.parseInt(u64, last, 10) catch 0;
                    }
                },
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Execute error: {s}\n", .{err.message orelse "unknown"});
                    return error.ExecuteError;
                },
                else => {},
            }
        }

        return affected_rows;
    }

    // ==================== Transaction Control ====================

    /// Begin a transaction
    pub fn begin(self: *PgDriver) !void {
        const cmd = QailCmd.raw("BEGIN");
        _ = try self.execute(&cmd);
    }

    /// Commit the transaction
    pub fn commit(self: *PgDriver) !void {
        const cmd = QailCmd.raw("COMMIT");
        _ = try self.execute(&cmd);
    }

    /// Rollback the transaction
    pub fn rollback(self: *PgDriver) !void {
        const cmd = QailCmd.raw("ROLLBACK");
        _ = try self.execute(&cmd);
    }

    /// Execute raw SQL string (for migrations, DDL, etc.)
    pub fn executeRaw(self: *PgDriver, sql: []const u8) !u64 {
        const cmd = QailCmd.raw(sql);
        return try self.execute(&cmd);
    }

    // ==================== Prepared Statements ====================

    /// Prepare a statement for later execution with parameters
    /// Returns immediately after Parse completes
    pub fn prepare(self: *PgDriver, stmt_name: []const u8, cmd: *const QailCmd) !void {
        // Encode Parse message only (no Bind/Execute)
        try self.encoder.encodePrepare(stmt_name, cmd);
        try self.conn.send(self.encoder.getWritten());

        // Wait for ParseComplete
        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .parse_complete => {},
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Prepare error: {s}\n", .{err.message orelse "unknown"});
                    return error.PrepareError;
                },
                else => {},
            }
        }
    }

    /// Execute a prepared statement with text parameters
    pub fn executePrepared(self: *PgDriver, stmt_name: []const u8, params: []const ?[]const u8) !u64 {
        // Encode Bind + Execute + Sync
        try self.encoder.executeNamedStatement(stmt_name, params);
        try self.conn.send(self.encoder.getWritten());

        var affected_rows: u64 = 0;

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .bind_complete => {},
                .command_complete => {
                    var decoder = Decoder.init(msg.payload);
                    const tag = try decoder.parseCommandComplete();
                    var parts = std.mem.splitBackwardsScalar(u8, tag, ' ');
                    if (parts.next()) |last| {
                        affected_rows = std.fmt.parseInt(u64, last, 10) catch 0;
                    }
                },
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Execute error: {s}\n", .{err.message orelse "unknown"});
                    return error.ExecuteError;
                },
                else => {},
            }
        }

        return affected_rows;
    }

    /// Fetch all rows from a prepared statement with parameters
    pub fn fetchPrepared(self: *PgDriver, stmt_name: []const u8, params: []const ?[]const u8) ![]PgRow {
        try self.encoder.executeNamedStatement(stmt_name, params);
        try self.conn.send(self.encoder.getWritten());

        var rows: std.ArrayList(PgRow) = .{};
        errdefer {
            for (rows.items) |*row| row.deinit();
            rows.deinit(self.allocator);
        }

        var field_descriptions: []FieldDescription = &.{};
        var field_names: [][]const u8 = &.{};

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .bind_complete => {},
                .row_description => {
                    var decoder = Decoder.init(msg.payload);
                    field_descriptions = try decoder.parseRowDescription(self.allocator);
                    defer self.allocator.free(field_descriptions);

                    field_names = try self.allocator.alloc([]const u8, field_descriptions.len);
                    for (field_descriptions, 0..) |fd, i| {
                        field_names[i] = fd.name;
                    }
                },
                .data_row => {
                    var decoder = Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRow(self.allocator);
                    try rows.append(self.allocator, PgRow{
                        .columns = columns,
                        .field_names = field_names,
                        .allocator = self.allocator,
                    });
                },
                .command_complete => {},
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Query error: {s}\n", .{err.message orelse "unknown"});
                    return error.QueryError;
                },
                else => {},
            }
        }

        return try rows.toOwnedSlice(self.allocator);
    }
};

// Tests
test "pgdriver struct" {
    // Just test the struct can be referenced
    _ = PgDriver;
}
