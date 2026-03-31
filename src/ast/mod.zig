// QAIL AST Module - Core Abstract Syntax Tree types
//
// This module provides the fundamental AST types for building
// database queries in a type-safe, allocator-aware manner.

pub const cmd = @import("cmd.zig");
pub const expr = @import("expr.zig");
pub const values = @import("values.zig");
pub const operators = @import("operators.zig");
pub const cages = @import("cages.zig");
pub const policy = @import("policy.zig");
pub const trusted_nested_query = @import("trusted_nested_query.zig");
pub const builders = @import("builders/mod.zig");

// Re-export main types
pub const QailCmd = cmd.QailCmd;
pub const CmdKind = cmd.CmdKind;
pub const Join = cmd.Join;
pub const JoinKind = cmd.JoinKind;
pub const WhereClause = cmd.WhereClause;
pub const OrderBy = cmd.OrderBy;
pub const Assignment = cmd.Assignment;
pub const CTEDef = cmd.CTEDef;
pub const OnConflict = cmd.OnConflict;
pub const ConflictAction = cmd.ConflictAction;
pub const SetOp = cmd.SetOp;
pub const SetOpDef = cmd.SetOpDef;
pub const GroupByMode = cmd.GroupByMode;
pub const PolicyTarget = cmd.PolicyTarget;
pub const PolicyPermissiveness = cmd.PolicyPermissiveness;
pub const PolicyDef = cmd.PolicyDef;
pub const Expr = expr.Expr;
pub const Condition = expr.Condition;
pub const Value = values.Value;
pub const IntervalUnit = values.IntervalUnit;
pub const Operator = operators.Operator;
pub const BinaryOp = expr.BinaryOp;
pub const LogicalOp = operators.LogicalOp;
pub const SortOrder = operators.SortOrder;
pub const AggregateFunc = operators.AggregateFunc;
pub const LockMode = operators.LockMode;
pub const TableLockMode = operators.TableLockMode;
pub const Distance = operators.Distance;
pub const Constraint = expr.Constraint;
pub const IndexDef = cmd.IndexDef;
pub const TableConstraint = cmd.TableConstraint;
pub const FunctionDef = expr.FunctionDef;
pub const TriggerDef = expr.TriggerDef;
pub const Cage = cages.Cage;
pub const CageKind = cages.CageKind;
pub const OwnedExpr = policy.OwnedExpr;
pub const OwnedPolicyDef = policy.OwnedPolicyDef;

test {
    @import("std").testing.refAllDecls(@This());
}
