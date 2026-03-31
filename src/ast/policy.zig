const std = @import("std");
const expr_mod = @import("expr.zig");
const values = @import("values.zig");
const binary_ops = @import("builders/binary.zig");

const Expr = expr_mod.Expr;
const Value = values.Value;
const Allocator = std.mem.Allocator;

fn cloneOwnedValue(allocator: Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
        .named_param => |p| .{ .named_param = try allocator.dupe(u8, p) },
        .function => |f| .{ .function = try allocator.dupe(u8, f) },
        .column => |c| .{ .column = try allocator.dupe(u8, c) },
        .uuid => |u| .{ .uuid = try allocator.dupe(u8, u) },
        .timestamp => |ts| .{ .timestamp = try allocator.dupe(u8, ts) },
        .json => |j| .{ .json = try allocator.dupe(u8, j) },
        .array => |items| blk: {
            const cloned = try allocator.alloc(Value, items.len);
            var cloned_len: usize = 0;
            errdefer {
                for (cloned[0..cloned_len]) |item| freeOwnedValue(allocator, item);
                allocator.free(cloned);
            }
            for (items, 0..) |item, i| {
                cloned[i] = try cloneOwnedValue(allocator, item);
                cloned_len = i + 1;
            }
            break :blk .{ .array = cloned };
        },
        else => value,
    };
}

fn freeOwnedValue(allocator: Allocator, value: Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .bytes => |b| allocator.free(b),
        .named_param => |p| allocator.free(p),
        .function => |f| allocator.free(f),
        .column => |c| allocator.free(c),
        .uuid => |u| allocator.free(u),
        .timestamp => |ts| allocator.free(ts),
        .json => |j| allocator.free(j),
        .array => |items| {
            for (items) |item| freeOwnedValue(allocator, item);
            allocator.free(items);
        },
        else => {},
    }
}

pub fn cloneOwnedExpr(allocator: Allocator, expr: Expr) !Expr {
    return switch (expr) {
        .named => |name| .{ .named = try allocator.dupe(u8, name) },
        .literal => |value| .{ .literal = try cloneOwnedValue(allocator, value) },
        .func_call => |fc| blk: {
            const args = try allocator.alloc(Expr, fc.args.len);
            var cloned_len: usize = 0;
            errdefer {
                for (args[0..cloned_len]) |arg| freeOwnedExpr(allocator, arg);
                allocator.free(args);
            }
            for (fc.args, 0..) |arg, i| {
                args[i] = try cloneOwnedExpr(allocator, arg);
                cloned_len = i + 1;
            }
            const name = try allocator.dupe(u8, fc.name);
            errdefer allocator.free(name);
            const alias = if (fc.alias) |fc_alias| try allocator.dupe(u8, fc_alias) else null;
            errdefer if (alias) |fc_alias| allocator.free(fc_alias);
            break :blk .{
                .func_call = .{
                    .name = name,
                    .args = args,
                    .alias = alias,
                },
            };
        },
        .cast => |c| blk: {
            const inner = try allocator.create(Expr);
            errdefer allocator.destroy(inner);
            inner.* = try cloneOwnedExpr(allocator, c.expr.*);
            errdefer freeOwnedExpr(allocator, inner.*);
            const target_type = try allocator.dupe(u8, c.target_type);
            errdefer allocator.free(target_type);
            const alias = if (c.alias) |cast_alias| try allocator.dupe(u8, cast_alias) else null;
            errdefer if (alias) |cast_alias| allocator.free(cast_alias);
            break :blk .{
                .cast = .{
                    .expr = inner,
                    .target_type = target_type,
                    .alias = alias,
                },
            };
        },
        .binary => |b| blk: {
            const left = try allocator.create(Expr);
            errdefer allocator.destroy(left);
            left.* = try cloneOwnedExpr(allocator, b.left.*);
            errdefer freeOwnedExpr(allocator, left.*);

            const right = try allocator.create(Expr);
            errdefer allocator.destroy(right);
            right.* = try cloneOwnedExpr(allocator, b.right.*);
            errdefer freeOwnedExpr(allocator, right.*);
            const alias = if (b.alias) |binary_alias| try allocator.dupe(u8, binary_alias) else null;
            errdefer if (alias) |binary_alias| allocator.free(binary_alias);

            break :blk .{
                .binary = .{
                    .left = left,
                    .op = b.op,
                    .right = right,
                    .alias = alias,
                },
            };
        },
        else => return error.UnsupportedOwnedExpr,
    };
}

fn freeOwnedExprPtr(allocator: Allocator, ptr: *const Expr) void {
    freeOwnedExpr(allocator, ptr.*);
    allocator.destroy(@constCast(ptr));
}

