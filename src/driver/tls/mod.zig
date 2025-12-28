// TLS Module Index
//
// Re-exports all TLS submodules.

pub const stream = @import("stream.zig");
pub const config = @import("config.zig");
pub const buffer = @import("buffer.zig");

// Re-export main types
pub const StreamReader = stream.StreamReader;
pub const StreamWriter = stream.StreamWriter;
pub const TlsConfig = config.TlsConfig;
pub const VerifyMode = config.VerifyMode;
pub const TlsBuffers = buffer.TlsBuffers;

// Constants
pub const MIN_BUFFER_LEN = stream.MIN_BUFFER_LEN;
pub const TLS_BUFFER_SIZE = buffer.TLS_BUFFER_SIZE;
pub const ENTROPY_SIZE = buffer.ENTROPY_SIZE;

test {
    @import("std").testing.refAllDecls(@This());
}
