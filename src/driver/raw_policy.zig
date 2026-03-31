const std = @import("std");
const ast = @import("../ast/mod.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Condition = ast.Condition;
const TableConstraint = ast.TableConstraint;
const Constraint = ast.Constraint;
const PolicyDef = ast.PolicyDef;
const Value = ast.Value;

/// Returns true when a command uses the raw-SQL runtime escape hatch.
pub fn isRawRuntimeCommand(cmd: *const QailCmd) bool {
    return cmd.kind == .raw or cmd.raw_sql != null;
}

fn valueHasTrustedOnlyEscapeHatch(value: *const Value) bool {
    return switch (value.*) {
        .array => |items| blk: {
            for (items) |item| {
                if (valueHasTrustedOnlyEscapeHatch(&item)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn conditionHasTrustedOnlyEscapeHatch(cond: *const Condition) bool {
    return exprHasTrustedOnlyEscapeHatch(&cond.left) or valueHasTrustedOnlyEscapeHatch(&cond.value);
}

fn constraintHasTrustedOnlyEscapeHatch(constraint: Constraint) bool {
    return switch (constraint) {
        .default, .check, .references, .generated => true,
        else => false,
    };
}

fn tableConstraintHasTrustedOnlyEscapeHatch(constraint: TableConstraint) bool {
    return switch (constraint) {
        .check => true,
        else => false,
    };
}

fn policyHasTrustedOnlyEscapeHatch(policy: *const PolicyDef) bool {
    if (policy.using_sql != null or policy.with_check_sql != null) return true;

    if (policy.using_expr) |using_expr| {
        var expr = using_expr;
        if (exprHasTrustedOnlyEscapeHatch(&expr)) return true;
    }
    if (policy.with_check_expr) |with_check_expr| {
        var expr = with_check_expr;
        if (exprHasTrustedOnlyEscapeHatch(&expr)) return true;
    }

    return false;
}

fn exprHasTrustedOnlyEscapeHatch(expr: *const Expr) bool {
    return switch (expr.*) {
        .binary => |b| exprHasTrustedOnlyEscapeHatch(b.left) or exprHasTrustedOnlyEscapeHatch(b.right),
        .func_call => |f| blk: {
            for (f.args) |*arg| {
                if (exprHasTrustedOnlyEscapeHatch(arg)) break :blk true;
            }
            break :blk false;
        },
        .case_expr => |c| blk: {
            for (c.when_clauses) |*w| {
                if (conditionHasTrustedOnlyEscapeHatch(&w.condition) or exprHasTrustedOnlyEscapeHatch(&w.result)) break :blk true;
            }
            if (c.else_value) |else_expr| {
                if (exprHasTrustedOnlyEscapeHatch(else_expr)) break :blk true;
            }
            break :blk false;
        },
        .subquery, .exists_subquery, .raw => true,
        .coalesce => |c| blk: {
            for (c.exprs) |*e| {
                if (exprHasTrustedOnlyEscapeHatch(e)) break :blk true;
            }
            break :blk false;
        },
        .cast => |c| exprHasTrustedOnlyEscapeHatch(c.expr),
        .column_def => |d| blk: {
            if (d.default_value != null or d.references != null) break :blk true;
            for (d.constraints) |constraint| {
                if (constraintHasTrustedOnlyEscapeHatch(constraint)) break :blk true;
            }
            break :blk false;
        },
        .col_mod => |m| exprHasTrustedOnlyEscapeHatch(m.col),
        .special_func => |s| blk: {
            for (s.args) |arg| {
                if (exprHasTrustedOnlyEscapeHatch(arg.expr)) break :blk true;
            }
            break :blk false;
        },
        .array_constructor => |a| blk: {
            for (a.elements) |*e| {
                if (exprHasTrustedOnlyEscapeHatch(e)) break :blk true;
            }
            break :blk false;
        },
        .row_constructor => |r| blk: {
            for (r.elements) |*e| {
                if (exprHasTrustedOnlyEscapeHatch(e)) break :blk true;
            }
            break :blk false;
        },
        .subscript => |s| exprHasTrustedOnlyEscapeHatch(s.base) or exprHasTrustedOnlyEscapeHatch(s.index),
        .collate => |c| exprHasTrustedOnlyEscapeHatch(c.expr),
        .field_access => |f| exprHasTrustedOnlyEscapeHatch(f.expr),
        .unary => |u| exprHasTrustedOnlyEscapeHatch(u.operand),
        else => false,
    };
}

fn cmdHasTrustedOnlyEscapeHatch(cmd: *const QailCmd) bool {
    if (isRawRuntimeCommand(cmd)) return true;

    switch (cmd.kind) {
        .call, .do_block, .session_set, .session_reset => return true,
        .create_function, .create_trigger, .create_enum, .lock_table => {
            if (cmd.payload != null) return true;
        },
        else => {},
    }

    if (cmd.source_query_sql != null) return true;
    if (cmd.source_query) |source_query| {
        if (cmdHasTrustedOnlyEscapeHatch(source_query)) return true;
    }

    for (cmd.columns) |*expr| {
        if (exprHasTrustedOnlyEscapeHatch(expr)) return true;
    }
    for (cmd.distinct_on) |*expr| {
        if (exprHasTrustedOnlyEscapeHatch(expr)) return true;
    }
    for (cmd.returning) |*expr| {
        if (exprHasTrustedOnlyEscapeHatch(expr)) return true;
    }

    for (cmd.where_clauses) |*clause| {
        if (conditionHasTrustedOnlyEscapeHatch(&clause.condition)) return true;
    }
    for (cmd.having_clauses) |*clause| {
        if (conditionHasTrustedOnlyEscapeHatch(&clause.condition)) return true;
    }

    for (cmd.assignments) |assignment| {
        if (valueHasTrustedOnlyEscapeHatch(&assignment.value)) return true;
    }
    for (cmd.insert_values) |value| {
        if (valueHasTrustedOnlyEscapeHatch(&value)) return true;
    }

    if (cmd.on_conflict) |oc| {
        for (oc.update_columns) |assignment| {
            if (valueHasTrustedOnlyEscapeHatch(&assignment.value)) return true;
        }
    }

    for (cmd.ctes) |cte| {
        if (cte.base_sql.len != 0) return true;
        if (cte.base_query) |query| {
            if (cmdHasTrustedOnlyEscapeHatch(query)) return true;
        }
        if (cte.recursive_query) |query| {
            if (cmdHasTrustedOnlyEscapeHatch(query)) return true;
        }
    }
    for (cmd.set_ops) |set_op| {
        if (set_op.query_sql.len != 0) return true;
        if (set_op.query) |query| {
            if (cmdHasTrustedOnlyEscapeHatch(query)) return true;
        }
    }
    if (cmd.policy_def) |*policy| {
        if (policyHasTrustedOnlyEscapeHatch(policy)) return true;
    }
    for (cmd.table_constraints) |constraint| {
        if (tableConstraintHasTrustedOnlyEscapeHatch(constraint)) return true;
    }

    return false;
}

/// Reject raw runtime commands from the public execution path.
pub fn rejectPublicRuntimeCmd(cmd: *const QailCmd) !void {
    if (cmdHasTrustedOnlyEscapeHatch(cmd)) return error.RawSqlForbidden;
}

/// Reject raw runtime commands from public batched execution paths.
pub fn rejectPublicRuntimeCmds(cmds: []const *const QailCmd) !void {
    for (cmds) |cmd| try rejectPublicRuntimeCmd(cmd);
}

test "raw policy allows regular ast commands" {
    const cmd = @import("../ast/mod.zig").QailCmd.get("users");
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy rejects raw command helper" {
    const raw_cmd = @import("../ast/raw_cmd.zig").command("SELECT 1");
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&raw_cmd));
}

test "raw policy rejects command slices containing raw sql" {
    const good = @import("../ast/mod.zig").QailCmd.get("users");
    const bad = @import("../ast/raw_cmd.zig").command("SELECT 1");
    const cmds = [_]*const QailCmd{ &good, &bad };
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmds(&cmds));
}

test "raw policy rejects expr.raw in public ast commands" {
    const cols = [_]Expr{.{ .raw = "pg_sleep(1)" }};
    const cmd = QailCmd.get("users").select(&cols);
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&cmd));
}

test "raw policy rejects subquery expressions in public ast commands" {
    const cols = [_]Expr{.{ .subquery = .{ .sql = "SELECT count(*) FROM users" } }};
    const cmd = QailCmd.get("users").select(&cols);
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&cmd));
}