pub fn freeOwnedExpr(allocator: Allocator, expr: Expr) void {
    switch (expr) {
        .named => |name| allocator.free(name),
        .literal => |value| freeOwnedValue(allocator, value),
        .func_call => |fc| {
            allocator.free(fc.name);
            for (fc.args) |arg| freeOwnedExpr(allocator, arg);
            allocator.free(fc.args);
            if (fc.alias) |alias| allocator.free(alias);
        },
        .cast => |c| {
            freeOwnedExprPtr(allocator, c.expr);
            allocator.free(c.target_type);
            if (c.alias) |alias| allocator.free(alias);
        },
        .binary => |b| {
            freeOwnedExprPtr(allocator, b.left);
            freeOwnedExprPtr(allocator, b.right);
            if (b.alias) |alias| allocator.free(alias);
        },
        else => {},
    }
}

pub const OwnedExpr = struct {
    allocator: Allocator,
    expr: Expr,

    pub fn init(allocator: Allocator, expr: Expr) !OwnedExpr {
        return .{
            .allocator = allocator,
            .expr = try cloneOwnedExpr(allocator, expr),
        };
    }

    pub fn deinit(self: *OwnedExpr) void {
        freeOwnedExpr(self.allocator, self.expr);
        self.* = undefined;
    }

    pub fn value(self: *const OwnedExpr) Expr {
        return self.expr;
    }

    pub fn root(self: *const OwnedExpr) *const Expr {
        return &self.expr;
    }

    pub fn take(self: *OwnedExpr) Expr {
        const expr = self.expr;
        self.* = undefined;
        return expr;
    }
};

pub fn tenantCheck(allocator: Allocator, column: []const u8, session_var: []const u8, cast_type: []const u8) !OwnedExpr {
    const session_arg = Expr.str(session_var);
    const args = [_]Expr{session_arg};
    const current_setting: Expr = .{
        .func_call = .{
            .name = "current_setting",
            .args = &args,
        },
    };
    const cast_expr: Expr = .{
        .cast = .{
            .expr = &current_setting,
            .target_type = cast_type,
        },
    };
    const left = Expr.col(column);
    return OwnedExpr.init(allocator, binary_ops.binary(&left, .eq, &cast_expr));
}

pub fn sessionBoolCheck(allocator: Allocator, session_var: []const u8) !OwnedExpr {
    const session_arg = Expr.str(session_var);
    const args = [_]Expr{session_arg};
    const current_setting: Expr = .{
        .func_call = .{
            .name = "current_setting",
            .args = &args,
        },
    };
    const cast_expr: Expr = .{
        .cast = .{
            .expr = &current_setting,
            .target_type = "boolean",
        },
    };
    const expected = Expr.val(Value.fromBool(true));
    return OwnedExpr.init(allocator, binary_ops.binary(&cast_expr, .eq, &expected));
}

pub fn orExpr(allocator: Allocator, left: *const Expr, right: *const Expr) !OwnedExpr {
    return OwnedExpr.init(allocator, binary_ops.orExpr(left, right));
}

pub fn andExpr(allocator: Allocator, left: *const Expr, right: *const Expr) !OwnedExpr {
    return OwnedExpr.init(allocator, binary_ops.andExpr(left, right));
}

test "tenantCheck builds typed tenant predicate" {
    var owned = try tenantCheck(std.testing.allocator, "tenant_id", "app.current_tenant_id", "uuid");
    defer owned.deinit();

    const expr = owned.value();
    try std.testing.expect(expr == .binary);
    try std.testing.expect(expr.binary.left.* == .named);
    try std.testing.expectEqualStrings("tenant_id", expr.binary.left.named);
    try std.testing.expectEqual(expr_mod.BinaryOp.eq, expr.binary.op);
    try std.testing.expect(expr.binary.right.* == .cast);
    try std.testing.expectEqualStrings("uuid", expr.binary.right.cast.target_type);
    try std.testing.expect(expr.binary.right.cast.expr.* == .func_call);
    try std.testing.expectEqualStrings("current_setting", expr.binary.right.cast.expr.func_call.name);
}

test "sessionBoolCheck builds typed session bool predicate" {
    var owned = try sessionBoolCheck(std.testing.allocator, "app.is_super_admin");
    defer owned.deinit();

    const expr = owned.value();
    try std.testing.expect(expr == .binary);
    try std.testing.expectEqual(expr_mod.BinaryOp.eq, expr.binary.op);
    try std.testing.expect(expr.binary.left.* == .cast);
    try std.testing.expectEqualStrings("boolean", expr.binary.left.cast.target_type);
    try std.testing.expect(expr.binary.right.* == .literal);
    try std.testing.expectEqual(true, expr.binary.right.literal.bool);
}

test "policy helpers combine owned expressions with or" {
    var tenant = try tenantCheck(std.testing.allocator, "tenant_id", "app.current_tenant_id", "uuid");
    defer tenant.deinit();

    var admin = try sessionBoolCheck(std.testing.allocator, "app.is_super_admin");
    defer admin.deinit();

    var combined = try orExpr(std.testing.allocator, tenant.root(), admin.root());
    defer combined.deinit();

    const expr = combined.value();
    try std.testing.expect(expr == .binary);
    try std.testing.expectEqual(expr_mod.BinaryOp.@"or", expr.binary.op);
}
