// PostgreSQL Connection Pool
//
// Provides connection pooling for efficient resource management.
// Connections are reused to avoid reconnection overhead.
// Supports background reconnect thread and URI-based configuration.

const std = @import("std");
const Connection = @import("connection.zig").Connection;
const config_mod = @import("pool/config.zig");
const protocol = @import("../protocol/mod.zig");
const rls_mod = @import("rls.zig");
const raw_sql_mod = @import("raw_sql.zig");
const io_compat = @import("../runtime/io.zig");
const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
pub const PoolConfig = config_mod.PoolConfig;
pub const parseUri = config_mod.parseUri;
/// Callback type for scoped pool helpers (`withRls`, `withTenant`, etc.).
pub const ScopedPoolOp = *const fn (*PooledConnection) anyerror!void;

/// Internal pooled connection with timestamp
const PooledConn = struct {
    conn: Connection,
    created_at: i64,
    last_used: i64,
};

/// A connection borrowed from the pool.
/// Returns to pool when `release()` is called.
pub const PooledConnection = struct {
    conn: ?Connection,
    pool: *PgPool,
    created_at: i64,
    reset_on_release: bool = false,

    /// Get a reference to the underlying connection
    pub fn get(self: *PooledConnection) *Connection {
        return &self.conn.?;
    }

    /// Release the connection back to the pool
    pub fn release(self: *PooledConnection) void {
        if (self.conn) |conn_value| {
            var conn = conn_value;
            if (self.reset_on_release) {
                self.pool.resetScopedConnection(&conn) catch {
                    self.pool.discardConnection(conn);
                    self.conn = null;
                    self.reset_on_release = false;
                    return;
                };
            }
            self.pool.returnConnection(conn, self.created_at);
            self.conn = null;
            self.created_at = 0;
            self.reset_on_release = false;
        }
    }

    /// Close without returning to pool (for bad connections)
    pub fn discard(self: *PooledConnection) void {
        if (self.conn) |conn| {
            self.pool.discardConnection(conn);
            self.conn = null;
            self.created_at = 0;
            self.reset_on_release = false;
        }
    }
};

