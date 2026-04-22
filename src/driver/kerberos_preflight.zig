const std = @import("std");
const process_compat = @import("../runtime/process.zig");
const io_compat = @import("../runtime/io.zig");

pub const LinuxKrb5ProviderConfig = struct {
    /// PostgreSQL service name (typically `postgres`).
    service: []const u8 = "postgres",
    /// PostgreSQL host used for host-based target naming.
    host: []const u8,
    /// Optional full GSS target override (for example `postgres@db.internal`).
    target_name: ?[]const u8 = null,

    pub fn resolveTargetName(self: LinuxKrb5ProviderConfig, allocator: std.mem.Allocator) ![]u8 {
        if (self.target_name) |target| {
            const trimmed = std.mem.trim(u8, target, " \t\r\n");
            if (trimmed.len == 0) return error.InvalidKerberosTargetName;
            return allocator.dupe(u8, trimmed);
        }

        const service = std.mem.trim(u8, self.service, " \t\r\n");
        if (service.len == 0) return error.InvalidKerberosServiceName;

        const host = std.mem.trim(u8, self.host, " \t\r\n");
        if (host.len == 0) return error.InvalidKerberosHostName;

        return std.fmt.allocPrint(allocator, "{s}@{s}", .{ service, host });
    }
};

pub const LinuxKrb5PreflightReport = struct {
    allocator: std.mem.Allocator,
    target_name: []u8,
    warnings: [][]u8,

    pub fn deinit(self: *LinuxKrb5PreflightReport) void {
        self.allocator.free(self.target_name);
        for (self.warnings) |warning| self.allocator.free(warning);
        self.allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub fn linuxKrb5Preflight(
    allocator: std.mem.Allocator,
    config: LinuxKrb5ProviderConfig,
) !LinuxKrb5PreflightReport {
    var env_map = try process_compat.getEnvMap(allocator);
    defer env_map.deinit();

    return linuxKrb5PreflightWithEnvMap(allocator, config, &env_map);
}

pub fn linuxKrb5PreflightWithEnvMap(
    allocator: std.mem.Allocator,
    config: LinuxKrb5ProviderConfig,
    env_map: *const process_compat.EnvMap,
) !LinuxKrb5PreflightReport {
    var warnings = std.ArrayList([]u8).empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    const target_name = try config.resolveTargetName(allocator);
    errdefer allocator.free(target_name);

    if (env_map.get("KRB5_CONFIG")) |raw_cfg| {
        var found = false;
        var it = std.mem.splitScalar(u8, raw_cfg, ':');
        while (it.next()) |candidate| {
            const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (pathExists(trimmed)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return error.KerberosConfigNotFound;
        }
    } else if (!pathExists("/etc/krb5.conf")) {
        try warnings.append(allocator, try std.fmt.allocPrint(
            allocator,
            "Kerberos preflight: /etc/krb5.conf not found and KRB5_CONFIG is unset; relying on system defaults",
            .{},
        ));
    }

    var explicit_cred_source = false;

    if (env_map.get("KRB5CCNAME")) |ccache| {
        explicit_cred_source = true;
        try validateCacheEnv(allocator, "KRB5CCNAME", ccache, &warnings);
    }

    inline for ([_][]const u8{ "KRB5_CLIENT_KTNAME", "KRB5_KTNAME" }) |env_name| {
        if (env_map.get(env_name)) |keytab| {
            explicit_cred_source = true;
            try validateKeytabEnv(env_name, keytab);
        }
    }

    if (!explicit_cred_source) {
        try warnings.append(allocator, try std.fmt.allocPrint(
            allocator,
            "Kerberos preflight: no explicit credential source set (KRB5CCNAME/KRB5_CLIENT_KTNAME/KRB5_KTNAME); relying on default cache discovery",
            .{},
        ));
    }

    return .{
        .allocator = allocator,
        .target_name = target_name,
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

fn validateCacheEnv(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    raw: []const u8,
    warnings: *std.ArrayList([]u8),
) !void {
    if (std.mem.startsWith(u8, raw, "FILE:")) {
        const path = raw["FILE:".len..];
        if (path.len == 0) return error.EmptyKerberosCachePath;
        if (!pathExists(path)) return error.KerberosCredentialCacheNotFound;
        return;
    }

    if (std.mem.startsWith(u8, raw, "DIR:")) {
        const path = raw["DIR:".len..];
        if (path.len == 0) return error.EmptyKerberosCachePath;
        if (!pathIsDir(path)) return error.KerberosCredentialCacheDirNotFound;
        return;
    }

    inline for ([_][]const u8{ "KEYRING:", "KCM:", "MEMORY:", "API:" }) |scheme| {
        if (std.mem.startsWith(u8, raw, scheme)) {
            try warnings.append(allocator, try std.fmt.allocPrint(
                allocator,
                "Kerberos preflight: {s} uses {s} cache; path validation skipped",
                .{ env_name, scheme[0 .. scheme.len - 1] },
            ));
            return;
        }
    }

    if (std.mem.indexOfScalar(u8, raw, ':') != null) {
        try warnings.append(allocator, try std.fmt.allocPrint(
            allocator,
            "Kerberos preflight: {s} uses unsupported cache spec '{s}'; validation skipped",
            .{ env_name, raw },
        ));
        return;
    }

    if (!pathExists(raw)) return error.KerberosCredentialCacheNotFound;
}

fn validateKeytabEnv(env_name: []const u8, raw: []const u8) !void {
    if (std.mem.startsWith(u8, raw, "FILE:")) {
        const path = raw["FILE:".len..];
        if (path.len == 0) return error.EmptyKerberosKeytabPath;
        if (!pathExists(path)) return error.KerberosKeytabNotFound;
        return;
    }

    if (std.mem.indexOfScalar(u8, raw, ':') != null) {
        _ = env_name;
        return error.UnsupportedKerberosKeytabSpec;
    }

    if (!pathExists(raw)) return error.KerberosKeytabNotFound;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io_compat.runtimeIo(), path, .{}) catch return false;
    return true;
}

fn pathIsDir(path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io_compat.runtimeIo(), path, .{}) catch return false;
    dir.close(io_compat.runtimeIo());
    return true;
}

fn tmpFilePathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try dir.realPath(std.testing.io, &base_buf);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_buf[0..base_len], name });
}

