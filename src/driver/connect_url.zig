const std = @import("std");
const protocol = @import("../protocol/mod.zig");
const conn_mod = @import("connection.zig");
const auth_options_mod = @import("auth_options.zig");
const tls_driver_mod = @import("tls.zig");
const io_compat = @import("../runtime/io.zig");

const StartupParam = protocol.Encoder.StartupParam;
const AuthOptions = conn_mod.AuthOptions;
const TlsConfig = tls_driver_mod.TlsConfig;

/// TLS policy parsed from libpq-style URL options.
///
/// `verify_ca`/`verify_full` require explicit certificate verification config
/// (for example via `sslrootcert`) and fail closed otherwise.
pub const TlsMode = enum {
    disable,
    prefer,
    require,
    verify_ca,
    verify_full,

    pub fn parseSslMode(value: []const u8) ?TlsMode {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "disable")) return .disable;
        if (std.ascii.eqlIgnoreCase(trimmed, "allow") or std.ascii.eqlIgnoreCase(trimmed, "prefer")) return .prefer;
        if (std.ascii.eqlIgnoreCase(trimmed, "require")) return .require;
        if (std.ascii.eqlIgnoreCase(trimmed, "verify-ca")) return .verify_ca;
        if (std.ascii.eqlIgnoreCase(trimmed, "verify-full")) return .verify_full;
        return null;
    }
};

/// GSS session-encryption policy parsed from URL options.
///
/// `PgDriver` supports libpq-style negotiation semantics for `.prefer` and
/// `.require`:
/// - rejected/server-error prefaces can fall through on `.prefer`
/// - accepted prefaces proceed into the encrypted GSS transport on Linux and
///   fail closed on unsupported platforms
pub const GssEncMode = enum {
    disable,
    prefer,
    require,

    pub fn parse(value: []const u8) ?GssEncMode {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "disable")) return .disable;
        if (std.ascii.eqlIgnoreCase(trimmed, "prefer")) return .prefer;
        if (std.ascii.eqlIgnoreCase(trimmed, "require")) return .require;
        return null;
    }
};

/// Advanced connection options used by `connectWithOptions` and builder API.
pub const ConnectOptions = struct {
    /// Optional TCP connect timeout in milliseconds.
    timeout_ms: ?i32 = null,
    /// Password/SCRAM/GSS auth policy.
    auth_options: AuthOptions = .{},
    /// Additional startup parameters sent in StartupMessage.
    startup_params: []const StartupParam = &.{},
    /// Parsed libpq-style TLS mode.
    tls_mode: TlsMode = .disable,
    /// Optional TLS configuration used when `tls_mode` is not `.disable`.
    tls_config: ?TlsConfig = null,
    /// Parsed libpq-style GSS encryption mode.
    ///
    /// Negotiation preface support is implemented. Accepted GSSENC transport
    /// proceeds on Linux and fails closed on unsupported platforms.
    gss_enc_mode: GssEncMode = .disable,
};

/// Parsed PostgreSQL URL pieces used by `connectUrl`.
pub const ParsedConnectionUrl = struct {
    host: []u8,
    port: u16,
    user: []u8,
    database: []u8,
    password: ?[]u8,
    options: ConnectOptions,
    logical_replication: bool,
};

pub fn parseConnectionUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedConnectionUrl {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    var rest = trimmed;
    if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else {
        return error.InvalidDatabaseUrlScheme;
    }

    const query_index = std.mem.indexOfScalar(u8, rest, '?');
    const authority_and_path = if (query_index) |idx| rest[0..idx] else rest;
    const query = if (query_index) |idx| rest[idx + 1 ..] else "";

    const at_index = std.mem.lastIndexOfScalar(u8, authority_and_path, '@') orelse return error.InvalidDatabaseUrlMissingUser;
    const auth_part = authority_and_path[0..at_index];
    const host_db_part = authority_and_path[at_index + 1 ..];
    if (auth_part.len == 0) return error.InvalidDatabaseUrlMissingUser;

    const slash_index = std.mem.indexOfScalar(u8, host_db_part, '/') orelse return error.InvalidDatabaseUrlMissingDatabase;
    const host_port_part = host_db_part[0..slash_index];
    const database_enc = host_db_part[slash_index + 1 ..];
    if (database_enc.len == 0) return error.InvalidDatabaseUrlMissingDatabase;

    var user_enc = auth_part;
    var password_enc: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, auth_part, ':')) |colon_index| {
        user_enc = auth_part[0..colon_index];
        password_enc = auth_part[colon_index + 1 ..];
    }
    if (user_enc.len == 0) return error.InvalidDatabaseUrlMissingUser;

    var host_part = host_port_part;
    var port: u16 = 5432;
    if (std.mem.lastIndexOfScalar(u8, host_port_part, ':')) |colon_index| {
        host_part = host_port_part[0..colon_index];
        const port_text = host_port_part[colon_index + 1 ..];
        if (port_text.len == 0) return error.InvalidDatabaseUrlPort;
        port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidDatabaseUrlPort;
    }
    if (host_part.len == 0) return error.InvalidDatabaseUrlHost;

    var parsed = ParsedConnectionUrl{
        .host = try allocator.dupe(u8, host_part),
        .port = port,
        .user = try percentDecodeAlloc(allocator, user_enc),
        .database = try percentDecodeAlloc(allocator, database_enc),
        .password = if (password_enc) |pw| try percentDecodeAlloc(allocator, pw) else null,
        .options = .{},
        .logical_replication = false,
    };

    if (query.len != 0) {
        try applyUrlQueryOptions(allocator, &parsed, query);
    }

    return parsed;
}

