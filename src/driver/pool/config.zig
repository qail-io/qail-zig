const std = @import("std");

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
    max_lifetime_ms: ?i64 = null, // no lifetime limit by default
    acquire_timeout_ms: i32 = 30_000, // 30 seconds
    test_on_acquire: bool = false, // disabled by default for performance
    connect_timeout_ms: i32 = 10_000, // 10 seconds
    reconnect_interval_ms: u64 = 5_000, // 5 seconds
};

/// Parse PostgreSQL connection URI
/// Format: postgresql://user:password@host:port/database
pub fn parseUri(uri: []const u8) !PoolConfig {
    const body_with_query = blk: {
        if (std.mem.startsWith(u8, uri, "postgresql://")) break :blk uri["postgresql://".len..];
        if (std.mem.startsWith(u8, uri, "postgres://")) break :blk uri["postgres://".len..];
        return error.InvalidUri;
    };
    const query_pos = std.mem.indexOfScalar(u8, body_with_query, '?');
    const body = if (query_pos) |idx| body_with_query[0..idx] else body_with_query;
    const query = if (query_pos) |idx| body_with_query[idx + 1 ..] else "";

    var user: []const u8 = "postgres";
    var password: ?[]const u8 = null;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 5432;
    var database: []const u8 = "postgres";

    var authority = body;
    if (std.mem.indexOfScalar(u8, body, '/')) |slash_pos| {
        authority = body[0..slash_pos];
        const db_part = body[slash_pos + 1 ..];
        if (db_part.len != 0) database = db_part;
    }

    var host_port = authority;
    if (std.mem.indexOfScalar(u8, authority, '@')) |at_pos| {
        const auth = authority[0..at_pos];
        host_port = authority[at_pos + 1 ..];
        if (auth.len != 0) {
            if (std.mem.indexOfScalar(u8, auth, ':')) |colon_pos| {
                user = auth[0..colon_pos];
                password = auth[colon_pos + 1 ..];
            } else {
                user = auth;
            }
        }
    }

    if (host_port.len != 0) {
        if (host_port[0] == '[') {
            const close_pos = std.mem.indexOfScalarPos(u8, host_port, 1, ']') orelse return error.InvalidUri;
            host = host_port[1..close_pos];
            const remainder = host_port[close_pos + 1 ..];
            if (remainder.len != 0) {
                if (remainder[0] != ':' or remainder.len <= 1) return error.InvalidUri;
                port = std.fmt.parseInt(u16, remainder[1..], 10) catch return error.InvalidUri;
            }
        } else {
            const colon_count = std.mem.count(u8, host_port, ":");
            if (colon_count <= 1) {
                if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_pos| {
                    const host_part = host_port[0..colon_pos];
                    const port_part = host_port[colon_pos + 1 ..];
                    if (host_part.len != 0 and isDecimal(port_part)) {
                        host = host_part;
                        port = std.fmt.parseInt(u16, port_part, 10) catch return error.InvalidUri;
                    } else if (host_port.len != 0) {
                        host = host_port;
                    }
                } else {
                    host = host_port;
                }
            } else {
                // Unbracketed IPv6 literal without explicit port.
                host = host_port;
            }
        }
    }

    var config = PoolConfig{
        .host = host,
        .port = port,
        .user = user,
        .password = password,
        .database = database,
    };
    try applyUriQueryParams(&config, query);
    try validateParsedConfig(&config);
    return config;
}

