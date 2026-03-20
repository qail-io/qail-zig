const std = @import("std");
const wire = @import("../protocol/wire.zig");

pub const SCRAM_SHA_256 = "SCRAM-SHA-256";
pub const SCRAM_SHA_256_PLUS = "SCRAM-SHA-256-PLUS";

pub const GssMechanism = enum {
    kerberos_v5,
    gss,
    sspi,
};

pub const ScramChannelBindingMode = enum {
    /// Do not use SCRAM-SHA-256-PLUS even when available.
    disable,
    /// Prefer SCRAM-SHA-256-PLUS, fallback to SCRAM-SHA-256.
    prefer,
    /// Require SCRAM-SHA-256-PLUS and fail otherwise.
    require,

    pub fn parse(value: []const u8) ?ScramChannelBindingMode {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "disable") or std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "false") or std.ascii.eqlIgnoreCase(trimmed, "no")) return .disable;
        if (std.ascii.eqlIgnoreCase(trimmed, "prefer") or std.ascii.eqlIgnoreCase(trimmed, "on") or std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "yes")) return .prefer;
        if (std.ascii.eqlIgnoreCase(trimmed, "require") or std.ascii.eqlIgnoreCase(trimmed, "required")) return .require;
        return null;
    }
};

/// Callback that returns a GSS token to send to PostgreSQL.
///
/// Contract:
/// - Returned bytes are used immediately and not retained by the driver.
/// - The driver does not free returned memory.
pub const GssTokenProvider = *const fn (
    ctx: ?*anyopaque,
    mechanism: GssMechanism,
    server_token: ?[]const u8,
    allocator: std.mem.Allocator,
) anyerror![]const u8;

pub const AuthOptions = struct {
    // Password/SASL policy
    allow_cleartext_password: bool = true,
    allow_md5_password: bool = true,
    allow_scram_sha_256: bool = true,

    // Enterprise auth policy
    allow_kerberos_v5: bool = false,
    allow_gssapi: bool = false,
    allow_sspi: bool = false,

    // SCRAM channel-binding policy
    scram_channel_binding: ScramChannelBindingMode = .prefer,
    /// Optional `tls-server-end-point` bytes used when selecting SCRAM-SHA-256-PLUS.
    /// For TLS connections this can also be auto-derived from
    /// `TlsConfig.tls_server_end_point_cert_der`.
    scram_tls_server_end_point_binding: ?[]const u8 = null,

    // GSS token exchange
    gss_token_provider: ?GssTokenProvider = null,
    gss_context: ?*anyopaque = null,
    max_gss_roundtrips: u32 = 32,
};

pub fn mechanismFromAuthType(auth_type: wire.AuthType) ?GssMechanism {
    return switch (auth_type) {
        .kerberos_v5 => .kerberos_v5,
        .gss => .gss,
        .sspi => .sspi,
        else => null,
    };
}

pub fn requestGssToken(
    options: AuthOptions,
    mechanism: GssMechanism,
    server_token: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const provider = options.gss_token_provider orelse return error.GssTokenProviderRequired;
    return provider(options.gss_context, mechanism, server_token, allocator);
}

pub fn authTypeAllowed(options: AuthOptions, auth_type: wire.AuthType) bool {
    return switch (auth_type) {
        .cleartext_password => options.allow_cleartext_password,
        .md5_password => options.allow_md5_password,
        .sasl => options.allow_scram_sha_256,
        .kerberos_v5 => options.allow_kerberos_v5,
        .gss => options.allow_gssapi,
        .sspi => options.allow_sspi,
        else => true,
    };
}

pub const ScramSelection = struct {
    mechanism: []const u8,
    channel_binding_data: ?[]const u8,
};