fn hasWarning(report: LinuxKrb5PreflightReport, needle: []const u8) bool {
    for (report.warnings) |warning| {
        if (std.mem.indexOf(u8, warning, needle) != null) return true;
    }
    return false;
}

test "linux krb5 target name resolves default service and host" {
    const config = LinuxKrb5ProviderConfig{ .host = "db.internal" };
    const target = try config.resolveTargetName(std.testing.allocator);
    defer std.testing.allocator.free(target);

    try std.testing.expectEqualStrings("postgres@db.internal", target);
}

test "linux krb5 target name uses explicit override" {
    const config = LinuxKrb5ProviderConfig{
        .host = "ignored",
        .target_name = "  postgres@kerberos.internal  ",
    };
    const target = try config.resolveTargetName(std.testing.allocator);
    defer std.testing.allocator.free(target);

    try std.testing.expectEqualStrings("postgres@kerberos.internal", target);
}

test "linux krb5 preflight warns when no explicit credential source is set" {
    var env_map = process_compat.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "krb5.conf", .data = "[libdefaults]\n" });
    const cfg_path = try tmpFilePathAlloc(std.testing.allocator, tmp.dir, "krb5.conf");
    defer std.testing.allocator.free(cfg_path);
    try env_map.put("KRB5_CONFIG", cfg_path);

    var report = try linuxKrb5PreflightWithEnvMap(
        std.testing.allocator,
        .{ .host = "db.internal" },
        &env_map,
    );
    defer report.deinit();

    try std.testing.expect(hasWarning(report, "no explicit credential source set"));
}

test "linux krb5 preflight validates FILE cache path" {
    var env_map = process_compat.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "krb5.conf", .data = "[libdefaults]\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cache", .data = "ticket" });

    const cfg_path = try tmpFilePathAlloc(std.testing.allocator, tmp.dir, "krb5.conf");
    defer std.testing.allocator.free(cfg_path);
    const cache_path = try tmpFilePathAlloc(std.testing.allocator, tmp.dir, "cache");
    defer std.testing.allocator.free(cache_path);

    const ccache = try std.fmt.allocPrint(std.testing.allocator, "FILE:{s}", .{cache_path});
    defer std.testing.allocator.free(ccache);

    try env_map.put("KRB5_CONFIG", cfg_path);
    try env_map.put("KRB5CCNAME", ccache);

    var report = try linuxKrb5PreflightWithEnvMap(
        std.testing.allocator,
        .{ .host = "db.internal" },
        &env_map,
    );
    defer report.deinit();

    try std.testing.expectEqualStrings("postgres@db.internal", report.target_name);
}

test "linux krb5 preflight warns for memory cache specs" {
    var env_map = process_compat.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "krb5.conf", .data = "[libdefaults]\n" });
    const cfg_path = try tmpFilePathAlloc(std.testing.allocator, tmp.dir, "krb5.conf");
    defer std.testing.allocator.free(cfg_path);

    try env_map.put("KRB5_CONFIG", cfg_path);
    try env_map.put("KRB5CCNAME", "MEMORY:test-cache");

    var report = try linuxKrb5PreflightWithEnvMap(
        std.testing.allocator,
        .{ .host = "db.internal" },
        &env_map,
    );
    defer report.deinit();

    try std.testing.expect(hasWarning(report, "uses MEMORY cache"));
}

test "linux krb5 preflight rejects missing keytab" {
    var env_map = process_compat.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "krb5.conf", .data = "[libdefaults]\n" });
    const cfg_path = try tmpFilePathAlloc(std.testing.allocator, tmp.dir, "krb5.conf");
    defer std.testing.allocator.free(cfg_path);

    try env_map.put("KRB5_CONFIG", cfg_path);
    try env_map.put("KRB5_CLIENT_KTNAME", "FILE:/definitely/missing/keytab");

    try std.testing.expectError(
        error.KerberosKeytabNotFound,
        linuxKrb5PreflightWithEnvMap(
            std.testing.allocator,
            .{ .host = "db.internal" },
            &env_map,
        ),
    );
}
