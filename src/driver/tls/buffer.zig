//! TLS Buffer Management
//!
//! Pre-allocated buffers for TLS records.
//! std.crypto.tls.Client requires buffers of at least max_ciphertext_record_len.

const std = @import("std");
const tls = std.crypto.tls;

/// Minimum buffer size for TLS records
pub const TLS_BUFFER_SIZE = tls.max_ciphertext_record_len;

/// Entropy size required by std.crypto.tls.Client
pub const ENTROPY_SIZE = 176;

/// Pre-allocated buffers for TLS connection
pub const TlsBuffers = struct {
    /// Buffer for incoming TLS records
    read_buf: [TLS_BUFFER_SIZE]u8 = undefined,
    /// Buffer for outgoing TLS records
    write_buf: [TLS_BUFFER_SIZE]u8 = undefined,
    /// Entropy for TLS handshake (client random, session ID, key agreement)
    entropy: [ENTROPY_SIZE]u8 = undefined,

    const Self = @This();

    /// Initialize with cryptographic random entropy
    pub fn initSecure() Self {
        var self = Self{};
        std.crypto.random.bytes(&self.entropy);
        return self;
    }

    /// Initialize with zero entropy (INSECURE - for testing only)
    pub fn initInsecure() Self {
        return Self{
            .entropy = [_]u8{0} ** ENTROPY_SIZE,
        };
    }

    /// Get read buffer slice
    pub fn readBuffer(self: *Self) []u8 {
        return &self.read_buf;
    }

    /// Get write buffer slice
    pub fn writeBuffer(self: *Self) []u8 {
        return &self.write_buf;
    }

    /// Get entropy pointer
    pub fn entropyPtr(self: *const Self) *const [ENTROPY_SIZE]u8 {
        return &self.entropy;
    }
};

// ==================== Tests ====================

test "TlsBuffers size" {
    try std.testing.expect(TLS_BUFFER_SIZE >= 16384);
    try std.testing.expectEqual(@as(usize, 176), ENTROPY_SIZE);
}

test "TlsBuffers initSecure" {
    const bufs = TlsBuffers.initSecure();
    // Entropy should not be all zeros (with high probability)
    var all_zero = true;
    for (bufs.entropy) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "TlsBuffers initInsecure" {
    const bufs = TlsBuffers.initInsecure();
    for (bufs.entropy) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}