/// PostgreSQL connection pool
pub const PgPool = struct {
    config: PoolConfig,
    allocator: std.mem.Allocator,
    idle_connections: std.ArrayList(PooledConn),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    wait_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    active_count: usize,
    closed: bool,
    owns_config_strings: bool = false,
    owned_host: []u8 = "",
    owned_user: []u8 = "",
    owned_database: []u8 = "",
    owned_password: ?[]u8 = null,

    // Reconnect thread
    reconnect_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Create a new connection pool
    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !PgPool {
        try validatePoolConfig(&config);

        const owned_host = try allocator.dupe(u8, config.host);
        errdefer allocator.free(owned_host);
        const owned_user = try allocator.dupe(u8, config.user);
        errdefer allocator.free(owned_user);
        const owned_database = try allocator.dupe(u8, config.database);
        errdefer allocator.free(owned_database);
        const owned_password = if (config.password) |password|
            try allocator.dupe(u8, password)
        else
            null;
        errdefer if (owned_password) |password| allocator.free(password);

        var resolved_config = config;
        resolved_config.host = owned_host;
        resolved_config.user = owned_user;
        resolved_config.database = owned_database;
        resolved_config.password = owned_password;

        var pool = PgPool{
            .config = resolved_config,
            .allocator = allocator,
            .idle_connections = .empty,
            .mutex = .init,
            .cond = .init,
            .active_count = 0,
            .closed = false,
            .owns_config_strings = true,
            .owned_host = owned_host,
            .owned_user = owned_user,
            .owned_database = owned_database,
            .owned_password = owned_password,
        };

        // Create initial connections
        for (0..config.min_connections) |_| {
            const conn = try pool.createConnection();
            const now = nowMillis();
            try pool.idle_connections.append(allocator, .{
                .conn = conn,
                .created_at = now,
                .last_used = now,
            });
        }

        return pool;
    }

    /// Create pool from URI string
    pub fn initUri(allocator: std.mem.Allocator, uri: []const u8) !PgPool {
        const config = try parseUri(uri);
        return init(allocator, config);
    }

    /// Start background reconnect thread
    pub fn startReconnectThread(self: *PgPool) !void {
        self.mutex.lockUncancelable(io_compat.runtimeIo());
        defer self.mutex.unlock(io_compat.runtimeIo());

        if (self.closed) return error.PoolClosed;
        if (self.reconnect_thread != null) return;

        self.reconnect_thread = try std.Thread.spawn(.{}, reconnectLoop, .{self});
    }

    /// Stop reconnect thread
    pub fn stopReconnectThread(self: *PgPool) void {
        self.should_stop.store(true, .release);
        if (self.reconnect_thread) |thread| {
            thread.join();
            self.reconnect_thread = null;
        }
    }

    /// Background reconnect loop
    fn reconnectLoop(self: *PgPool) void {
        while (!self.should_stop.load(.acquire)) {
            self.maintainMinConnections();
            sleepMs(@intCast(self.config.reconnect_interval_ms));
        }
    }

    /// Ensure minimum connections are available
    fn maintainMinConnections(self: *PgPool) void {
        self.mutex.lockUncancelable(io_compat.runtimeIo());
        if (self.closed) {
            self.mutex.unlock(io_compat.runtimeIo());
            return;
        }
        const current = self.idle_connections.items.len + self.active_count;
        const needed = if (current < self.config.min_connections)
            self.config.min_connections - current
        else
            0;
        self.mutex.unlock(io_compat.runtimeIo());

        for (0..needed) |_| {
            const conn = self.createConnection() catch continue;
            self.mutex.lockUncancelable(io_compat.runtimeIo());
            if (self.closed) {
                self.mutex.unlock(io_compat.runtimeIo());
                var c = conn;
                c.close();
                break;
            }
            if (self.idle_connections.items.len + self.active_count >= self.config.max_connections) {
                self.mutex.unlock(io_compat.runtimeIo());
                var c = conn;
                c.close();
                break;
            }
            const now = nowMillis();
            self.idle_connections.append(self.allocator, .{
                .conn = conn,
                .created_at = now,
                .last_used = now,
            }) catch {
                var c = conn;
                c.close();
            };
            self.cond.signal(io_compat.runtimeIo());
            self.notifyWaiters();
            self.mutex.unlock(io_compat.runtimeIo());
        }
    }

    /// Clean up the pool
    pub fn deinit(self: *PgPool) void {
        self.closeGraceful(self.config.acquire_timeout_ms);
        self.freeOwnedConfigStrings();
    }

    /// Gracefully close pool: reject new acquires, wait for active borrowers,
    /// then close and free all idle connections.
    pub fn closeGraceful(self: *PgPool, drain_timeout_ms: i32) void {
        self.stopReconnectThread();

        self.mutex.lockUncancelable(io_compat.runtimeIo());
        self.closed = true;
        self.cond.broadcast(io_compat.runtimeIo());
        self.notifyWaiters();

        if (drain_timeout_ms > 0) {
            const started_at = nowMillis();
            while (self.active_count > 0) {
                const elapsed = nowMillis() - started_at;
                if (elapsed >= drain_timeout_ms) break;

                const remaining_ms = drain_timeout_ms - elapsed;
                const observed_epoch = self.wait_epoch.load(.acquire);
                self.mutex.unlock(io_compat.runtimeIo());
                self.waitForStateChange(observed_epoch, remaining_ms);
                self.mutex.lockUncancelable(io_compat.runtimeIo());
            }
        }

        defer self.mutex.unlock(io_compat.runtimeIo());

        for (self.idle_connections.items) |*pooled| {
            pooled.conn.close();
        }
        self.idle_connections.deinit(self.allocator);
        self.idle_connections = .empty;
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *PgPool) !PooledConnection {
        const started_at = nowMillis();

        while (true) {
            self.mutex.lockUncancelable(io_compat.runtimeIo());
            if (self.closed) {
                self.mutex.unlock(io_compat.runtimeIo());
                return error.PoolClosed;
            }
            const now = nowMillis();

            // Try to get an idle connection
            while (self.idle_connections.items.len > 0) {
                const pooled = self.idle_connections.pop() orelse break;

                // Check if connection is stale
                if (now - pooled.last_used > self.config.idle_timeout_ms) {
                    var stale = pooled.conn;
                    stale.close();
                    continue;
                }
                if (self.config.max_lifetime_ms) |max_lifetime_ms| {
                    if (now - pooled.created_at > max_lifetime_ms) {
                        var expired = pooled.conn;
                        expired.close();
                        continue;
                    }
                }

                self.active_count += 1;
                self.mutex.unlock(io_compat.runtimeIo());
                var conn = pooled.conn;
                if (self.config.test_on_acquire) {
                    self.executeSimple(&conn, raw_sql_mod.healthCheck()) catch {
                        self.discardConnection(conn);
                        continue;
                    };
                }
                return .{
                    .conn = conn,
                    .pool = self,
                    .created_at = pooled.created_at,
                    .reset_on_release = false,
                };
            }

            // No idle connections - create new if under limit
            if (self.active_count < self.config.max_connections) {
                self.active_count += 1;
                self.mutex.unlock(io_compat.runtimeIo());
                const created_at = nowMillis();
                var conn = self.createConnection() catch |err| {
                    self.mutex.lockUncancelable(io_compat.runtimeIo());
                    self.decrementActiveCount();
                    self.cond.signal(io_compat.runtimeIo());
                    self.notifyWaiters();
                    self.mutex.unlock(io_compat.runtimeIo());
                    return err;
                };
                if (self.config.test_on_acquire) {
                    self.executeSimple(&conn, raw_sql_mod.healthCheck()) catch {
                        self.discardConnection(conn);
                        continue;
                    };
                }

                return .{
                    .conn = conn,
                    .pool = self,
                    .created_at = created_at,
                    .reset_on_release = false,
                };
            }

            const elapsed = nowMillis() - started_at;
            if (elapsed >= self.config.acquire_timeout_ms) {
                self.mutex.unlock(io_compat.runtimeIo());
                return error.PoolAcquireTimeout;
            }

            const remaining_ms = self.config.acquire_timeout_ms - elapsed;
            const observed_epoch = self.wait_epoch.load(.acquire);
            self.mutex.unlock(io_compat.runtimeIo());
            self.waitForStateChange(observed_epoch, remaining_ms);
        }
    }

    /// Return a connection to the pool
    pub fn returnConnection(self: *PgPool, conn: Connection, created_at: i64) void {
        self.mutex.lockUncancelable(io_compat.runtimeIo());
        defer self.mutex.unlock(io_compat.runtimeIo());

        self.decrementActiveCount();
        defer {
            self.cond.signal(io_compat.runtimeIo());
            self.notifyWaiters();
        }

        if (self.closed) {
            var c = conn;
            c.close();
            return;
        }

        // Return to idle pool if under max
        if (self.idle_connections.items.len < self.config.max_connections) {
            self.idle_connections.append(self.allocator, .{
                .conn = conn,
                .created_at = created_at,
                .last_used = nowMillis(),
            }) catch {
                var c = conn;
                c.close();
            };
        } else {
            var c = conn;
            c.close();
        }
    }

    /// Close and drop an active connection without returning it to idle pool.
    fn discardConnection(self: *PgPool, conn: Connection) void {
        self.mutex.lockUncancelable(io_compat.runtimeIo());
        defer self.mutex.unlock(io_compat.runtimeIo());

        self.decrementActiveCount();
        self.cond.signal(io_compat.runtimeIo());
        self.notifyWaiters();
        var c = conn;
        c.close();
    }

    /// Get number of idle connections
    pub fn idleCount(self: *PgPool) usize {
        self.mutex.lockUncancelable(io_compat.runtimeIo());
        defer self.mutex.unlock(io_compat.runtimeIo());
        return self.idle_connections.items.len;
    }

    /// Get number of active (in-use) connections
    pub fn activeCount(self: *PgPool) usize {
        self.mutex.lockUncancelable(io_compat.runtimeIo());
        defer self.mutex.unlock(io_compat.runtimeIo());
        return self.active_count;
    }

    // ==================== RLS Scoped Acquisition ====================

    /// Acquire a connection and configure tenant/user/session RLS context.
    ///
    /// Connection is marked for auto-reset (`COMMIT`) on `release()`.
    pub fn acquireWithRls(self: *PgPool, ctx: rls_mod.RlsContext) !PooledConnection {
        const sql = try rls_mod.contextToSql(self.allocator, &ctx);
        defer self.allocator.free(sql);
        return try self.acquireWithScopedSql(sql);
    }

    /// Acquire with RLS context and statement timeout (milliseconds).
    pub fn acquireWithRlsTimeout(self: *PgPool, ctx: rls_mod.RlsContext, timeout_ms: u32) !PooledConnection {
        const sql = try rls_mod.contextToSqlWithTimeout(self.allocator, &ctx, timeout_ms);
        defer self.allocator.free(sql);
        return try self.acquireWithScopedSql(sql);
    }

    /// Acquire with RLS context, statement timeout, and optional lock timeout.
    pub fn acquireWithRlsTimeouts(
        self: *PgPool,
        ctx: rls_mod.RlsContext,
        statement_timeout_ms: u32,
        lock_timeout_ms: u32,
    ) !PooledConnection {
        const sql = try rls_mod.contextToSqlWithTimeouts(self.allocator, &ctx, statement_timeout_ms, lock_timeout_ms);
        defer self.allocator.free(sql);
        return try self.acquireWithScopedSql(sql);
    }

    /// Acquire a system-scoped connection (`RlsContext.empty()`).
    pub fn acquireSystem(self: *PgPool) !PooledConnection {
        return self.acquireWithRls(rls_mod.RlsContext.empty());
    }

    /// Acquire a global/platform-scoped connection (`RlsContext.global()`).
    pub fn acquireGlobal(self: *PgPool) !PooledConnection {
        return self.acquireWithRls(rls_mod.RlsContext.global());
    }

    /// Acquire a connection scoped to one tenant.
    pub fn acquireForTenant(self: *PgPool, tenant_id: []const u8) !PooledConnection {
        return self.acquireWithRls(rls_mod.RlsContext.tenant(tenant_id));
    }

    /// Run a callback with an RLS-scoped connection and always release it.
    pub fn withRls(self: *PgPool, ctx: rls_mod.RlsContext, op: ScopedPoolOp) !void {
        var pooled = try self.acquireWithRls(ctx);
        defer pooled.release();
        try op(&pooled);
    }

    /// Run a callback with `RlsContext.empty()`.
    pub fn withSystem(self: *PgPool, op: ScopedPoolOp) !void {
        return self.withRls(rls_mod.RlsContext.empty(), op);
    }

    /// Run a callback with `RlsContext.global()`.
    pub fn withGlobal(self: *PgPool, op: ScopedPoolOp) !void {
        return self.withRls(rls_mod.RlsContext.global(), op);
    }

    /// Run a callback with tenant-scoped context.
    pub fn withTenant(self: *PgPool, tenant_id: []const u8, op: ScopedPoolOp) !void {
        return self.withRls(rls_mod.RlsContext.tenant(tenant_id), op);
    }

    // ==================== Convenience Methods (AST-Native) ====================

    /// Execute a QAIL command (acquire, execute, release)
    /// Returns affected row count
    pub fn exec(self: *PgPool, cmd: *const @import("../ast/mod.zig").QailCmd) !u64 {
        var pooled = try self.acquire();

        const driver_mod = @import("driver.zig");
        var driver = driver_mod.PgDriver.init(pooled.conn.?, self.allocator);
        const result = driver.execute(cmd) catch |err| return finishDriverPoolError(&pooled, driver.conn, err);
        releaseDriverPoolSuccess(&pooled, driver.conn);
        return result;
    }

    /// Fetch all rows for a QAIL command (acquire, fetch, release)
    pub fn fetchAll(self: *PgPool, cmd: *const @import("../ast/mod.zig").QailCmd) ![]@import("row.zig").PgRow {
        var pooled = try self.acquire();

        const driver_mod = @import("driver.zig");
        var driver = driver_mod.PgDriver.init(pooled.conn.?, self.allocator);
        const rows = driver.fetchAll(cmd) catch |err| return finishDriverPoolError(&pooled, driver.conn, err);
        releaseDriverPoolSuccess(&pooled, driver.conn);
        return rows;
    }

    /// Fetch one row for a QAIL command (acquire, fetch, release)
    pub fn fetchOne(self: *PgPool, cmd: *const @import("../ast/mod.zig").QailCmd) !?@import("row.zig").PgRow {
        var pooled = try self.acquire();

        const driver_mod = @import("driver.zig");
        var driver = driver_mod.PgDriver.init(pooled.conn.?, self.allocator);
        const row = driver.fetchOne(cmd) catch |err| return finishDriverPoolError(&pooled, driver.conn, err);
        releaseDriverPoolSuccess(&pooled, driver.conn);
        return row;
    }

    /// Create a new connection using pool config
    fn createConnection(self: *PgPool) !Connection {
        var conn = try Connection.connectWithTimeout(
            self.allocator,
            self.config.host,
            self.config.port,
            self.config.connect_timeout_ms,
        );
        errdefer conn.close();

        try conn.startup(
            self.config.user,
            self.config.database,
            self.config.password,
        );

        return conn;
    }

    fn acquireWithScopedSql(self: *PgPool, sql: []const u8) !PooledConnection {
        var pooled = try self.acquire();
        errdefer pooled.discard();

        if (pooled.conn) |*conn| {
            try self.executeSimple(conn, sql);
        } else {
            return error.PoolConnectionUnavailable;
        }

        pooled.reset_on_release = true;
        return pooled;
    }

    fn resetScopedConnection(self: *PgPool, conn: *Connection) !void {
        try executeSimpleConn(self.allocator, conn, rls_mod.resetSql());
    }

    fn executeSimple(self: *PgPool, conn: *Connection, sql: []const u8) !void {
        try executeSimpleConn(self.allocator, conn, sql);
    }

    fn nowMillis() i64 {
        return std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds();
    }

    fn notifyWaiters(self: *PgPool) void {
        _ = self.wait_epoch.fetchAdd(1, .release);
        std.Io.futexWake(io_compat.runtimeIo(), u32, &self.wait_epoch.raw, std.math.maxInt(u32));
    }

    fn waitForStateChange(self: *PgPool, observed_epoch: u32, timeout_ms: i64) void {
        if (timeout_ms <= 0) return;
        std.Io.futexWaitTimeout(
            io_compat.runtimeIo(),
            u32,
            &self.wait_epoch.raw,
            observed_epoch,
            .{
                .duration = .{
                    .clock = .awake,
                    .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
                },
            },
        ) catch {};
    }

    fn sleepMs(ms: u64) void {
        if (ms == 0) return;
        std.Io.sleep(
            io_compat.runtimeIo(),
            std.Io.Duration.fromMilliseconds(@intCast(ms)),
            .awake,
        ) catch {};
    }

    fn decrementActiveCount(self: *PgPool) void {
        self.active_count -|= 1;
    }

    fn freeOwnedConfigStrings(self: *PgPool) void {
        if (!self.owns_config_strings) return;
        self.allocator.free(self.owned_host);
        self.allocator.free(self.owned_user);
        self.allocator.free(self.owned_database);
        if (self.owned_password) |password| self.allocator.free(password);

        self.owned_host = "";
        self.owned_user = "";
        self.owned_database = "";
        self.owned_password = null;
        self.owns_config_strings = false;
    }
};

