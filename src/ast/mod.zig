//! QAIL AST Module - Core Abstract Syntax Tree types
//!
//! This module provides the fundamental AST types for building
//! database queries in a type-safe, allocator-aware manner.

pub const cmd = @import("cmd.zig");
pub const expr = @import("expr.zig");
pub const values = @import("values.zig");
pub const operators = @import("operators.zig");

// Re-export main types
pub const QailCmd = cmd.QailCmd;
pub const CmdKind = cmd.CmdKind;
pub const Join = cmd.Join;
pub const WhereClause = cmd.WhereClause;
pub const OrderBy = cmd.OrderBy;
pub const Assignment = cmd.Assignment;
pub const Expr = expr.Expr;
pub const Value = values.Value;
pub const Operator = operators.Operator;
pub const BinaryOp = operators.BinaryOp;
pub const LogicalOp = operators.LogicalOp;
pub const AggregateFunc = operators.AggregateFunc;

test {
    @import("std").testing.refAllDecls(@This());
}
