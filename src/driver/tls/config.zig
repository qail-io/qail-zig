// TLS Configuration
//
// Certificate and verification configuration for TLS connections.

const std = @import("std");
const Certificate = std.crypto.Certificate;

/// TLS configuration options
pub const TlsConfig = struct {
    /// Server hostname for SNI and certificate verification
    server_name: ?[]const u8 = null,
    /// Certificate verification mode
    verify: VerifyMode = .no_verification,
    /// Optional leaf certificate DER bytes used to derive SCRAM
    /// `tls-server-end-point` channel binding automatically.
    ///
    /// This provides automatic SCRAM+ binding wiring without needing per-connect
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

/// Build std.crypto.tls.Client.Options from TlsConfig
pub fn buildClientOptions(
    config: TlsConfig,
    read_buffer: []u8,
    write_buffer: []u8,
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
        .allow_truncation_attacks = config.allow_truncation_attacks,
        .alert = null,
        .ssl_key_log = null,
    };
}

const BindingHash = enum {
    sha224,
    sha256,
    sha384,
    sha512,
};

fn bindingHashForSignatureAlgorithm(signature_algorithm: Certificate.Algorithm) BindingHash {
    return switch (signature_algorithm) {
        .sha224WithRSAEncryption, .ecdsa_with_SHA224 => .sha224,
        .sha256WithRSAEncryption, .ecdsa_with_SHA256 => .sha256,
        .sha384WithRSAEncryption, .ecdsa_with_SHA384 => .sha384,
        .sha512WithRSAEncryption, .ecdsa_with_SHA512 => .sha512,
        // RFC 5929 section 4.1:
        // if the cert signature algorithm hash is MD5/SHA-1 (or algorithm has
        // no embedded hash), use SHA-256 for tls-server-end-point.
        .sha1WithRSAEncryption,
        .md2WithRSAEncryption,
        .md5WithRSAEncryption,
        .curveEd25519,
        => .sha256,
    };
}

fn deriveTlsServerEndPointBindingFromSignatureAlgorithm(
    allocator: std.mem.Allocator,
    cert_der: []const u8,
    signature_algorithm: Certificate.Algorithm,
) ![]u8 {
    return switch (bindingHashForSignatureAlgorithm(signature_algorithm)) {
        .sha224 => blk: {
            var digest: [std.crypto.hash.sha2.Sha224.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha224.hash(cert_der, &digest, .{});
            break :blk allocator.dupe(u8, &digest);
        },
        .sha256 => blk: {
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(cert_der, &digest, .{});
            break :blk allocator.dupe(u8, &digest);
        },
        .sha384 => blk: {
            var digest: [std.crypto.hash.sha2.Sha384.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha384.hash(cert_der, &digest, .{});
            break :blk allocator.dupe(u8, &digest);
        },
        .sha512 => blk: {
            var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha512.hash(cert_der, &digest, .{});
            break :blk allocator.dupe(u8, &digest);
        },
    };
}

/// Derive SCRAM `tls-server-end-point` bytes from leaf certificate DER.
pub fn deriveTlsServerEndPointBindingFromCertDer(
    allocator: std.mem.Allocator,
    cert_der: []const u8,
) ![]u8 {
    if (cert_der.len == 0) return error.InvalidCertificate;
    const cert: Certificate = .{
        .buffer = cert_der,
        .index = 0,
    };
    const parsed = try cert.parse();
    return deriveTlsServerEndPointBindingFromSignatureAlgorithm(
        allocator,
        cert_der,
        parsed.signature_algorithm,
    );
}

// ==================== Tests ====================

test "TlsConfig default" {
    const config = TlsConfig{};
    try std.testing.expect(config.server_name == null);
    try std.testing.expect(config.verify == .no_verification);
    try std.testing.expect(config.tls_server_end_point_cert_der == null);
}

test "binding hash weak signature fallback" {
    try std.testing.expectEqual(
        BindingHash.sha256,
        bindingHashForSignatureAlgorithm(.sha1WithRSAEncryption),
    );
    try std.testing.expectEqual(
        BindingHash.sha256,
        bindingHashForSignatureAlgorithm(.md5WithRSAEncryption),
    );
    try std.testing.expectEqual(
        BindingHash.sha256,
        bindingHashForSignatureAlgorithm(.curveEd25519),
    );
}

test "derive binding digest length by signature algorithm" {
    const sample = "dummy-der-certificate";

    const sha224 = try deriveTlsServerEndPointBindingFromSignatureAlgorithm(
        std.testing.allocator,
        sample,
        .sha224WithRSAEncryption,
    );
    defer std.testing.allocator.free(sha224);
    try std.testing.expectEqual(@as(usize, 28), sha224.len);

    const sha256 = try deriveTlsServerEndPointBindingFromSignatureAlgorithm(
        std.testing.allocator,
        sample,
        .sha256WithRSAEncryption,
    );
    defer std.testing.allocator.free(sha256);
    try std.testing.expectEqual(@as(usize, 32), sha256.len);

    const sha384 = try deriveTlsServerEndPointBindingFromSignatureAlgorithm(
        std.testing.allocator,
        sample,
        .sha384WithRSAEncryption,
    );
    defer std.testing.allocator.free(sha384);
    try std.testing.expectEqual(@as(usize, 48), sha384.len);

    const sha512 = try deriveTlsServerEndPointBindingFromSignatureAlgorithm(
        std.testing.allocator,
        sample,
        .sha512WithRSAEncryption,
    );
    defer std.testing.allocator.free(sha512);
    try std.testing.expectEqual(@as(usize, 64), sha512.len);
}