fn executeSimpleConn(allocator: std.mem.Allocator, conn: *Connection, sql: []const u8) !void {
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .command_complete, .row_description, .data_row, .empty_query, .notice, .parameter_status, .notification => {},
            .ready_for_query => {
                var decoder = Decoder.init(msg.payload);
                const tx_status = try decoder.parseReadyForQuery();
                conn.ready = true;
                conn.in_transaction = tx_status == .in_transaction;
                return;
            },
            .error_response => {
                var decoder = Decoder.init(msg.payload);
                const err_info = try decoder.parseErrorResponse();
                std.debug.print("Pool scoped SQL error: {s}\n", .{err_info.message orelse "unknown"});
                return error.PoolScopedSqlFailed;
            },
            else => return error.UnexpectedBackendMessageType,
        }
    }
}

fn releaseDriverPoolSuccess(pooled: *PooledConnection, conn: Connection) void {
    pooled.conn = conn;
    pooled.release();
}

fn finishDriverPoolError(pooled: *PooledConnection, conn: Connection, err: anyerror) anyerror {
    pooled.conn = conn;
    if (poolErrorRequiresDiscard(err)) {
        pooled.discard();
    } else {
        pooled.release();
    }
    return err;
}

fn poolErrorRequiresDiscard(err: anyerror) bool {
    return switch (err) {
        error.ConnectionClosed,
        error.EndOfStream,
        error.ReadFailed,
        error.ReadTimeout,
        error.WriteTimeout,
        error.WouldBlock,
        error.IoUringOperationFailed,
        error.ServerError,
        error.UnexpectedBackendMessageType,
        error.UnexpectedStartupMessageType,
        error.InvalidMessageLength,
        error.MessageTooLarge,
        error.InvalidBackendMessagePayload,
        error.InvalidReadyForQueryPayload,
        error.InvalidReadyForQueryStatus,
        error.InvalidRowDescriptionPayload,
        error.InvalidDataRowPayload,
        error.InvalidDataRow,
        error.InvalidCommandCompletePayload,
        error.InvalidCommandCompleteTag,
        error.MalformedCommandCompleteTag,
        error.InvalidErrorResponsePayload,
        error.InvalidNotificationPayload,
        error.InvalidParameterStatusPayload,
        error.InvalidBackendKeyDataPayload,
        error.InvalidNegotiateProtocolVersionPayload,
        error.InvalidFormatCode,
        error.InvalidCopyState,
        error.InvalidCopyResponse,
        error.InvalidCopyData,
        error.CopyFailed,
        error.CopyDataTooLarge,
        error.InvalidReplicationCopyData,
        error.UnexpectedReplicationMessage,
        error.UnsupportedReplicationFormat,
        error.InvalidReplicationResponse,
        error.InvalidReplicationWalEnd,
        error.ReplicationStreamEnded,
        error.InvalidUtf8,
        error.UnexpectedCompletionCount,
        error.UnexpectedParseComplete,
        error.DuplicateParseComplete,
        error.ParseCompleteAfterBindComplete,
        error.ParseCompleteAfterCompletion,
        error.UnexpectedParameterDescription,
        error.ParameterDescriptionBeforeParseComplete,
        error.ParameterDescriptionAfterBindComplete,
        error.ParameterDescriptionAfterCompletion,
        error.DuplicateBindComplete,
        error.BindCompleteBeforeParseComplete,
        error.BindCompleteAfterCompletion,
        error.RowDescriptionAfterCompletion,
        error.RowDescriptionBeforeBindComplete,
        error.RowDescriptionBeforeParseComplete,
        error.NoDataAfterCompletion,
        error.UnexpectedNoDataAfterBindComplete,
        error.UnexpectedNoDataBeforeBindComplete,
        error.NoDataBeforeParseComplete,
        error.DataRowBeforeBindComplete,
        error.DataRowAfterCompletion,
        error.CompletionBeforeBindComplete,
        error.DuplicateCompletionMessage,
        error.ReadyForQueryBeforeParseComplete,
        error.ReadyForQueryBeforeBindComplete,
        error.ReadyForQueryBeforeCompletion,
        => true,
        else => false,
    };
}

