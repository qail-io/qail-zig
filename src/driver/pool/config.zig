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
    acquire_timeout_ms: i32 = 30_000, // 30 seconds
    reconnect_interval_ms: u64 = 5_000, // 5 seconds
};

/// Parse PostgreSQL connection URI
/// Format: postgresql://user:password@host:port/database
pub fn parseUri(uri: []const u8) !PoolConfig {
    const prefix = "postgresql://";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return error.InvalidUri;
    }

    const body = uri[prefix.len..];

    var user: []const u8 = "postgres";
    var password: ?[]const u8 = null;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 5432;
    var database: []const u8 = "postgres";

    if (std.mem.indexOf(u8, body, "@")) |at_pos| {
        const auth = body[0..at_pos];
        const rest = body[at_pos + 1 ..];

        if (std.mem.indexOf(u8, auth, ":")) |colon_pos| {
            user = auth[0..colon_pos];
            password = auth[colon_pos + 1 ..];
        } else {
            user = auth;
        }

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
