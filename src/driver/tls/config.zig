// TLS Configuration
//
// Certificate and verification configuration for TLS connections.

const std = @import("std");
const Certificate = std.crypto.Certificate;
const channel_binding = @import("channel_binding.zig");

/// TLS configuration options
pub const TlsConfig = struct {
    /// Server hostname for SNI and certificate verification
    server_name: ?[]const u8 = null,
    /// Certificate verification mode
    verify: VerifyMode = .no_verification,
    /// Optional fallback leaf certificate DER bytes used to derive SCRAM
    /// `tls-server-end-point` channel binding when handshake capture is not
    /// available, or as deterministic test input.
    ///
    /// This preserves automatic SCRAM+ binding wiring without needing per-connect
    /// `AuthOptions.scram_tls_server_end_point_binding` assignment.
    tls_server_end_point_cert_der: ?[]const u8 = null,
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

pub const ClientOptions = struct {
    host: union(enum) {
        no_verification,
        explicit: []const u8,
    },
    ca: union(enum) {
        no_verification,
        self_signed,
        bundle: Certificate.Bundle,
    },
    read_buffer: []u8,
    write_buffer: []u8,
    allow_truncation_attacks: bool = false,
    alert: ?*std.crypto.tls.Alert = null,
};

/// Build std.crypto.tls.Client.Options from TlsConfig
pub fn buildClientOptions(
    config: TlsConfig,
    read_buffer: []u8,
    write_buffer: []u8,
) ClientOptions {
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
        .allow_truncation_attacks = config.allow_truncation_attacks,
        .alert = null,
    };
}

/// Derive SCRAM `tls-server-end-point` bytes from leaf certificate DER.
pub fn deriveTlsServerEndPointBindingFromCertDer(
    allocator: std.mem.Allocator,
    cert_der: []const u8,
) ![]u8 {
    return channel_binding.deriveTlsServerEndPointBindingFromCertDer(allocator, cert_der);
}

// ==================== Tests ====================

test "TlsConfig default" {
    const config = TlsConfig{};
    try std.testing.expect(config.server_name == null);
    try std.testing.expect(config.verify == .no_verification);
    try std.testing.expect(config.tls_server_end_point_cert_der == null);
}
