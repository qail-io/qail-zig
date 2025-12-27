//! Transpiler Module
//!
//! Converts QAIL AST to SQL for debugging and logging purposes.

pub const postgres = @import("postgres.zig");

pub const toSql = postgres.toSql;

test {
    @import("std").testing.refAllDecls(@This());
}
