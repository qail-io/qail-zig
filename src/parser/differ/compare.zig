const std = @import("std");
const schema = @import("../schema.zig");
const ast = @import("../../ast/mod.zig");

const PolicyDef = schema.PolicyDef;
const GrantDef = schema.GrantDef;
const Expr = ast.Expr;
const Value = ast.Value;

fn optionalStrEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn valueEquals(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |av| switch (b) {
            .bool => |bv| av == bv,
            else => false,
        },
        .int => |av| switch (b) {
            .int => |bv| av == bv,
            else => false,
        },
        .float => |av| switch (b) {
            .float => |bv| av == bv,
            else => false,
        },
        .string => |av| switch (b) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        else => false,
    };
}

fn exprEquals(a: *const Expr, b: *const Expr) bool {
    return switch (a.*) {
        .named => |an| switch (b.*) {
            .named => |bn| std.mem.eql(u8, an, bn),
            else => false,
        },
        .literal => |av| switch (b.*) {
            .literal => |bv| valueEquals(av, bv),
            else => false,
        },
        .func_call => |af| switch (b.*) {
            .func_call => |bf| blk: {
                if (!std.mem.eql(u8, af.name, bf.name)) break :blk false;
                if (af.args.len != bf.args.len) break :blk false;
                for (af.args, 0..) |arg, i| {
                    if (!exprEquals(&arg, &bf.args[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .cast => |ac| switch (b.*) {
            .cast => |bc| std.mem.eql(u8, ac.target_type, bc.target_type) and exprEquals(ac.expr, bc.expr),
            else => false,
        },
        .binary => |ab| switch (b.*) {
            .binary => |bb| ab.op == bb.op and exprEquals(ab.left, bb.left) and exprEquals(ab.right, bb.right),
            else => false,
        },
        else => false,
    };
}

fn optionalExprEq(a: ?Expr, b: ?Expr) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    var av = a.?;
    var bv = b.?;
    return exprEquals(&av, &bv);
}

pub fn policyEquals(a: *const PolicyDef, b: *const PolicyDef) bool {
    return std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.table, b.table) and
        a.target == b.target and
        a.permissiveness == b.permissiveness and
        optionalStrEq(a.role, b.role) and
        optionalExprEq(a.using_expr, b.using_expr) and
        optionalExprEq(a.with_check_expr, b.with_check_expr) and
        optionalStrEq(a.using_sql, b.using_sql) and
        optionalStrEq(a.with_check_sql, b.with_check_sql);
}

pub fn grantEquals(a: *const GrantDef, b: *const GrantDef) bool {
    if (a.action != b.action) return false;
    if (!std.mem.eql(u8, a.on_object, b.on_object)) return false;
    if (!std.mem.eql(u8, a.role, b.role)) return false;
    if (a.privileges.len != b.privileges.len) return false;
    for (a.privileges, 0..) |privilege, i| {
        if (!std.mem.eql(u8, privilege, b.privileges[i])) return false;
    }
    return true;
}