fn isDecimal(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn applyUriQueryParams(config: *PoolConfig, query: []const u8) !void {
    if (query.len == 0) return;

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;

        var kv = std.mem.splitScalar(u8, pair, '=');
        const key = std.mem.trim(u8, kv.next() orelse "", " \t\r\n");
        const value = std.mem.trim(u8, kv.next() orelse "", " \t\r\n");
        if (key.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(key, "connect_timeout")) {
            const secs = parseNonNegativeI64(value) catch return error.InvalidUriOption;
            if (secs == 0) continue;
            const ms = std.math.mul(i64, secs, 1000) catch return error.InvalidUriOption;
            if (ms > std.math.maxInt(i32)) return error.InvalidUriOption;
            config.connect_timeout_ms = @intCast(ms);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "connect_timeout_ms")) {
            const ms = parsePositiveI32(value) catch return error.InvalidUriOption;
            config.connect_timeout_ms = ms;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "acquire_timeout")) {
            const secs = parsePositiveI64(value) catch return error.InvalidUriOption;
            const ms = std.math.mul(i64, secs, 1000) catch return error.InvalidUriOption;
            if (ms > std.math.maxInt(i32)) return error.InvalidUriOption;
            config.acquire_timeout_ms = @intCast(ms);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "acquire_timeout_ms")) {
            config.acquire_timeout_ms = parsePositiveI32(value) catch return error.InvalidUriOption;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "idle_timeout")) {
            const secs = parseNonNegativeI64(value) catch return error.InvalidUriOption;
            config.idle_timeout_ms = std.math.mul(i64, secs, 1000) catch return error.InvalidUriOption;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "idle_timeout_ms")) {
            config.idle_timeout_ms = parseNonNegativeI64(value) catch return error.InvalidUriOption;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "max_lifetime")) {
            const secs = parseNonNegativeI64(value) catch return error.InvalidUriOption;
            if (secs == 0) {
                config.max_lifetime_ms = null;
            } else {
                config.max_lifetime_ms = std.math.mul(i64, secs, 1000) catch return error.InvalidUriOption;
            }
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "max_lifetime_ms")) {
            const ms = parseNonNegativeI64(value) catch return error.InvalidUriOption;
            config.max_lifetime_ms = if (ms == 0) null else ms;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "reconnect_interval")) {
            const secs = parsePositiveI64(value) catch return error.InvalidUriOption;
            const ms = std.math.mul(i64, secs, 1000) catch return error.InvalidUriOption;
            if (ms > std.math.maxInt(u64)) return error.InvalidUriOption;
            config.reconnect_interval_ms = @intCast(ms);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "reconnect_interval_ms") or std.ascii.eqlIgnoreCase(key, "pool_reconnect_interval_ms")) {
            const ms = parsePositiveI64(value) catch return error.InvalidUriOption;
            if (ms > std.math.maxInt(u64)) return error.InvalidUriOption;
            config.reconnect_interval_ms = @intCast(ms);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "max_connections") or std.ascii.eqlIgnoreCase(key, "pool_max_connections")) {
            const parsed = parsePositiveUsize(value) catch return error.InvalidUriOption;
            config.max_connections = parsed;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "min_connections") or std.ascii.eqlIgnoreCase(key, "pool_min_connections")) {
            config.min_connections = parseUsize(value) catch return error.InvalidUriOption;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "test_on_acquire") or std.ascii.eqlIgnoreCase(key, "pool_test_on_acquire")) {
            config.test_on_acquire = parseBool(value) orelse return error.InvalidUriOption;
            continue;
        }
    }
}

fn parseUsize(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidUriOption;
    return std.fmt.parseInt(usize, value, 10) catch error.InvalidUriOption;
}

fn parsePositiveUsize(value: []const u8) !usize {
    const parsed = try parseUsize(value);
    if (parsed == 0) return error.InvalidUriOption;
    return parsed;
}

fn parseNonNegativeI64(value: []const u8) !i64 {
    if (value.len == 0) return error.InvalidUriOption;
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidUriOption;
    if (parsed < 0) return error.InvalidUriOption;
    return parsed;
}

fn parsePositiveI64(value: []const u8) !i64 {
    const parsed = try parseNonNegativeI64(value);
    if (parsed == 0) return error.InvalidUriOption;
    return parsed;
}

fn parsePositiveI32(value: []const u8) !i32 {
    const parsed = std.fmt.parseInt(i32, value, 10) catch return error.InvalidUriOption;
    if (parsed <= 0) return error.InvalidUriOption;
    return parsed;
}

fn parseBool(value: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "no") or
        std.ascii.eqlIgnoreCase(trimmed, "off"))
    {
        return false;
    }
    return null;
}

fn validateParsedConfig(config: *const PoolConfig) !void {
    if (config.host.len == 0) return error.InvalidUriOption;
    if (config.user.len == 0) return error.InvalidUriOption;
    if (config.database.len == 0) return error.InvalidUriOption;
    if (config.max_connections == 0) return error.InvalidUriOption;
    if (config.min_connections > config.max_connections) return error.InvalidUriOption;
    if (config.idle_timeout_ms < 0) return error.InvalidUriOption;
    if (config.max_lifetime_ms) |max_lifetime_ms| {
        if (max_lifetime_ms <= 0) return error.InvalidUriOption;
    }
    if (config.acquire_timeout_ms <= 0) return error.InvalidUriOption;
    if (config.connect_timeout_ms <= 0) return error.InvalidUriOption;
    if (config.reconnect_interval_ms == 0) return error.InvalidUriOption;
}

test "parseUri uses defaults when authority missing" {
    const config = try parseUri("postgresql://");
    try std.testing.expectEqualStrings("postgres", config.user);
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqualStrings("postgres", config.database);
    try std.testing.expectEqual(@as(u16, 5432), config.port);
}

