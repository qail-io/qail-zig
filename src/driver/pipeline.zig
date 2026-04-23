// PostgreSQL Pipelining API
//
// High-performance pipelining methods for batch query execution.
// Matches qail-pg (Rust) pipelining feature set.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const protocol = @import("../protocol/mod.zig");
const conn_mod = @import("connection.zig");
const raw_policy = @import("raw_policy.zig");
const row_mod = @import("row.zig");
const extended_flow_mod = @import("extended_flow.zig");

const QailCmd = ast.QailCmd;
const AstEncoder = protocol.AstEncoder;
const Encoder = protocol.Encoder;
const BackendMessage = protocol.BackendMessage;
const Connection = conn_mod.Connection;
const PgRow = row_mod.PgRow;
const Decoder = protocol.Decoder;
const ExtendedFlowConfig = extended_flow_mod.ExtendedFlowConfig;
const ExtendedFlowTracker = extended_flow_mod.ExtendedFlowTracker;

const MISSING_PREPARED_STMT_SQLSTATE = "26000";
const CACHED_PLAN_REPLANNED_SQLSTATE = "0A000";
const PREPARED_STMT_ALREADY_EXISTS_SQLSTATE = "42P05";
const CACHED_PLAN_REPLANNED_MSG = "cached plan must be replanned";
const PREPARED_STMT_MSG = "prepared statement";
const ALREADY_EXISTS_MSG = "already exists";
const max_wire_message_len: usize = std.math.maxInt(i32);

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

/// Borrowed via `Pipeline.lastFailure()` until the next pipeline operation.
pub const PipelineFailure = struct {
    /// Number of queries the caller expected to complete in this batch.
    expected_queries: usize,
    /// Number of queries that completed before PostgreSQL sent ErrorResponse.
    completed_queries: usize,
    /// Zero-based index of the failing query within the submitted batch.
    failed_query_index: usize,
    /// Number of queued queries PostgreSQL discarded after the failure.
    skipped_queries_after_failure: usize,
    /// True when the driver drained to ReadyForQuery after the error.
    drained_to_ready: bool,
    /// `true` for qail's single-Sync pipeline helpers, `null` for raw bytes.
    cycle_rolled_back: ?bool,
    sqlstate: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,

    pub fn deinit(self: *PipelineFailure, allocator: std.mem.Allocator) void {
        freeOwnedOptionalSlice(allocator, &self.sqlstate);
        freeOwnedOptionalSlice(allocator, &self.message);
        freeOwnedOptionalSlice(allocator, &self.detail);
        freeOwnedOptionalSlice(allocator, &self.hint);
    }
};

