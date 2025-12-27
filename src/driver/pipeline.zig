//! PostgreSQL Pipelining API
//!
//! High-performance pipelining methods for batch query execution.
//! Matches qail-pg (Rust) pipelining feature set.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const protocol = @import("../protocol/mod.zig");
const conn_mod = @import("connection.zig");
const row_mod = @import("row.zig");

const QailCmd = ast.QailCmd;
const AstEncoder = protocol.AstEncoder;
const Encoder = protocol.Encoder;
const BackendMessage = protocol.BackendMessage;
const Connection = conn_mod.Connection;
const PgRow = row_mod.PgRow;

/// Prepared statement handle for fast repeated execution.
/// Create with `prepare()`, use with `pipelinePreparedFast()`.
pub const PreparedStatement = struct {
    name: []const u8,
    sql: []const u8,
    param_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PreparedStatement) void {
        self.allocator.free(self.name);
        self.allocator.free(self.sql);
    }
};

/// Pipeline execution context - holds shared state for pipelining operations
pub const Pipeline = struct {
    conn: *Connection,
    encoder: Encoder,
    allocator: std.mem.Allocator,
    stmt_cache: std.StringHashMap(PreparedStatement),

    pub fn init(conn: *Connection, allocator: std.mem.Allocator) Pipeline {
        return .{
            .conn = conn,
            .encoder = Encoder.init(allocator),
            .allocator = allocator,
            .stmt_cache = std.StringHashMap(PreparedStatement).init(allocator),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        // Clean up cached statements
        var it = self.stmt_cache.valueIterator();
        while (it.next()) |stmt| {
            var s = stmt.*;
            s.deinit();
        }
        self.stmt_cache.deinit();
        self.encoder.deinit();
    }

    /// Clear the statement cache (useful for session reset)
    pub fn clearCache(self: *Pipeline) void {
        var it = self.stmt_cache.valueIterator();
        while (it.next()) |stmt| {
            var s = stmt.*;
            s.deinit();
        }
        self.stmt_cache.clearRetainingCapacity();
    }

    /// Get a cached prepared statement or create a new one.
    /// Cached statements are automatically reused across calls.
    pub fn getOrPrepare(self: *Pipeline, sql: []const u8) !*PreparedStatement {
        // Check cache first
        if (self.stmt_cache.getPtr(sql)) |cached| {
            return cached;
        }

        // Not in cache - prepare it
        const stmt = try self.prepare(sql);

        // Cache it (uses sql as key since it's already allocated in stmt)
        try self.stmt_cache.put(stmt.sql, stmt);

        // Return pointer to cached statement
        return self.stmt_cache.getPtr(stmt.sql).?;
    }

    // ==================== Prepared Statement Methods ====================

    /// Prepare a SQL statement and return a handle for fast execution.
    /// The statement is registered with PostgreSQL for reuse.
    pub fn prepare(self: *Pipeline, sql: []const u8) !PreparedStatement {
        // Generate unique statement name from SQL hash
        const hash = std.hash.Wyhash.hash(0, sql);
        const name = try std.fmt.allocPrint(self.allocator, "s{x}", .{hash});
        errdefer self.allocator.free(name);

        const sql_copy = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_copy);

        // Send Parse + Sync
        try self.encoder.encodeParse(name, sql, &.{});
        try self.conn.send(self.encoder.getWritten());

        try self.encoder.encodeSync();
        try self.conn.send(self.encoder.getWritten());

        // Wait for ParseComplete + ReadyForQuery
        try self.readUntilReady();

        // Count parameters (simple $ counting)
        var param_count: usize = 0;
        for (sql) |c| {
            if (c == '$') param_count += 1;
        }

        return .{
            .name = name,
            .sql = sql_copy,
            .param_count = param_count,
            .allocator = self.allocator,
        };
    }

    // ==================== AST Pipelining ====================

    /// Execute multiple QailCmd ASTs in a single network round-trip.
    /// Returns only the count of completed queries (fast path).
    pub fn pipelineAstFast(self: *Pipeline, cmds: []const *const QailCmd) !usize {
        if (cmds.len == 0) return 0;

        var ast_encoder = AstEncoder.init(self.allocator);
        defer ast_encoder.deinit();

        // Encode all ASTs to wire protocol
        for (cmds) |cmd| {
            try ast_encoder.encodeQuery(cmd);
        }

        // Send all at once
        try self.conn.send(ast_encoder.getWritten());

        // Count completions
        return try self.countCompletions(cmds.len);
    }

    /// Execute multiple QailCmd ASTs and return all results.
    pub fn pipelineAst(
        self: *Pipeline,
        cmds: []const *const QailCmd,
    ) ![][]PgRow {
        if (cmds.len == 0) return &.{};

        var ast_encoder = AstEncoder.init(self.allocator);
        defer ast_encoder.deinit();

        // Encode all ASTs
        for (cmds) |cmd| {
            try ast_encoder.encodeQuery(cmd);
        }

        // Send all at once
        try self.conn.send(ast_encoder.getWritten());

        // Collect results
        return try self.collectResults(cmds.len);
    }

    // ==================== Prepared Statement Pipelining ====================

    /// Execute a prepared statement multiple times with different parameters.
    /// Returns only the count of completed queries (fastest path).
    ///
    /// OPTIMIZATION: All Bind+Execute messages are batched in memory and sent
    /// with a single network write, minimizing syscalls for maximum throughput.
    pub fn pipelinePreparedFast(
        self: *Pipeline,
        stmt: *const PreparedStatement,
        params_batch: []const []const ?[]const u8,
    ) !usize {
        if (params_batch.len == 0) return 0;

        // Pre-allocate buffer for ALL messages (Bind+Execute per query + Sync)
        // Estimate: ~50 bytes per query for SELECT 1 type queries
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);
        try buffer.ensureTotalCapacity(self.allocator, params_batch.len * 50 + 10);

        // Encode ALL Bind+Execute messages into buffer
        for (params_batch) |params| {
            // Encode Bind
            try self.encodeBind(&buffer, "", stmt.name, params);
            // Encode Execute
            try self.encodeExecute(&buffer, "", 0);
        }

        // Encode Sync at end
        try self.encodeSync(&buffer);

        // Send ALL at once (single syscall!)
        try self.conn.send(buffer.items);

        // Count completions
        return try self.countCompletions(params_batch.len);
    }

    /// Execute a prepared statement multiple times and return all results.
    pub fn pipelinePreparedResults(
        self: *Pipeline,
        stmt: *const PreparedStatement,
        params_batch: []const []const ?[]const u8,
    ) ![][]PgRow {
        if (params_batch.len == 0) return &.{};

        // Pre-allocate buffer for ALL messages
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);
        try buffer.ensureTotalCapacity(self.allocator, params_batch.len * 50 + 10);

        // Encode ALL Bind+Execute messages into buffer
        for (params_batch) |params| {
            try self.encodeBind(&buffer, "", stmt.name, params);
            try self.encodeExecute(&buffer, "", 0);
        }

        // Encode Sync at end
        try self.encodeSync(&buffer);

        // Send ALL at once
        try self.conn.send(buffer.items);

        // Collect results
        return try self.collectResults(params_batch.len);
    }

    // ==================== Optimized Pipelining Methods ====================

    /// Execute pre-encoded wire protocol bytes directly.
    /// Maximum performance - caller is responsible for encoding
    /// Parse/Bind/Execute/Sync messages correctly.
    pub fn pipelineBytesFast(
        self: *Pipeline,
        wire_bytes: []const u8,
        expected_queries: usize,
    ) !usize {
        // Send raw bytes directly (no encoding overhead)
        try self.conn.send(wire_bytes);

        // Count completions
        return try self.countCompletions(expected_queries);
    }

    /// Zero-copy prepared statement pipeline.
    /// Encodes Bind+Execute directly without intermediate allocations.
    /// Same as pipelinePreparedFast but with explicit zero-copy semantics.
    pub fn pipelinePreparedZerocopy(
        self: *Pipeline,
        stmt: *const PreparedStatement,
        params_batch: []const []const ?[]const u8,
    ) !usize {
        // This is the same implementation as pipelinePreparedFast
        // which already uses zero-copy buffer encoding
        return self.pipelinePreparedFast(stmt, params_batch);
    }

    /// Ultra-fast optimized path for 2-column result sets.
    /// Common pattern: SELECT id, name FROM table WHERE ...
    /// Returns results as pairs of (col1, col2).
    pub fn pipelinePreparedUltra(
        self: *Pipeline,
        stmt: *const PreparedStatement,
        params_batch: []const []const ?[]const u8,
    ) ![][2]?[]const u8 {
        if (params_batch.len == 0) return &.{};

        // Pre-allocate buffer for ALL messages
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);
        try buffer.ensureTotalCapacity(self.allocator, params_batch.len * 50 + 10);

        // Encode ALL Bind+Execute messages into buffer
        for (params_batch) |params| {
            try self.encodeBind(&buffer, "", stmt.name, params);
            try self.encodeExecute(&buffer, "", 0);
        }

        // Encode Sync at end
        try self.encodeSync(&buffer);

        // Send ALL at once
        try self.conn.send(buffer.items);

        // Collect 2-column results
        return try self.collectUltraResults(params_batch.len);
    }

    /// Internal: collect 2-column result pairs
    fn collectUltraResults(self: *Pipeline, expected: usize) ![][2]?[]const u8 {
        var results: std.ArrayList([2]?[]const u8) = .{};
        errdefer results.deinit(self.allocator);

        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .data_row => {
                    var decoder = protocol.Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRow(self.allocator);

                    // Extract first 2 columns
                    var pair: [2]?[]const u8 = .{ null, null };
                    if (columns.len > 0) pair[0] = columns[0];
                    if (columns.len > 1) pair[1] = columns[1];

                    try results.append(self.allocator, pair);
                },
                .command_complete, .bind_complete, .no_data => {},
                .ready_for_query => {
                    if (results.items.len >= expected or results.items.len > 0) {
                        return try results.toOwnedSlice(self.allocator);
                    }
                },
                .error_response => return error.QueryError,
                else => {},
            }
        }
    }

    // ==================== Direct Buffer Encoding (for batching) ====================

    fn encodeBind(self: *Pipeline, buffer: *std.ArrayList(u8), portal: []const u8, stmt_name: []const u8, params: []const ?[]const u8) !void {
        var params_size: u32 = 0;
        for (params) |param| {
            params_size += 4;
            if (param) |p| {
                params_size += @intCast(p.len);
            }
        }

        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + @as(u32, @intCast(stmt_name.len)) + 1 + 2 + 2 + params_size + 2;

        try buffer.append(self.allocator, @intFromEnum(protocol.wire.FrontendMessage.bind));
        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, msg_len)));
        try buffer.appendSlice(self.allocator, portal);
        try buffer.append(self.allocator, 0);
        try buffer.appendSlice(self.allocator, stmt_name);
        try buffer.append(self.allocator, 0);
        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // format codes
        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @as(u16, @intCast(params.len)))));

        for (params) |param| {
            if (param) |p| {
                try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, @as(i32, @intCast(p.len)))));
                try buffer.appendSlice(self.allocator, p);
            } else {
                try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, -1)));
            }
        }

        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // result format codes
    }

    fn encodeExecute(self: *Pipeline, buffer: *std.ArrayList(u8), portal: []const u8, max_rows: u32) !void {
        const msg_len: u32 = 4 + @as(u32, @intCast(portal.len)) + 1 + 4;
        try buffer.append(self.allocator, @intFromEnum(protocol.wire.FrontendMessage.execute));
        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, msg_len)));
        try buffer.appendSlice(self.allocator, portal);
        try buffer.append(self.allocator, 0);
        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, max_rows)));
    }

    fn encodeSync(self: *Pipeline, buffer: *std.ArrayList(u8)) !void {
        try buffer.append(self.allocator, @intFromEnum(protocol.wire.FrontendMessage.sync));
        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, 4)));
    }

    // ==================== Internal Helpers ====================

    /// Count query completions without parsing results
    fn countCompletions(self: *Pipeline, expected: usize) !usize {
        var completed: usize = 0;

        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .bind_complete, .parse_complete => {},
                .row_description => {},
                .data_row => {},
                .command_complete => completed += 1,
                .no_data => completed += 1,
                .ready_for_query => {
                    if (completed >= expected) return completed;
                },
                .error_response => return error.QueryError,
                else => {},
            }
        }
    }

    /// Collect full results from pipeline
    fn collectResults(self: *Pipeline, expected: usize) ![][]PgRow {
        var all_results: std.ArrayList([]PgRow) = .{};
        errdefer {
            for (all_results.items) |rows| {
                for (rows) |*row| {
                    row.deinit();
                }
                self.allocator.free(rows);
            }
            all_results.deinit(self.allocator);
        }

        var current_rows: std.ArrayList(PgRow) = .{};
        errdefer {
            for (current_rows.items) |*row| {
                row.deinit();
            }
            current_rows.deinit(self.allocator);
        }

        var field_names: [][]const u8 = &.{};

        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .bind_complete, .parse_complete => {},
                .row_description => {
                    var decoder = protocol.Decoder.init(msg.payload);
                    const fields = try decoder.parseRowDescription(self.allocator);

                    field_names = try self.allocator.alloc([]const u8, fields.len);
                    for (fields, 0..) |fd, i| {
                        field_names[i] = fd.name;
                    }
                },
                .data_row => {
                    var decoder = protocol.Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRow(self.allocator);

                    try current_rows.append(self.allocator, .{
                        .columns = columns,
                        .field_names = field_names,
                        .allocator = self.allocator,
                    });
                },
                .command_complete => {
                    try all_results.append(self.allocator, try current_rows.toOwnedSlice(self.allocator));
                    current_rows = .{};
                },
                .no_data => {
                    try all_results.append(self.allocator, &.{});
                },
                .ready_for_query => {
                    if (all_results.items.len >= expected) {
                        return try all_results.toOwnedSlice(self.allocator);
                    }
                },
                .error_response => return error.QueryError,
                else => {},
            }
        }
    }

    /// Read messages until ReadyForQuery
    fn readUntilReady(self: *Pipeline) !void {
        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .ready_for_query => return,
                .error_response => return error.ServerError,
                else => {},
            }
        }
    }
};

// ==================== Tests ====================

test "PreparedStatement struct" {
    _ = PreparedStatement;
}

test "Pipeline struct" {
    _ = Pipeline;
}