test "parseUri parses user host port database" {
    const config = try parseUri("postgresql://alice:secret@db.example:6543/app");
    try std.testing.expectEqualStrings("alice", config.user);
    try std.testing.expectEqualStrings("secret", config.password.?);
    try std.testing.expectEqualStrings("db.example", config.host);
    try std.testing.expectEqual(@as(u16, 6543), config.port);
    try std.testing.expectEqualStrings("app", config.database);
}

test "parseUri parses host port database without auth section" {
    const config = try parseUri("postgresql://db.example:6543/app");
    try std.testing.expectEqualStrings("postgres", config.user);
    try std.testing.expect(config.password == null);
    try std.testing.expectEqualStrings("db.example", config.host);
    try std.testing.expectEqual(@as(u16, 6543), config.port);
    try std.testing.expectEqualStrings("app", config.database);
}

test "parseUri parses host and database without explicit port" {
    const config = try parseUri("postgresql://db.example/app");
    try std.testing.expectEqualStrings("db.example", config.host);
    try std.testing.expectEqual(@as(u16, 5432), config.port);
    try std.testing.expectEqualStrings("app", config.database);
}

test "parseUri parses ipv6 host and port" {
    const config = try parseUri("postgresql://alice@[2001:db8::1]:7777/app");
    try std.testing.expectEqualStrings("alice", config.user);
    try std.testing.expectEqualStrings("2001:db8::1", config.host);
    try std.testing.expectEqual(@as(u16, 7777), config.port);
    try std.testing.expectEqualStrings("app", config.database);
}

test "parseUri strips query suffix from database" {
    const config = try parseUri("postgresql://alice:secret@db.example:6543/app?sslmode=require");
    try std.testing.expectEqualStrings("app", config.database);
}

test "parseUri accepts postgres scheme alias" {
    const config = try parseUri("postgres://alice:secret@db.example:6543/app");
    try std.testing.expectEqualStrings("alice", config.user);
    try std.testing.expectEqualStrings("db.example", config.host);
    try std.testing.expectEqual(@as(u16, 6543), config.port);
    try std.testing.expectEqualStrings("app", config.database);
}

test "parseUri applies pool query params" {
    const config = try parseUri(
        "postgresql://alice:secret@db.example:6543/app?connect_timeout=3&acquire_timeout_ms=2500&idle_timeout=120&max_lifetime_ms=7000&max_connections=24&min_connections=4&test_on_acquire=on",
    );
    try std.testing.expectEqualStrings("alice", config.user);
    try std.testing.expectEqualStrings("db.example", config.host);
    try std.testing.expectEqual(@as(i32, 3000), config.connect_timeout_ms);
    try std.testing.expectEqual(@as(i32, 2500), config.acquire_timeout_ms);
    try std.testing.expectEqual(@as(i64, 120_000), config.idle_timeout_ms);
    try std.testing.expectEqual(@as(?i64, 7000), config.max_lifetime_ms);
    try std.testing.expectEqual(@as(u64, 5000), config.reconnect_interval_ms);
    try std.testing.expectEqual(@as(usize, 24), config.max_connections);
    try std.testing.expectEqual(@as(usize, 4), config.min_connections);
    try std.testing.expect(config.test_on_acquire);
}

test "parseUri accepts pool aliases and zero max_lifetime disables cap" {
    const config = try parseUri(
        "postgresql://db.example/app?pool_max_connections=12&pool_min_connections=2&pool_test_on_acquire=false&max_lifetime=0&pool_reconnect_interval_ms=2500",
    );
    try std.testing.expectEqual(@as(usize, 12), config.max_connections);
    try std.testing.expectEqual(@as(usize, 2), config.min_connections);
    try std.testing.expect(!config.test_on_acquire);
    try std.testing.expectEqual(@as(?i64, null), config.max_lifetime_ms);
    try std.testing.expectEqual(@as(u64, 2500), config.reconnect_interval_ms);
}

test "parseUri rejects invalid pool query params" {
    try std.testing.expectError(
        error.InvalidUriOption,
        parseUri("postgresql://db.example/app?max_connections=0"),
    );
    try std.testing.expectError(
        error.InvalidUriOption,
        parseUri("postgresql://db.example/app?test_on_acquire=maybe"),
    );
    try std.testing.expectError(
        error.InvalidUriOption,
        parseUri("postgresql://db.example/app?connect_timeout_ms=-1"),
    );
    try std.testing.expectError(
        error.InvalidUriOption,
        parseUri("postgresql://db.example/app?reconnect_interval_ms=0"),
    );
    try std.testing.expectError(
        error.InvalidUriOption,
        parseUri("postgresql://db.example/app?min_connections=5&max_connections=2"),
    );
}