fn validatePoolConfig(config: *const PoolConfig) !void {
    if (config.host.len == 0) {
        return error.InvalidPoolConfig;
    }
    if (config.user.len == 0) {
        return error.InvalidPoolConfig;
    }
    if (config.database.len == 0) {
        return error.InvalidPoolConfig;
    }
    if (config.max_connections == 0) {
        return error.InvalidPoolConfig;
    }
    if (config.min_connections > config.max_connections) {
        return error.InvalidPoolConfig;
    }
    if (config.idle_timeout_ms < 0) {
        return error.InvalidPoolConfig;
    }
    if (config.max_lifetime_ms) |max_lifetime_ms| {
        if (max_lifetime_ms <= 0) {
            return error.InvalidPoolConfig;
        }
    }
    if (config.acquire_timeout_ms <= 0) {
        return error.InvalidPoolConfig;
    }
    if (config.connect_timeout_ms <= 0) {
        return error.InvalidPoolConfig;
    }
    if (config.reconnect_interval_ms == 0) {
        return error.InvalidPoolConfig;
    }
}

// ==================== Tests ====================

test "PoolConfig defaults" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
    };
    try std.testing.expectEqual(@as(usize, 10), config.max_connections);
    try std.testing.expectEqual(@as(usize, 1), config.min_connections);
    try std.testing.expectEqual(@as(?i64, null), config.max_lifetime_ms);
    try std.testing.expectEqual(false, config.test_on_acquire);
    try std.testing.expectEqual(@as(i32, 10_000), config.connect_timeout_ms);
}