/// Pipeline execution context - holds shared state for pipelining operations
pub const Pipeline = struct {
    conn: *Connection,
    encoder: Encoder,
    allocator: std.mem.Allocator,
    stmt_cache: std.StringHashMap(PreparedStatement),
    last_failure: ?PipelineFailure = null,

    pub fn init(conn: *Connection, allocator: std.mem.Allocator) Pipeline {
        return .{
            .conn = conn,
            .encoder = Encoder.init(allocator),
            .allocator = allocator,
            .stmt_cache = std.StringHashMap(PreparedStatement).init(allocator),
            .last_failure = null,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.clearLastFailure();
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

    pub fn lastFailure(self: *const Pipeline) ?*const PipelineFailure {
        if (self.last_failure == null) return null;
        return &self.last_failure.?;
    }

    pub fn clearLastFailure(self: *Pipeline) void {
        if (self.last_failure) |*failure| {
            failure.deinit(self.allocator);
            self.last_failure = null;
        }
    }

    /// Get a cached prepared statement or create a new one.
    /// Cached statements are automatically reused across calls.
    pub fn getOrPrepare(self: *Pipeline, sql: []const u8) !*PreparedStatement {
        self.clearLastFailure();
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
        self.clearLastFailure();
        // Generate unique statement name from SQL hash
        const hash = std.hash.Wyhash.hash(0, sql);
        const name = try std.fmt.allocPrint(self.allocator, "s{x}", .{hash});
        errdefer self.allocator.free(name);

        const sql_copy = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_copy);

        // Send Parse + Sync in a single write (was 2 separate sends — bug)
        self.encoder.reset();
        try self.encoder.encodeParse(name, sql, &.{});
        try self.encoder.appendSync();
        try self.conn.send(self.encoder.getWritten());

        // Wait for ParseComplete + ReadyForQuery
        self.readUntilReady() catch |err| switch (err) {
            // Statement name already exists server-side; treat as reusable.
            error.PreparedStatementAlreadyExists => {},
            else => return err,
        };

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
        self.clearLastFailure();
        try raw_policy.rejectPublicRuntimeCmds(cmds);

        var ast_encoder = AstEncoder.init(self.allocator);
        defer ast_encoder.deinit();

        // Encode all ASTs to wire protocol (appendQuery does NOT reset buffer)
        for (cmds) |cmd| {
            try ast_encoder.appendQuery(cmd);
        }
        // Single Sync at end (one ReadyForQuery for the whole batch)
        try ast_encoder.appendSync();

        // Send all at once
        try self.conn.send(ast_encoder.getWritten());

        // Count completions
        return try self.countCompletions(cmds.len, ExtendedFlowConfig.parseBindExecute(true));
    }

    /// Execute multiple QailCmd ASTs and return all results.
    pub fn pipelineAst(
        self: *Pipeline,
        cmds: []const *const QailCmd,
    ) ![][]PgRow {
        if (cmds.len == 0) return &.{};
        self.clearLastFailure();
        try raw_policy.rejectPublicRuntimeCmds(cmds);

        var ast_encoder = AstEncoder.init(self.allocator);
        defer ast_encoder.deinit();

        // Encode all ASTs (appendQuery does NOT reset buffer)
        for (cmds) |cmd| {
            try ast_encoder.appendQuery(cmd);
        }
        // Single Sync at end
        try ast_encoder.appendSync();

        // Send all at once
        try self.conn.send(ast_encoder.getWritten());

        // Collect results
        return try self.collectResults(cmds.len, ExtendedFlowConfig.parseBindExecute(true));
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
        self.clearLastFailure();

        // Pre-allocate buffer for ALL messages (Bind+Execute per query + Sync)
        // Estimate: ~50 bytes per query for SELECT 1 type queries
        var buffer: std.ArrayList(u8) = .empty;
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
        return try self.countCompletions(params_batch.len, ExtendedFlowConfig.parseBindExecute(false));
    }

    /// Execute a prepared statement multiple times and return all results.
    pub fn pipelinePreparedResults(
        self: *Pipeline,
        stmt: *const PreparedStatement,
        params_batch: []const []const ?[]const u8,
    ) ![][]PgRow {
        if (params_batch.len == 0) return &.{};
        self.clearLastFailure();

        // Pre-allocate buffer for ALL messages
        var buffer: std.ArrayList(u8) = .empty;
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
        return try self.collectResults(params_batch.len, ExtendedFlowConfig.parseBindExecute(false));
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
        self.clearLastFailure();
        // Send raw bytes directly (no encoding overhead)
        try self.conn.send(wire_bytes);

        // Count completions
        return try self.countCompletionsRaw(expected_queries);
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
        self.clearLastFailure();

        // Pre-allocate buffer for ALL messages
        var buffer: std.ArrayList(u8) = .empty;
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
        return try self.collectUltraResults(params_batch.len, ExtendedFlowConfig.parseBindExecute(false));
    }

    /// Internal: collect 2-column result pairs
    fn collectUltraResults(self: *Pipeline, expected: usize, flow_cfg: ExtendedFlowConfig) ![][2]?[]const u8 {
        var results: std.ArrayList([2]?[]const u8) = .empty;
        errdefer results.deinit(self.allocator);
        var flow = ExtendedFlowTracker.init(flow_cfg);
        const enforce_order = expected <= 1;

        while (true) {
            const msg = try self.conn.readMessageRawFast();
            if (enforce_order) {
                try self.validateExtendedFlowMsgType(&flow, msg.msg_type, false);
            }

            switch (msg.msg_type) {
                'D' => {
                    const pair = try parseDataRowFirstTwoPayload(msg.payload);
                    try results.append(self.allocator, pair);
                },
                'C', '2', 'n' => {},
                'Z' => {
                    if (results.items.len >= expected or results.items.len > 0) {
                        return try results.toOwnedSlice(self.allocator);
                    }
                },
                'E' => {
                    const retryable = isPreparedStatementRetryablePayload(msg.payload);
                    const drained = self.drainUntilReadyAfterError() catch false;
                    captureLastFailure(self, msg.payload, results.items.len, expected, true, drained);
                    if (retryable) {
                        self.clearCache();
                        return error.PreparedStatementRetryable;
                    }
                    return error.QueryError;
                },
                'A', 'N', 'S' => {},
                else => return error.UnexpectedBackendMessageType,
            }
        }
    }

    // ==================== Direct Buffer Encoding (for batching) ====================

    fn encodeBind(self: *Pipeline, buffer: *std.ArrayList(u8), portal: []const u8, stmt_name: []const u8, params: []const ?[]const u8) !void {
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
                try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, try toWireI32Len(p.len))));
                try buffer.appendSlice(self.allocator, p);
            } else {
                try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, -1)));
            }
        }

        try buffer.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, 0))); // result format codes
    }

    fn encodeExecute(self: *Pipeline, buffer: *std.ArrayList(u8), portal: []const u8, max_rows: u32) !void {
        var msg_len_usize: usize = 0;
        try addLenChecked(&msg_len_usize, 4);
        try addCStringLenChecked(&msg_len_usize, portal);
        try addLenChecked(&msg_len_usize, 4);
        const msg_len = try toWireLen(msg_len_usize);
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

    // ==================== Internal Helpers ====================

    /// Count query completions without parsing results
    fn countCompletions(self: *Pipeline, expected: usize, flow_cfg: ExtendedFlowConfig) !usize {
        var completed: usize = 0;
        var flow = ExtendedFlowTracker.init(flow_cfg);
        const enforce_order = expected <= 1;

        while (true) {
            const msg = try self.conn.readMessageRawFast();
            if (enforce_order) {
                try self.validateExtendedFlowMsgType(&flow, msg.msg_type, false);
            }

            switch (msg.msg_type) {
                '2', '1', 'T', 'D' => {},
                'C' => completed += 1,
                'n' => completed += 1,
                'Z' => {
                    if (completed >= expected) return completed;
                },
                'E' => {
                    const retryable = isPreparedStatementRetryablePayload(msg.payload);
                    const drained = self.drainUntilReadyAfterError() catch false;
                    captureLastFailure(self, msg.payload, completed, expected, true, drained);
                    if (retryable) {
                        self.clearCache();
                        return error.PreparedStatementRetryable;
                    }
                    return error.QueryError;
                },
                'A', 'N', 'S' => {},
                else => return error.UnexpectedBackendMessageType,
            }
        }
    }

    /// Count completions for raw wire bytes without strict flow assumptions.
    fn countCompletionsRaw(self: *Pipeline, expected: usize) !usize {
        var completed: usize = 0;

        while (true) {
            const msg = try self.conn.readMessageRawFast();
            switch (msg.msg_type) {
                '2', '1', 'T', 'D' => {},
                'C' => completed += 1,
                'n' => completed += 1,
                'Z' => {
                    if (completed >= expected) return completed;
                },
                'E' => {
                    const retryable = isPreparedStatementRetryablePayload(msg.payload);
                    const drained = self.drainUntilReadyAfterError() catch false;
                    captureLastFailure(self, msg.payload, completed, expected, null, drained);
                    if (retryable) {
                        self.clearCache();
                        return error.PreparedStatementRetryable;
                    }
                    return error.QueryError;
                },
                'A', 'N', 'S' => {},
                else => return error.UnexpectedBackendMessageType,
            }
        }
    }

    /// Collect full results from pipeline
    fn collectResults(self: *Pipeline, expected: usize, flow_cfg: ExtendedFlowConfig) ![][]PgRow {
        var all_results: std.ArrayList([]PgRow) = .empty;
        errdefer {
            for (all_results.items) |rows| {
                for (rows) |*row| {
                    row.deinit();
                }
                self.allocator.free(rows);
            }
            all_results.deinit(self.allocator);
        }

        var current_rows: std.ArrayList(PgRow) = .empty;
        errdefer {
            for (current_rows.items) |*row| {
                row.deinit();
            }
            current_rows.deinit(self.allocator);
        }

        var field_names_template: []const []const u8 = &.{};
        errdefer if (field_names_template.len > 0) PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
        var flow = ExtendedFlowTracker.init(flow_cfg);
        const enforce_order = expected <= 1;

        while (true) {
            const msg = try self.conn.readMessage();
            if (enforce_order) {
                try self.validateExtendedFlow(&flow, msg.msg_type, false);
            }

            switch (msg.msg_type) {
                .bind_complete, .parse_complete => {},
                .row_description => {
                    var decoder = protocol.Decoder.init(msg.payload);
                    const fields = try decoder.parseRowDescription(self.allocator);
                    defer self.allocator.free(fields);

                    if (field_names_template.len > 0) {
                        PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
                        field_names_template = &.{};
                    }

                    var field_names = try self.allocator.alloc([]const u8, fields.len);
                    var copied: usize = 0;
                    errdefer {
                        for (field_names[0..copied]) |name| self.allocator.free(name);
                        self.allocator.free(field_names);
                    }
                    for (fields, 0..) |fd, i| {
                        field_names[i] = try self.allocator.dupe(u8, fd.name);
                        copied += 1;
                    }
                    field_names_template = field_names;
                },
                .data_row => {
                    var decoder = protocol.Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRowOwned(self.allocator);
                    const row = try PgRow.initOwned(self.allocator, columns, field_names_template);

                    try current_rows.append(self.allocator, row);
                },
                .command_complete => {
                    try all_results.append(self.allocator, try current_rows.toOwnedSlice(self.allocator));
                    current_rows = .empty;
                },
                .no_data => {
                    const empty = try self.allocator.alloc(PgRow, 0);
                    try all_results.append(self.allocator, empty);
                },
                .ready_for_query => {
                    if (all_results.items.len >= expected) {
                        if (field_names_template.len > 0) {
                            PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
                            field_names_template = &.{};
                        }
                        return try all_results.toOwnedSlice(self.allocator);
                    }
                },
                .error_response => {
                    const retryable = isPreparedStatementRetryablePayload(msg.payload);
                    const drained = self.drainUntilReadyAfterError() catch false;
                    captureLastFailure(self, msg.payload, all_results.items.len, expected, true, drained);
                    if (retryable) {
                        self.clearCache();
                        return error.PreparedStatementRetryable;
                    }
                    return error.QueryError;
                },
                .notification, .notice, .parameter_status => {},
                else => return error.UnexpectedBackendMessageType,
            }
        }
    }

    /// Read messages until ReadyForQuery
    fn readUntilReady(self: *Pipeline) !void {
        var flow = ExtendedFlowTracker.init(ExtendedFlowConfig.parseOnly(true));
        while (true) {
            const msg = try self.conn.readMessage();
            try self.validateExtendedFlow(&flow, msg.msg_type, false);
            switch (msg.msg_type) {
                .parse_complete => {},
                .ready_for_query => return,
                .error_response => {
                    const already_exists = isPreparedStatementAlreadyExistsPayload(msg.payload);
                    const retryable = isPreparedStatementRetryablePayload(msg.payload);
                    _ = self.drainUntilReadyAfterError() catch {};

                    if (already_exists) return error.PreparedStatementAlreadyExists;
                    if (retryable) {
                        self.clearCache();
                        return error.PreparedStatementRetryable;
                    }
                    return error.ServerError;
                },
                .notification, .notice, .parameter_status => {},
                else => return error.UnexpectedBackendMessageType,
            }
        }
    }

    fn drainUntilReadyAfterError(self: *Pipeline) !bool {
        while (true) {
            const msg = try self.conn.readMessage();
            if (!isPipelineDrainAllowedMessage(msg.msg_type)) return error.UnexpectedBackendMessageType;
            if (msg.msg_type == .ready_for_query) return true;
        }
    }

    fn validateExtendedFlow(
        self: *Pipeline,
        flow: *ExtendedFlowTracker,
        msg_type: BackendMessage,
        error_pending: bool,
    ) !void {
        flow.validate(msg_type, error_pending) catch |err| {
            _ = self.drainUntilReadyAfterError() catch {};
            return err;
        };
    }

    fn validateExtendedFlowMsgType(
        self: *Pipeline,
        flow: *ExtendedFlowTracker,
        msg_type: u8,
        error_pending: bool,
    ) !void {
        flow.validateMsgType(msg_type, error_pending) catch |err| {
            _ = self.drainUntilReadyAfterError() catch {};
            return err;
        };
    }
};