pub fn hasLogicalReplicationStartupMode(startup_params: []const StartupParam) bool {
    for (startup_params) |param| {
        if (std.ascii.eqlIgnoreCase(param.name, "replication")) {
            return isReplicationDatabaseValue(param.value);
        }
    }
    return false;
}

fn applyUrlQueryOptions(
    allocator: std.mem.Allocator,
    parsed: *ParsedConnectionUrl,
    query: []const u8,
) !void {
    var query_iter = std.mem.splitScalar(u8, query, '&');
    while (query_iter.next()) |pair| {
        if (pair.len == 0) continue;

        var key_value = std.mem.splitScalar(u8, pair, '=');
        const key = std.mem.trim(u8, key_value.next() orelse "", " \t\r\n");
        const value = std.mem.trim(u8, key_value.next() orelse "", " \t\r\n");
        if (key.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(key, "replication")) {
            if (!isReplicationDatabaseValue(value)) return error.InvalidReplicationStartupMode;
            parsed.logical_replication = true;
            continue;
        }

        if (try applyTlsQueryOption(allocator, parsed, key, value)) |handled| {
            if (handled) continue;
        }

        if (try applyAuthBoolQueryOption(parsed, key, value)) |handled| {
            if (handled) continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_mode")) {
            parsed.options.auth_options = try parseAuthMode(value);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "connect_timeout")) {
            parsed.options.timeout_ms = try parseConnectTimeoutMs(value);
            continue;
        }
    }
}

fn applyTlsQueryOption(
    allocator: std.mem.Allocator,
    parsed: *ParsedConnectionUrl,
    key: []const u8,
    value: []const u8,
) !?bool {
    if (std.ascii.eqlIgnoreCase(key, "sslmode")) {
        parsed.options.tls_mode = TlsMode.parseSslMode(value) orelse return error.InvalidTlsMode;
        return true;
    }

    if (std.ascii.eqlIgnoreCase(key, "sslrootcert")) {
        var tls_config = ensureTlsConfig(parsed);
        tls_config.verify = .{
            .bundle = try loadCaBundleFromPath(allocator, value),
        };
        if (parsed.options.tls_mode == .disable) parsed.options.tls_mode = .require;
        return true;
    }

    if (std.ascii.eqlIgnoreCase(key, "gssencmode")) {
        parsed.options.gss_enc_mode = GssEncMode.parse(value) orelse return error.InvalidGssEncMode;
        return true;
    }

    if (std.ascii.eqlIgnoreCase(key, "tls_server_end_point_cert_der")) {
        var tls_config = ensureTlsConfig(parsed);
        tls_config.tls_server_end_point_cert_der = try readFileAllocAnyPath(
            allocator,
            value,
            8 * 1024 * 1024,
        );
        if (parsed.options.tls_mode == .disable) parsed.options.tls_mode = .require;
        return true;
    }

    return null;
}

fn applyAuthBoolQueryOption(
    parsed: *ParsedConnectionUrl,
    key: []const u8,
    value: []const u8,
) !?bool {
    if (std.ascii.eqlIgnoreCase(key, "channel_binding")) {
        parsed.options.auth_options.scram_channel_binding = auth_options_mod.ScramChannelBindingMode.parse(value) orelse return error.InvalidChannelBindingMode;
        return true;
    }

    if (std.ascii.eqlIgnoreCase(key, "auth_scram")) {
        parsed.options.auth_options.allow_scram_sha_256 = parseBoolParam(value) orelse return error.InvalidAuthOption;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(key, "auth_md5")) {
        parsed.options.auth_options.allow_md5_password = parseBoolParam(value) orelse return error.InvalidAuthOption;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(key, "auth_cleartext")) {
        parsed.options.auth_options.allow_cleartext_password = parseBoolParam(value) orelse return error.InvalidAuthOption;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(key, "auth_kerberos")) {
        parsed.options.auth_options.allow_kerberos_v5 = parseBoolParam(value) orelse return error.InvalidAuthOption;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(key, "auth_gssapi")) {
        parsed.options.auth_options.allow_gssapi = parseBoolParam(value) orelse return error.InvalidAuthOption;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(key, "auth_sspi")) {
        parsed.options.auth_options.allow_sspi = parseBoolParam(value) orelse return error.InvalidAuthOption;
        return true;
    }

    return null;
}