test "raw policy rejects raw cte source sql in public ast commands" {
    const ctes = [_]ast.CTEDef{.{ .name = "danger", .base_sql = "SELECT 1" }};
    const cmd = QailCmd.get("users").withCtes(&ctes);
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&cmd));
}

test "raw policy rejects raw ddl fragments in public ast commands" {
    const defs = [_]Expr{.{ .column_def = .{
        .name = "created_at",
        .data_type = "timestamptz",
        .default_value = "now()",
    } }};
    const cmd = QailCmd.make("users").select(&defs);
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&cmd));

    const constraints = [_]TableConstraint{.{ .check = "price > 0" }};
    const constrained = QailCmd.make("products").withConstraints(&constraints);
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&constrained));
}

test "raw policy rejects raw source query sql in public ast commands" {
    var cmd = QailCmd.createMaterializedView("mv_users");
    cmd.source_query_sql = "SELECT * FROM users";
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&cmd));
}

test "raw policy allows typed source query in public ast commands" {
    const source = QailCmd.get("users").select(&.{Expr.col("id")});
    const cmd = QailCmd.createMaterializedView("mv_users").withSourceQuery(&source);
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy allows typed cte queries in public ast commands" {
    const source = QailCmd.get("orders").select(&.{Expr.col("user_id")});
    const ctes = [_]ast.CTEDef{ast.CTEDef.fromQuery("active_orders", &source)};
    const cmd = QailCmd.get("active_orders").withCtes(&ctes);
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy allows typed recursive cte queries in public ast commands" {
    const base = QailCmd.get("users").select(&.{Expr.col("id")});
    const recursive = QailCmd.get("active_users").select(&.{Expr.col("id")});
    const ctes = [_]ast.CTEDef{
        ast.CTEDef.fromQuery("active_users", &base).recursiveUnionAll(&recursive).fromSourceTable("users"),
    };
    const cmd = QailCmd.get("active_users").withCtes(&ctes);
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy allows typed set op queries in public ast commands" {
    const rhs = QailCmd.get("admins").select(&.{Expr.col("id")});
    const set_ops = [_]ast.SetOpDef{ast.SetOpDef.fromQuery(.union_all, &rhs)};
    const cmd = QailCmd.get("users").withSetOps(&set_ops);
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy allows typed policy predicates in public ast commands" {
    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = PolicyDef.create("tenant_only", "orders")
        .restrictive()
        .toRole("app_user")
        .usingExpr(predicate)
        .withCheckExpr(predicate);
    const cmd = QailCmd.createPolicy(policy);
    try rejectPublicRuntimeCmd(&cmd);
}

