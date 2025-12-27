//! TLS Configuration
//!
//! Certificate and verification configuration for TLS connections.

const std = @import("std");
const Certificate = std.crypto.Certificate;

/// TLS configuration options
pub const TlsConfig = struct {
    /// Server hostname for SNI and certificate verification
    server_name: ?[]const u8 = null,
    /// Certificate verification mode
    verify: VerifyMode = .no_verification,
    /// Allow truncation attacks (only for testing)
    allow_truncation_attacks: bool = false,
};

/// Certificate verification mode
pub const VerifyMode = union(enum) {
    /// Skip all certificate verification (INSECURE)
    no_verification,
    /// Accept self-signed certificates
    self_signed,
    /// Verify using a certificate bundle
    bundle: Certificate.Bundle,
    // Future: system (load system certs)
};

/// Build std.crypto.tls.Client.Options from TlsConfig
pub fn buildClientOptions(
    config: TlsConfig,
    read_buffer: []u8,
    write_buffer: []u8,
    entropy: *const [176]u8,
) std.crypto.tls.Client.Options {
    return .{
        .host = if (config.server_name) |name|
            .{ .explicit = name }
        else
            .no_verification,
        .ca = switch (config.verify) {
            .no_verification => .no_verification,
            .self_signed => .self_signed,
            .bundle => |b| .{ .bundle = b },
        },
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .entropy = entropy,
        .realtime_now_seconds = std.time.timestamp(),
        .allow_truncation_attacks = config.allow_truncation_attacks,
        .alert = null,
        .ssl_key_log = null,
    };
}

// ==================== Tests ====================

test "TlsConfig default" {
    const config = TlsConfig{};
    try std.testing.expect(config.server_name == null);
    try std.testing.expect(config.verify == .no_verification);
}
