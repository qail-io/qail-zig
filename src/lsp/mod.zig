//! QAIL Language Server Module
//!
//! Provides IDE features for QAIL queries via Language Server Protocol.

pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");

pub const QailServer = server.QailServer;
pub const main = server.main;

// Re-export LSP types
pub const Position = protocol.Position;
pub const Range = protocol.Range;
pub const Diagnostic = protocol.Diagnostic;
pub const CompletionItem = protocol.CompletionItem;
pub const Hover = protocol.Hover;

test {
    @import("std").testing.refAllDecls(@This());
}