test "raw policy rejects policy sql in public ast commands" {
    const policy: PolicyDef = .{
        .name = "tenant_only",
        .table = "users",
        .using_sql = "tenant_id = current_setting('app.tenant_id')::uuid",
    };
    const cmd = QailCmd.createPolicy(policy);
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&cmd));
}

test "raw policy rejects raw ddl payloads in public ast commands" {
    var function_cmd = QailCmd.createFunction("touch_users()");
    function_cmd.payload = "() RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$";
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&function_cmd));

    var enum_cmd = QailCmd{ .kind = .create_enum, .table = "mood", .payload = "'happy', 'sad'" };
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&enum_cmd));

    var lock_cmd = QailCmd.lockTable("users");
    lock_cmd.payload = "ACCESS EXCLUSIVE";
    try std.testing.expectError(error.RawSqlForbidden, rejectPublicRuntimeCmd(&lock_cmd));
}

test "raw policy allows typed lock table mode" {
    const cmd = QailCmd.lockTable("users").lockTableMode(.access_exclusive);
    try rejectPublicRuntimeCmd(&cmd);
}

test "source: public driver raw runtime api is not re-exported" {
    const allocator = std.testing.allocator;

    const ast_mod = try std.fs.cwd().readFileAlloc(allocator, "src/ast/mod.zig", 32 * 1024);
    defer allocator.free(ast_mod);
    try std.testing.expect(std.mem.indexOf(u8, ast_mod, "pub const raw_cmd =") == null);

    const expr_src = try std.fs.cwd().readFileAlloc(allocator, "src/ast/expr.zig", 48 * 1024);
    defer allocator.free(expr_src);
    try std.testing.expect(std.mem.indexOf(u8, expr_src, "pub fn raw(") == null);

    const driver_mod = try std.fs.cwd().readFileAlloc(allocator, "src/driver/mod.zig", 32 * 1024);
    defer allocator.free(driver_mod);
    try std.testing.expect(std.mem.indexOf(u8, driver_mod, "pub const raw_sql =") == null);
    try std.testing.expect(std.mem.indexOf(u8, driver_mod, "pub const raw_cmd =") == null);

    const driver_src = try std.fs.cwd().readFileAlloc(allocator, "src/driver/driver.zig", 96 * 1024);
    defer allocator.free(driver_src);
    try std.testing.expect(std.mem.indexOf(u8, driver_src, "pub fn executeRaw(") == null);
}