fn freeOwnedOptionalSlice(allocator: std.mem.Allocator, maybe_slice: *?[]const u8) void {
    if (maybe_slice.*) |slice| allocator.free(slice);
    maybe_slice.* = null;
}

fn dupeOptionalSliceBestEffort(allocator: std.mem.Allocator, maybe_slice: ?[]const u8) ?[]const u8 {
    const slice = maybe_slice orelse return null;
    return allocator.dupe(u8, slice) catch null;
}

fn isPipelineSessionNoise(msg_type: BackendMessage) bool {
    return msg_type == .notification or msg_type == .notice or msg_type == .parameter_status;
}

fn isPipelineDrainAllowedMessage(msg_type: BackendMessage) bool {
    return msg_type == .ready_for_query or msg_type == .error_response or isPipelineSessionNoise(msg_type);
}

fn isPreparedStatementRetryablePayload(payload: []const u8) bool {
    var decoder = Decoder.init(payload);
    const err = decoder.parseErrorResponse() catch return false;

    if (err.code) |sqlstate| {
        if (std.ascii.eqlIgnoreCase(sqlstate, MISSING_PREPARED_STMT_SQLSTATE)) return true;
        if (std.ascii.eqlIgnoreCase(sqlstate, CACHED_PLAN_REPLANNED_SQLSTATE)) {
            if (err.message) |msg| return containsAsciiIgnoreCase(msg, CACHED_PLAN_REPLANNED_MSG);
            return false;
        }
    }

    if (err.message) |msg| return containsAsciiIgnoreCase(msg, CACHED_PLAN_REPLANNED_MSG);
    return false;
}

