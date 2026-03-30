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
const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
pub const PoolConfig = config_mod.PoolConfig;
pub const parseUri = config_mod.parseUri;
/// Callback type for scoped pool helpers (`withRls`, `withTenant`, etc.).
pub const ScopedPoolOp = *const fn (*PooledConnection) anyerror!void;

/// Internal pooled connection with timestamp
const PooledConn = struct {
    conn: Connection,
    last_used: i64,
};

/// A connection borrowed from the pool.
/// Returns to pool when `release()` is called.
pub const PooledConnection = struct {
    conn: ?Connection,
    pool: *PgPool,
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
            self.pool.returnConnection(conn);
            self.conn = null;
            self.reset_on_release = false;
        }
    }

    /// Close without returning to pool (for bad connections)
    pub fn discard(self: *PooledConnection) void {
        if (self.conn) |conn| {
            self.pool.discardConnection(conn);
            self.conn = null;
            self.reset_on_release = false;
        }
    }
};

/// PostgreSQL connection pool
pub const PgPool = struct {
    config: PoolConfig,
    allocator: std.mem.Allocator,
    idle_connections: std.ArrayList(PooledConn),
    mutex: std.Thread.Mutex,
    active_count: usize,

    // Reconnect thread
    reconnect_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Create a new connection pool
    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !PgPool {
        var pool = PgPool{
            .config = config,
            .allocator = allocator,
            .idle_connections = .{},
            .mutex = .{},
            .active_count = 0,
        };

        // Create initial connections
        for (0..config.min_connections) |_| {
            const conn = try pool.createConnection();
            try pool.idle_connections.append(allocator, .{
                .conn = conn,
                .last_used = std.time.milliTimestamp(),
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
            std.time.sleep(self.config.reconnect_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Ensure minimum connections are available
    fn maintainMinConnections(self: *PgPool) void {
        self.mutex.lock();
        const current = self.idle_connections.items.len + self.active_count;
        const needed = if (current < self.config.min_connections)
            self.config.min_connections - current
        else
            0;
        self.mutex.unlock();

        for (0..needed) |_| {
            const conn = self.createConnection() catch continue;
            self.mutex.lock();
            self.idle_connections.append(self.allocator, .{
                .conn = conn,
                .last_used = std.time.milliTimestamp(),
            }) catch {
                var c = conn;
                c.close();
            };
            self.mutex.unlock();
        }
    }

    /// Clean up the pool
    pub fn deinit(self: *PgPool) void {
        self.stopReconnectThread();

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.idle_connections.items) |*pooled| {
            pooled.conn.close();
        }
        self.idle_connections.deinit(self.allocator);
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *PgPool) !PooledConnection {
        self.mutex.lock();

        const now = std.time.milliTimestamp();

        // Try to get an idle connection
        while (self.idle_connections.items.len > 0) {
            const pooled = self.idle_connections.pop() orelse break;

            // Check if connection is stale
            if (now - pooled.last_used > self.config.idle_timeout_ms) {
                var conn = pooled.conn;
                conn.close();
                continue;
            }

            self.active_count += 1;
            self.mutex.unlock();
            return .{
                .conn = pooled.conn,
                .pool = self,
                .reset_on_release = false,
            };
        }

        // No idle connections - create new if under limit
        if (self.active_count < self.config.max_connections) {
            self.active_count += 1;
            self.mutex.unlock();
            const conn = self.createConnection() catch |err| {
                self.mutex.lock();
                self.active_count -= 1;
                self.mutex.unlock();
                return err;
            };

            return .{
                .conn = conn,
                .pool = self,
                .reset_on_release = false,
            };
        }

        // Pool exhausted
        self.mutex.unlock();
        return error.PoolExhausted;
    }

    /// Return a connection to the pool
    pub fn returnConnection(self: *PgPool, conn: Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.active_count -= 1;

        // Return to idle pool if under max
        if (self.idle_connections.items.len < self.config.max_connections) {
            self.idle_connections.append(self.allocator, .{
                .conn = conn,
                .last_used = std.time.milliTimestamp(),
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
        self.mutex.lock();
        defer self.mutex.unlock();

        self.active_count -= 1;
        var c = conn;
        c.close();
    }

    /// Get number of idle connections
    pub fn idleCount(self: *PgPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.idle_connections.items.len;
    }

    /// Get number of active (in-use) connections
    pub fn activeCount(self: *PgPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
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
        defer pooled.release();

        const driver_mod = @import("driver.zig");
        var driver = driver_mod.PgDriver.init(pooled.conn.?, self.allocator);
        return try driver.execute(cmd);
    }

    /// Fetch all rows for a QAIL command (acquire, fetch, release)
    pub fn fetchAll(self: *PgPool, cmd: *const @import("../ast/mod.zig").QailCmd) ![]@import("row.zig").PgRow {
        var pooled = try self.acquire();
        defer pooled.release();

        const driver_mod = @import("driver.zig");
        var driver = driver_mod.PgDriver.init(pooled.conn.?, self.allocator);
        return try driver.fetchAll(cmd);
    }

    /// Fetch one row for a QAIL command (acquire, fetch, release)
    pub fn fetchOne(self: *PgPool, cmd: *const @import("../ast/mod.zig").QailCmd) !?@import("row.zig").PgRow {
        var pooled = try self.acquire();
        defer pooled.release();

        const driver_mod = @import("driver.zig");
        var driver = driver_mod.PgDriver.init(pooled.conn.?, self.allocator);
        return try driver.fetchOne(cmd);
    }

    /// Create a new connection using pool config
    fn createConnection(self: *PgPool) !Connection {
        var conn = try Connection.connect(
            self.allocator,
            self.config.host,
            self.config.port,
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
            else => {},
        }
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
}

test "PgPool struct" {
    _ = PgPool;
    _ = PooledConnection;
}
