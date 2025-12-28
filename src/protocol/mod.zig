// PostgreSQL Wire Protocol Module
//
// This module implements the PostgreSQL wire protocol encoder/decoder.
// Pure Zig, no external dependencies.

pub const wire = @import("wire.zig");
pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");
pub const auth = @import("auth.zig");
pub const types = @import("types.zig");
pub const ast_encoder = @import("ast_encoder.zig");

// Re-export main types
pub const FrontendMessage = wire.FrontendMessage;
pub const BackendMessage = wire.BackendMessage;
pub const Encoder = encoder.Encoder;
pub const Decoder = decoder.Decoder;
pub const AstEncoder = ast_encoder.AstEncoder;

test {
    @import("std").testing.refAllDecls(@This());
}