test "PgPool struct" {
    _ = PgPool;
    _ = PooledConnection;
}

test "pool error classification discards protocol unsafe errors only" {
    try std.testing.expect(poolErrorRequiresDiscard(error.UnexpectedBackendMessageType));
    try std.testing.expect(poolErrorRequiresDiscard(error.InvalidCopyState));
    try std.testing.expect(poolErrorRequiresDiscard(error.ConnectionClosed));
    try std.testing.expect(poolErrorRequiresDiscard(error.ReadyForQueryBeforeCompletion));
    try std.testing.expect(!poolErrorRequiresDiscard(error.QueryError));
    try std.testing.expect(!poolErrorRequiresDiscard(error.ExecuteError));
    try std.testing.expect(!poolErrorRequiresDiscard(error.InvalidIdentifier));
    try std.testing.expect(!poolErrorRequiresDiscard(error.ParameterCountMismatch));
}

test "PgPool.init duplicates config strings for owned lifetime" {
    const allocator = std.testing.allocator;
    const host = "localhost";
    const user = "test";
    const database = "testdb";

    const config = PoolConfig{
        .host = host,
        .port = 5432,
        .user = user,
        .database = database,
        .password = "secret",
        .max_connections = 1,
        .min_connections = 0,
    };

    var pool = try PgPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expect(pool.owns_config_strings);
    try std.testing.expect(pool.config.host.ptr != host.ptr);
    try std.testing.expect(pool.config.user.ptr != user.ptr);
    try std.testing.expect(pool.config.database.ptr != database.ptr);
    try std.testing.expect(pool.config.password != null);
    try std.testing.expect(pool.config.password.?.ptr != config.password.?.ptr);
}