fn parseAuthMode(value: []const u8) !AuthOptions {
    if (std.ascii.eqlIgnoreCase(value, "scram_only")) {
        return .{
            .allow_cleartext_password = false,
            .allow_md5_password = false,
            .allow_scram_sha_256 = true,
            .allow_kerberos_v5 = false,
            .allow_gssapi = false,
            .allow_sspi = false,
            .scram_channel_binding = .prefer,
        };
    }

    if (std.ascii.eqlIgnoreCase(value, "gssapi_only")) {
        return .{
            .allow_cleartext_password = false,
            .allow_md5_password = false,
            .allow_scram_sha_256 = false,
            .allow_kerberos_v5 = true,
            .allow_gssapi = true,
            .allow_sspi = true,
            .scram_channel_binding = .prefer,
        };
    }

    return error.InvalidAuthMode;
}

fn parseConnectTimeoutMs(value: []const u8) !?i32 {
    const seconds = std.fmt.parseInt(i32, value, 10) catch return error.InvalidConnectTimeout;
    if (seconds < 0) return error.InvalidConnectTimeout;
    if (seconds == 0) return null;
    return std.math.mul(i32, seconds, 1000) catch return error.InvalidConnectTimeout;
}

fn ensureTlsConfig(parsed: *ParsedConnectionUrl) *TlsConfig {
    if (parsed.options.tls_config == null) {
        parsed.options.tls_config = TlsConfig{};
    }
    return &parsed.options.tls_config.?;
}

fn loadCaBundleFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.crypto.Certificate.Bundle {
    const io_iface = io_compat.runtimeIo();
    const now = std.Io.Clock.real.now(io_iface);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    if (std.fs.path.isAbsolute(path)) {
        try bundle.addCertsFromFilePathAbsolute(allocator, io_iface, now, path);
    } else {
        try bundle.addCertsFromFilePath(allocator, io_iface, now, std.Io.Dir.cwd(), path);
    }
    return bundle;
}

fn readFileAllocAnyPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io_compat.runtimeIo(),
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn parseBoolParam(value: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "on") or std.ascii.eqlIgnoreCase(trimmed, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "false") or std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    return null;
}

fn isReplicationDatabaseValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "database") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "on") or
        std.mem.eql(u8, trimmed, "1");
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) {
        return allocator.dupe(u8, text);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const hex = text[i + 1 .. i + 3];
            const decoded = std.fmt.parseInt(u8, hex, 16) catch {
                try out.append(allocator, text[i]);
                continue;
            };
            try out.append(allocator, decoded);
            i += 2;
            continue;
        }
        try out.append(allocator, text[i]);
    }

    return try out.toOwnedSlice(allocator);
}

test "parse sslmode aliases" {
    try std.testing.expectEqual(TlsMode.disable, TlsMode.parseSslMode(" disable "));
    try std.testing.expectEqual(TlsMode.prefer, TlsMode.parseSslMode("allow"));
    try std.testing.expectEqual(TlsMode.require, TlsMode.parseSslMode("require"));
    try std.testing.expectEqual(TlsMode.verify_ca, TlsMode.parseSslMode("verify-ca"));
    try std.testing.expectEqual(TlsMode.verify_full, TlsMode.parseSslMode("verify-full"));
    try std.testing.expect(TlsMode.parseSslMode("bogus") == null);
}

test "parse gssencmode values" {
    try std.testing.expectEqual(GssEncMode.disable, GssEncMode.parse("disable"));
    try std.testing.expectEqual(GssEncMode.prefer, GssEncMode.parse("prefer"));
    try std.testing.expectEqual(GssEncMode.require, GssEncMode.parse("require"));
    try std.testing.expect(GssEncMode.parse("bogus") == null);
}

test "parse logical replication startup mode" {
    const startup_params = [_]StartupParam{
        .{ .name = "application_name", .value = "qail" },
        .{ .name = "replication", .value = "database" },
    };

    try std.testing.expect(hasLogicalReplicationStartupMode(&startup_params));
    try std.testing.expect(!hasLogicalReplicationStartupMode(&[_]StartupParam{.{ .name = "replication", .value = "false" }}));
}

test "parse connect timeout milliseconds" {
    try std.testing.expectEqual(@as(?i32, null), try parseConnectTimeoutMs("0"));
    try std.testing.expectEqual(@as(?i32, 5000), try parseConnectTimeoutMs("5"));
    try std.testing.expectError(error.InvalidConnectTimeout, parseConnectTimeoutMs("-1"));
}