fn isPreparedStatementAlreadyExistsPayload(payload: []const u8) bool {
    var decoder = Decoder.init(payload);
    const err = decoder.parseErrorResponse() catch return false;

    if (err.code) |sqlstate| {
        if (!std.ascii.eqlIgnoreCase(sqlstate, PREPARED_STMT_ALREADY_EXISTS_SQLSTATE)) return false;
    } else {
        return false;
    }

    const msg = err.message orelse return false;
    return containsAsciiIgnoreCase(msg, PREPARED_STMT_MSG) and containsAsciiIgnoreCase(msg, ALREADY_EXISTS_MSG);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn captureLastFailure(
    self: *Pipeline,
    payload: []const u8,
    completed_queries: usize,
    expected_queries: usize,
    cycle_rolled_back: ?bool,
    drained_to_ready: bool,
) void {
    const failed_query_index = if (completed_queries < expected_queries) completed_queries else expected_queries;
    const skipped_queries_after_failure = if (completed_queries + 1 < expected_queries)
        expected_queries - completed_queries - 1
    else
        0;

    var failure = PipelineFailure{
        .expected_queries = expected_queries,
        .completed_queries = completed_queries,
        .failed_query_index = failed_query_index,
        .skipped_queries_after_failure = skipped_queries_after_failure,
        .drained_to_ready = drained_to_ready,
        .cycle_rolled_back = cycle_rolled_back,
    };

    var decoder = Decoder.init(payload);
    const err_info = decoder.parseErrorResponse() catch protocol.wire.ErrorInfo{};
    failure.sqlstate = dupeOptionalSliceBestEffort(self.allocator, err_info.code);
    failure.message = dupeOptionalSliceBestEffort(self.allocator, err_info.message);
    failure.detail = dupeOptionalSliceBestEffort(self.allocator, err_info.detail);
    failure.hint = dupeOptionalSliceBestEffort(self.allocator, err_info.hint);

    self.last_failure = failure;
}

fn parseDataRowFirstTwoPayload(payload: []const u8) ![2]?[]const u8 {
    if (payload.len < 2) return error.InvalidDataRow;
    const col_count: usize = @intCast(std.mem.readInt(u16, payload[0..2], .big));

    var pos: usize = 2;
    var pair: [2]?[]const u8 = .{ null, null };

    for (0..col_count) |i| {
        if (pos + 4 > payload.len) return error.InvalidDataRow;
        const len = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;

        if (len == -1) {
            if (i < 2) pair[i] = null;
            continue;
        }
        if (len < -1) return error.InvalidDataRow;

        const ulen: usize = @intCast(len);
        const end = std.math.add(usize, pos, ulen) catch return error.InvalidDataRow;
        if (end > payload.len) return error.InvalidDataRow;
        if (i < 2) pair[i] = payload[pos..end];
        pos = end;
    }

    if (pos != payload.len) return error.InvalidDataRow;
    return pair;
}

// ==================== Tests ====================

test "PreparedStatement struct" {
    _ = PreparedStatement;
}

test "Pipeline struct" {
    _ = Pipeline;
}

test "pipeline hardening: retryable prepared statement payload detection" {
    const payload = [_]u8{
        'S', 'E', 'R', 'R', 'O', 'R', 0,
        'C', '2', '6', '0', '0', '0', 0,
        'M', 'p', 'r', 'e', 'p', 'a', 'r',
        'e', 'd', ' ', 's', 't', 'a', 't',
        'e', 'm', 'e', 'n', 't', ' ', '"',
        's', '1', '"', ' ', 'd', 'o', 'e',
        's', ' ', 'n', 'o', 't', ' ', 'e',
        'x', 'i', 's', 't', 0,   0,
    };
    try std.testing.expect(isPreparedStatementRetryablePayload(&payload));
}

test "pipeline hardening: already-exists prepared statement payload detection" {
    const payload = [_]u8{
        'S', 'E', 'R', 'R', 'O', 'R', 0,
        'C', '4', '2', 'P', '0', '5', 0,
        'M', 'p', 'r', 'e', 'p', 'a', 'r',
        'e', 'd', ' ', 's', 't', 'a', 't',
        'e', 'm', 'e', 'n', 't', ' ', '"',
        's', '1', '"', ' ', 'a', 'l', 'r',
        'e', 'a', 'd', 'y', ' ', 'e', 'x',
        'i', 's', 't', 's', 0,   0,
    };
    try std.testing.expect(isPreparedStatementAlreadyExistsPayload(&payload));
    try std.testing.expect(!isPreparedStatementRetryablePayload(&payload));
}

test "pipeline hardening: drain allowlist rejects unexpected message types" {
    try std.testing.expect(isPipelineDrainAllowedMessage(.ready_for_query));
    try std.testing.expect(isPipelineDrainAllowedMessage(.error_response));
    try std.testing.expect(isPipelineDrainAllowedMessage(.notification));
    try std.testing.expect(isPipelineDrainAllowedMessage(.notice));
    try std.testing.expect(isPipelineDrainAllowedMessage(.parameter_status));
    try std.testing.expect(!isPipelineDrainAllowedMessage(.data_row));
    try std.testing.expect(!isPipelineDrainAllowedMessage(.command_complete));
}

test "pipeline hardening: direct bind rejects too many parameters" {
    var pipeline = Pipeline{
        .conn = @ptrFromInt(@alignOf(Connection)),
        .encoder = Encoder.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .stmt_cache = std.StringHashMap(PreparedStatement).init(std.testing.allocator),
    };
    defer pipeline.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    const too_many_count = @as(usize, std.math.maxInt(i16)) + 1;
    const params = try std.testing.allocator.alloc(?[]const u8, too_many_count);
    defer std.testing.allocator.free(params);
    for (params) |*p| p.* = null;

    try std.testing.expectError(error.TooManyParameters, pipeline.encodeBind(&buffer, "", "stmt", params));
}

test "pipeline hardening: direct bind rejects oversized parameter payload" {
    var pipeline = Pipeline{
        .conn = @ptrFromInt(@alignOf(Connection)),
        .encoder = Encoder.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .stmt_cache = std.StringHashMap(PreparedStatement).init(std.testing.allocator),
    };
    defer pipeline.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_param = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];
    const params = [_]?[]const u8{huge_param};

    try std.testing.expectError(error.MessageTooLarge, pipeline.encodeBind(&buffer, "", "stmt", &params));
}

