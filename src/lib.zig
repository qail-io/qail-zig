// QAIL Zig - Pure Zig PostgreSQL Driver with AST-Native Query Building
//
// This is the root module that exports all QAIL functionality.
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
        @compileError("qail-zig requires Zig 0.16.0 or newer.");
    }
}

pub const ast = @import("ast/mod.zig");
pub const driver = @import("driver/mod.zig");
pub const transpiler = @import("transpiler/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const analyzer = @import("analyzer/mod.zig");
pub const validator = @import("validator.zig");
pub const sanitize = @import("sanitize.zig");
pub const fmt = @import("fmt.zig");
pub const runtime = @import("runtime/mod.zig");
// Editor LSP is provided by the published qail.rs extension, not this library.

test {
    @import("std").testing.refAllDecls(@This());
    // Fuzz tests — discovered via explicit import
    _ = @import("fuzz/fuzz_decoder.zig");
    _ = @import("fuzz/fuzz_value.zig");
    _ = @import("fuzz/fuzz_transpiler.zig");
    _ = @import("driver/raw_policy.zig");
    _ = @import("driver/cursor.zig");
    _ = @import("tests/protocol_fail_closed_test.zig");
    _ = @import("tests/replication_fail_closed_test.zig");
    _ = @import("tests/startup_fail_closed_test.zig");
}