pub fn selectScramMechanism(
    mechanisms: []const []const u8,
    tls_server_end_point_binding: ?[]const u8,
    mode: ScramChannelBindingMode,
) !ScramSelection {
    const has_scram = hasMechanism(mechanisms, SCRAM_SHA_256);
    const has_scram_plus = hasMechanism(mechanisms, SCRAM_SHA_256_PLUS);

    return switch (mode) {
        .disable => if (has_scram)
            .{ .mechanism = SCRAM_SHA_256, .channel_binding_data = null }
        else
            error.ScramMechanismUnavailable,
        .prefer => blk: {
            if (has_scram_plus) {
                if (tls_server_end_point_binding) |binding| {
                    break :blk .{ .mechanism = SCRAM_SHA_256_PLUS, .channel_binding_data = binding };
                }
                if (has_scram) {
                    break :blk .{ .mechanism = SCRAM_SHA_256, .channel_binding_data = null };
                }
                break :blk error.ChannelBindingUnavailable;
            }
            if (has_scram) {
                break :blk .{ .mechanism = SCRAM_SHA_256, .channel_binding_data = null };
            }
            break :blk error.ScramMechanismUnavailable;
        },
        .require => blk: {
            if (!has_scram_plus) break :blk error.ScramPlusRequired;
            const binding = tls_server_end_point_binding orelse break :blk error.ChannelBindingUnavailable;
            break :blk .{ .mechanism = SCRAM_SHA_256_PLUS, .channel_binding_data = binding };
        },
    };
}

fn hasMechanism(mechanisms: []const []const u8, name: []const u8) bool {
    for (mechanisms) |mechanism| {
        if (std.mem.eql(u8, mechanism, name)) return true;
    }
    return false;
}

test "map auth type to gss mechanism" {
    try std.testing.expectEqual(GssMechanism.kerberos_v5, mechanismFromAuthType(.kerberos_v5).?);
    try std.testing.expectEqual(GssMechanism.gss, mechanismFromAuthType(.gss).?);
    try std.testing.expectEqual(GssMechanism.sspi, mechanismFromAuthType(.sspi).?);
    try std.testing.expect(mechanismFromAuthType(.sasl) == null);
}

test "parse channel binding mode" {
    try std.testing.expectEqual(ScramChannelBindingMode.disable, ScramChannelBindingMode.parse("disable").?);
    try std.testing.expectEqual(ScramChannelBindingMode.prefer, ScramChannelBindingMode.parse("  Prefer ").?);
    try std.testing.expectEqual(ScramChannelBindingMode.require, ScramChannelBindingMode.parse("required").?);
    try std.testing.expect(ScramChannelBindingMode.parse("bogus") == null);
}

test "auth type policy defaults" {
    const options: AuthOptions = .{};
    try std.testing.expect(authTypeAllowed(options, .cleartext_password));
    try std.testing.expect(authTypeAllowed(options, .md5_password));
    try std.testing.expect(authTypeAllowed(options, .sasl));
    try std.testing.expect(!authTypeAllowed(options, .kerberos_v5));
    try std.testing.expect(!authTypeAllowed(options, .gss));
    try std.testing.expect(!authTypeAllowed(options, .sspi));
}

test "select SCRAM plus when binding available" {
    const mechanisms = [_][]const u8{ SCRAM_SHA_256, SCRAM_SHA_256_PLUS };
    const selection = try selectScramMechanism(&mechanisms, &.{ 0x01, 0x02, 0x03 }, .prefer);
    try std.testing.expectEqualStrings(SCRAM_SHA_256_PLUS, selection.mechanism);
    try std.testing.expect(selection.channel_binding_data != null);
    try std.testing.expectEqual(@as(usize, 3), selection.channel_binding_data.?.len);
}

test "select SCRAM fallback without binding" {
    const mechanisms = [_][]const u8{ SCRAM_SHA_256, SCRAM_SHA_256_PLUS };
    const selection = try selectScramMechanism(&mechanisms, null, .prefer);
    try std.testing.expectEqualStrings(SCRAM_SHA_256, selection.mechanism);
    try std.testing.expect(selection.channel_binding_data == null);
}

test "select SCRAM require plus fails when unavailable" {
    const mechanisms = [_][]const u8{SCRAM_SHA_256};
    try std.testing.expectError(error.ScramPlusRequired, selectScramMechanism(&mechanisms, &.{0xAA}, .require));
}

test "select SCRAM require fails without binding data" {
    const mechanisms = [_][]const u8{ SCRAM_SHA_256, SCRAM_SHA_256_PLUS };
    try std.testing.expectError(error.ChannelBindingUnavailable, selectScramMechanism(&mechanisms, null, .require));
}
