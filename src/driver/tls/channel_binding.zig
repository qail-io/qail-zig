const std = @import("std");
const Certificate = std.crypto.Certificate;

pub const BindingHash = enum {
    sha224,
    sha256,
    sha384,
    sha512,
};

pub fn bindingHashForSignatureAlgorithm(signature_algorithm: Certificate.Algorithm) BindingHash {
    return switch (signature_algorithm) {
        .sha224WithRSAEncryption, .ecdsa_with_SHA224 => .sha224,
        .sha256WithRSAEncryption, .ecdsa_with_SHA256 => .sha256,
        .sha384WithRSAEncryption, .ecdsa_with_SHA384 => .sha384,
        .sha512WithRSAEncryption, .ecdsa_with_SHA512 => .sha512,
        .sha1WithRSAEncryption,
        .md2WithRSAEncryption,
        .md5WithRSAEncryption,
        .curveEd25519,
        => .sha256,
    };
}

pub fn deriveTlsServerEndPointBindingFromSignatureAlgorithm(
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
