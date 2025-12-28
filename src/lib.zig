// QAIL Zig - Pure Zig PostgreSQL Driver with AST-Native Query Building
//
// This is the root module that exports all QAIL functionality.

pub const ast = @import("ast/mod.zig");
pub const protocol = @import("protocol/mod.zig");
pub const driver = @import("driver/mod.zig");
pub const transpiler = @import("transpiler/mod.zig");
pub const parser = @import("parser/mod.zig");

// Re-export key types for convenience
pub const QailCmd = ast.QailCmd;
pub const Expr = ast.Expr;
pub const Operator = ast.Operator;
pub const Value = ast.Value;

pub const PgDriver = driver.PgDriver;
pub const PgRow = driver.PgRow;

test {
    @import("std").testing.refAllDecls(@This());
}
