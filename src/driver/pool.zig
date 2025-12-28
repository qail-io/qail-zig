// PostgreSQL Connection Pool
//
// Provides connection pooling for efficient resource management.
// Connections are reused to avoid reconnection overhead.
// Supports background reconnect thread and URI-based configuration.

const std = @import("std");
const Connection = @import("connection.zig").Connection;

/// Connection pool configuration
pub const PoolConfig = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    database: []const u8,
    password: ?[]const u8 = null,
    max_connections: usize = 10,
    min_connections: usize = 1,
    idle_timeout_ms: i64 = 600_000, // 10 minutes
    acquire_timeout_ms: i32 = 30_000, // 30 seconds
    reconnect_interval_ms: u64 = 5_000, // 5 seconds
};

/// Parse PostgreSQL connection URI
/// Format: postgresql://user:password@host:port/database
pub fn parseUri(uri: []const u8) !PoolConfig {
    // Simple parser for postgresql:// URIs
    const prefix = "postgresql://";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return error.InvalidUri;
    }

    const body = uri[prefix.len..];

    // Extract user:password@host:port/database
    var user: []const u8 = "postgres";
    var password: ?[]const u8 = null;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 5432;
    var database: []const u8 = "postgres";

    // Find @ separator (user:pass before, host:port/db after)
    if (std.mem.indexOf(u8, body, "@")) |at_pos| {
        const auth = body[0..at_pos];
        const rest = body[at_pos + 1 ..];

        // Parse user:password
        if (std.mem.indexOf(u8, auth, ":")) |colon_pos| {
            user = auth[0..colon_pos];
            password = auth[colon_pos + 1 ..];
        } else {
            user = auth;
        }

        // Parse host:port/database
        if (std.mem.indexOf(u8, rest, "/")) |slash_pos| {
            const host_port = rest[0..slash_pos];
            database = rest[slash_pos + 1 ..];

            if (std.mem.indexOf(u8, host_port, ":")) |hp_colon| {
                host = host_port[0..hp_colon];
                port = std.fmt.parseInt(u16, host_port[hp_colon + 1 ..], 10) catch 5432;
            } else {
                host = host_port;
            }
        }
    }

    return PoolConfig{
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = database,
    };
}

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

    /// Get a reference to the underlying connection
    pub fn get(self: *PooledConnection) *Connection {
        return &self.conn.?;
    }

    /// Release the connection back to the pool
    pub fn release(self: *PooledConnection) void {
        if (self.conn) |conn| {
            self.pool.returnConnection(conn);
            self.conn = null;
        }
    }

    /// Close without returning to pool (for bad connections)
    pub fn discard(self: *PooledConnection) void {
        if (self.conn) |*conn| {
            conn.close();
            self.conn = null;
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
        defer self.mutex.unlock();

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
            return .{
                .conn = pooled.conn,
                .pool = self,
            };
        }

        // No idle connections - create new if under limit
        if (self.active_count < self.config.max_connections) {
            self.active_count += 1;
            self.mutex.unlock();
            const conn = try self.createConnection();
            self.mutex.lock();

            return .{
                .conn = conn,
                .pool = self,
            };
        }

        // Pool exhausted
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
};

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