test "pipeline hardening: direct execute rejects oversized portal name" {
    var pipeline = Pipeline{
        .conn = @ptrFromInt(@alignOf(Connection)),
        .encoder = Encoder.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .stmt_cache = std.StringHashMap(PreparedStatement).init(std.testing.allocator),
    };
    defer pipeline.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_portal = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.MessageTooLarge, pipeline.encodeExecute(&buffer, huge_portal, 0));
}

test "pipeline hardening: captures last failure metadata" {
    var pipeline = Pipeline{
        .conn = @ptrFromInt(@alignOf(Connection)),
        .encoder = Encoder.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .stmt_cache = std.StringHashMap(PreparedStatement).init(std.testing.allocator),
    };
    defer pipeline.deinit();

    const payload = [_]u8{
        'S', 'E', 'R', 'R', 'O', 'R', 0,
        'C', '2', '2', 'P', '0', '2', 0,
        'M', 'i', 'n', 'v', 'a', 'l', 'i',
        'd', ' ', 'i', 'n', 'p', 'u', 't',
        ' ', 's', 'y', 'n', 't', 'a', 'x',
        ' ', 'f', 'o', 'r', ' ', 't', 'y',
        'p', 'e', ' ', 'i', 'n', 't', 'e',
        'g', 'e', 'r', 0,   'D', 'f', 'a',
        'i', 'l', 'i', 'n', 'g', ' ', 'r',
        'o', 'w', 0,   'H', 'u', 's', 'e',
        ' ', 'a', ' ', 'v', 'a', 'l', 'i',
        'd', ' ', 'n', 'u', 'm', 'b', 'e',
        'r', 0,   0,
    };

    captureLastFailure(&pipeline, &payload, 1, 3, true, true);

    const failure = pipeline.lastFailure() orelse return error.ExpectedPipelineFailureMetadata;
    try std.testing.expectEqual(@as(usize, 3), failure.expected_queries);
    try std.testing.expectEqual(@as(usize, 1), failure.completed_queries);
    try std.testing.expectEqual(@as(usize, 1), failure.failed_query_index);
    try std.testing.expectEqual(@as(usize, 1), failure.skipped_queries_after_failure);
    try std.testing.expect(failure.drained_to_ready);
    try std.testing.expectEqual(@as(?bool, true), failure.cycle_rolled_back);
    try std.testing.expectEqualStrings("22P02", failure.sqlstate.?);
    try std.testing.expectEqualStrings("invalid input syntax for type integer", failure.message.?);
    try std.testing.expectEqualStrings("failing row", failure.detail.?);
    try std.testing.expectEqualStrings("use a valid number", failure.hint.?);

    pipeline.clearLastFailure();
    try std.testing.expect(pipeline.lastFailure() == null);
}