test "validatePoolConfig rejects zero max_connections" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .max_connections = 0,
        .min_connections = 0,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects empty host" {
    const config = PoolConfig{
        .host = "",
        .port = 5432,
        .user = "test",
        .database = "testdb",
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects empty user" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "",
        .database = "testdb",
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects empty database" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "",
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects min_connections over max_connections" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .max_connections = 2,
        .min_connections = 3,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects zero acquire_timeout_ms" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .acquire_timeout_ms = 0,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects negative idle_timeout_ms" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .idle_timeout_ms = -1,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects non-positive max_lifetime_ms when configured" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .max_lifetime_ms = 0,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects zero connect_timeout_ms" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .connect_timeout_ms = 0,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "validatePoolConfig rejects zero reconnect_interval_ms" {
    const config = PoolConfig{
        .host = "localhost",
        .port = 5432,
        .user = "test",
        .database = "testdb",
        .reconnect_interval_ms = 0,
    };

    try std.testing.expectError(error.InvalidPoolConfig, validatePoolConfig(&config));
}

test "PgPool.acquire returns PoolClosed when already closed" {
    var pool = PgPool{
        .config = .{
            .host = "localhost",
            .port = 5432,
            .user = "test",
            .database = "testdb",
            .max_connections = 1,
            .min_connections = 0,
            .acquire_timeout_ms = 10,
            .connect_timeout_ms = 10,
            .reconnect_interval_ms = 1000,
        },
        .allocator = std.testing.allocator,
        .idle_connections = .empty,
        .mutex = .init,
        .cond = .init,
        .active_count = 0,
        .closed = true,
    };
    defer pool.idle_connections.deinit(pool.allocator);

    try std.testing.expectError(error.PoolClosed, pool.acquire());
}

test "PgPool.acquire returns PoolAcquireTimeout when saturated with no idle" {
    var pool = PgPool{
        .config = .{
            .host = "localhost",
            .port = 5432,
            .user = "test",
            .database = "testdb",
            .max_connections = 1,
            .min_connections = 0,
            .acquire_timeout_ms = 2,
            .connect_timeout_ms = 10,
            .reconnect_interval_ms = 1000,
        },
        .allocator = std.testing.allocator,
        .idle_connections = .empty,
        .mutex = .init,
        .cond = .init,
        .active_count = 1,
        .closed = false,
    };
    defer pool.idle_connections.deinit(pool.allocator);

    try std.testing.expectError(error.PoolAcquireTimeout, pool.acquire());
}
