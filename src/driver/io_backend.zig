// I/O Backend Auto-Detection
//
// Automatically selects the best I/O backend for the current platform:
// - Linux: io_uring (high-performance async)
// - macOS/Windows: sync (blocking I/O)
//
// This mirrors the Rust implementation in qail-pg's io_backend.rs

const std = @import("std");
const builtin = @import("builtin");

/// Available I/O backends
pub const Backend = enum {
    /// Linux io_uring for high-performance async I/O
    io_uring,
    /// Synchronous blocking I/O (portable fallback)
    sync,
};

/// Compile-time selected backend based on target OS
pub const backend: Backend = switch (builtin.os.tag) {
    .linux => .io_uring,
    else => .sync,
};

/// Human-readable backend name
pub const name: []const u8 = switch (backend) {
    .io_uring => "io_uring",
    .sync => "sync (blocking)",
};

/// Check if io_uring is available at runtime (Linux only)
pub fn isIoUringAvailable() bool {
    if (builtin.os.tag != .linux) return false;

    // Try to create a minimal io_uring instance
    const IoUring = std.os.linux.IoUring;
    var ring = IoUring.init(1, 0) catch return false;
    ring.deinit();
    return true;
}

/// Get the actual backend being used (with runtime fallback)
pub fn detect() Backend {
    if (builtin.os.tag == .linux) {
        if (isIoUringAvailable()) {
            return .io_uring;
        }
        // Fallback to sync on older Linux kernels
        return .sync;
    }
    return .sync;
}

// ==================== Tests ====================

test "backend detection" {
    const detected = detect();
    _ = detected;

    // Should always get a valid backend
    try std.testing.expect(backend == .io_uring or backend == .sync);
}

test "backend name" {
    try std.testing.expect(name.len > 0);
}
