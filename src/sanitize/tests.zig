const std = @import("std");
const sanitize = @import("../sanitize.zig");
const ast = @import("../ast/mod.zig");
const raw_cmd = @import("../ast/raw_cmd.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const validateCmd = sanitize.validateCmd;

test "sanitize: valid simple query passes" {
    const cmd = QailCmd.get("users").select(&.{ Expr.col("id"), Expr.col("name") });
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: table injection rejected" {
    const cmd = QailCmd.get("users; DROP TABLE users");
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("table", err.field);
}

test "sanitize: column injection rejected" {
    const cmd = QailCmd.get("users").select(&.{Expr.col("name; DROP TABLE x")});
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("columns", err.field);
}

test "sanitize: insert target expression rejected" {
    const targets = [_]Expr{Expr.int(1)};
    var cmd = QailCmd.add("users").select(&targets);
    cmd.insert_values = &[_]ast.Value{.{ .int = 1 }};

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("insert.column", err.field);
}

test "sanitize: raw sql rejected" {
    const cmd = raw_cmd.command("SELECT 1");
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("command", err.field);
}

test "sanitize: session set rejected" {
    var cmd = QailCmd.get("users");
    cmd.kind = .session_set;
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("command", err.field);
}

test "sanitize: long identifier rejected" {
    var name_buf: [64]u8 = undefined;
    @memset(name_buf[0..], 'a');
    const cmd = QailCmd.get(name_buf[0..]);
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("table", err.field);
}

test "sanitize: qualified identifier parts are validated independently" {
    var schema_buf: [63]u8 = undefined;
    var table_buf: [63]u8 = undefined;
    @memset(schema_buf[0..], 's');
    @memset(table_buf[0..], 't');

    var qualified_buf: [127]u8 = undefined;
    const qualified = try std.fmt.bufPrint(&qualified_buf, "{s}.{s}", .{ schema_buf[0..], table_buf[0..] });
    try std.testing.expect(validateCmd(&QailCmd.get(qualified)) == null);

    const empty_part_err = validateCmd(&QailCmd.get("public..users")).?;
    try std.testing.expectEqualStrings("table", empty_part_err.field);
}

test "sanitize: query and mutation table aliases pass" {
    try std.testing.expect(validateCmd(&QailCmd.get("public.users u")) == null);
    try std.testing.expect(validateCmd(&QailCmd.set("public.users AS u")) == null);
    try std.testing.expect(validateCmd(&QailCmd.del("public.users u")) == null);
}

test "sanitize: ddl table alias shape is rejected" {
    const err = validateCmd(&QailCmd.make("public.users u")).?;
    try std.testing.expectEqualStrings("table", err.field);
}

test "sanitize: join table reference aliases are validated" {
    const good_joins = [_]ast.Join{.{
        .kind = .left,
        .table = "orders o",
        .on_left = "users.id",
        .on_right = "orders.user_id",
    }};
    const good = QailCmd.get("users").join(&good_joins);
    try std.testing.expect(validateCmd(&good) == null);

    const bad_joins = [_]ast.Join{.{
        .kind = .left,
        .table = "orders DROP TABLE x",
        .on_left = "users.id",
        .on_right = "orders.user_id",
    }};
    const bad = QailCmd.get("users").join(&bad_joins);
    const err = validateCmd(&bad).?;
    try std.testing.expectEqualStrings("join.table", err.field);

    const incomplete_alias_joins = [_]ast.Join{.{
        .kind = .left,
        .table = "orders AS",
        .on_left = "users.id",
        .on_right = "orders.user_id",
    }};
    const incomplete_alias = QailCmd.get("users").join(&incomplete_alias_joins);
    const incomplete_err = validateCmd(&incomplete_alias).?;
    try std.testing.expectEqualStrings("join.table", incomplete_err.field);
}

test "sanitize: update from and delete using aliases pass" {
    var update = QailCmd.set("orders");
    update.assignments = &[_]ast.Assignment{.{ .column = "status", .value = .{ .string = "paid" } }};
    update.from_tables = &[_][]const u8{"accounts a"};
    try std.testing.expect(validateCmd(&update) == null);

    var delete = QailCmd.del("orders");
    delete.using_tables = &[_][]const u8{"accounts AS a"};
    try std.testing.expect(validateCmd(&delete) == null);
}

test "sanitize: malformed update from and delete using aliases rejected" {
    var update = QailCmd.set("orders");
    update.assignments = &[_]ast.Assignment{.{ .column = "status", .value = .{ .string = "paid" } }};
    update.from_tables = &[_][]const u8{"accounts DROP TABLE x"};
    const update_err = validateCmd(&update).?;
    try std.testing.expectEqualStrings("from_tables", update_err.field);

    var delete = QailCmd.del("orders");
    delete.using_tables = &[_][]const u8{"accounts; DROP TABLE accounts"};
    const delete_err = validateCmd(&delete).?;
    try std.testing.expectEqualStrings("using_tables", delete_err.field);
}

test "sanitize: typed source query passes" {
    const source = QailCmd.get("users").select(&.{Expr.col("id")});
    const cmd = QailCmd.createViewFromQuery("user_ids", &source);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed cte query passes" {
    const source = QailCmd.get("orders").select(&.{Expr.col("user_id")});
    const ctes = [_]ast.CTEDef{ast.CTEDef.fromQuery("active_orders", &source)};
    const cmd = QailCmd.get("active_orders").withCtes(&ctes);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed recursive cte query passes" {
    const base = QailCmd.get("users").select(&.{Expr.col("id")});
    const recursive = QailCmd.get("active_users").select(&.{Expr.col("id")});
    const ctes = [_]ast.CTEDef{
        ast.CTEDef.fromQuery("active_users", &base).recursiveUnionAll(&recursive).fromSourceTable("users"),
    };
    const cmd = QailCmd.get("active_users").withCtes(&ctes);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed set op query passes" {
    const rhs = QailCmd.get("admins").select(&.{Expr.col("id")});
    const set_ops = [_]ast.SetOpDef{ast.SetOpDef.fromQuery(.union_all, &rhs)};
    const cmd = QailCmd.get("users").withSetOps(&set_ops);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: typed policy predicates pass" {
    const left = Expr.col("tenant_id");
    const right = Expr.int(42);
    const predicate: Expr = .{
        .binary = .{
            .left = &left,
            .op = .eq,
            .right = &right,
        },
    };
    const policy = ast.PolicyDef.create("tenant_only", "orders")
        .restrictive()
        .toRole("app_user")
        .usingExpr(predicate)
        .withCheckExpr(predicate);
    const cmd = QailCmd.createPolicy(policy);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: notify payload is data" {
    const cmd = QailCmd.notifyChannel("events", "x'); DROP TABLE users; --");
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: grant role payload is an identifier" {
    const privs = [_][]const u8{"SELECT"};
    const cmd = QailCmd.grant("users", &privs, "app_role; DROP ROLE app_role");
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("role", err.field);
}

test "sanitize: grant privileges are allowlisted" {
    const allowed = [_][]const u8{ "select", "ALL PRIVILEGES", "temp" };
    const safe = QailCmd.grant("users", &allowed, "app_role");
    try std.testing.expect(validateCmd(&safe) == null);

    const unknown = [_][]const u8{"OWN"};
    const unknown_cmd = QailCmd.grant("users", &unknown, "app_role");
    const unknown_err = validateCmd(&unknown_cmd).?;
    try std.testing.expectEqualStrings("privilege", unknown_err.field);

    const injected = [_][]const u8{"SELECT; DROP TABLE users; --"};
    const injected_cmd = QailCmd.revoke("users", &injected, "app_role");
    const injected_err = validateCmd(&injected_cmd).?;
    try std.testing.expectEqualStrings("privilege", injected_err.field);
}

test "sanitize: comment targets are guarded" {
    var table_comment = QailCmd.commentOn("users");
    table_comment.payload = "owner's note";
    try std.testing.expect(validateCmd(&table_comment) == null);

    var column_comment = QailCmd.commentOn("users.email");
    column_comment.payload = "email column";
    try std.testing.expect(validateCmd(&column_comment) == null);

    var function_comment = QailCmd.commentOn("FUNCTION public.cleanup(numeric(10,2), text)");
    function_comment.payload = "cleanup helper";
    try std.testing.expect(validateCmd(&function_comment) == null);

    var injected_target = QailCmd.commentOn("TABLE users; DROP TABLE users; --");
    injected_target.payload = "bad";
    const target_err = validateCmd(&injected_target).?;
    try std.testing.expectEqualStrings("comment.target", target_err.field);

    var nul_text = QailCmd.commentOn("users");
    nul_text.payload = "owner\x00note";
    const text_err = validateCmd(&nul_text).?;
    try std.testing.expectEqualStrings("comment.text", text_err.field);
}

test "sanitize: raw default payload rejected" {
    var cmd = QailCmd{
        .kind = .alter_set_default,
        .table = "users",
        .columns = &.{Expr.col("role")},
        .payload = "current_user; DROP TABLE users",
    };
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("payload", err.field);
}

test "sanitize: unsafe named parameter rejected" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .eq,
            .value = .{ .named_param = "1bad" },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("value.named_param", err.field);
}

test "sanitize: unsafe raw function value rejected" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "updated_at",
            .op = .lt,
            .value = .{ .function = "now(); DROP TABLE users; --" },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("value.function", err.field);
}

test "sanitize: safe raw function value passes" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "updated_at",
            .op = .lt,
            .value = .{ .function = "now()" },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: valid condition operator shapes pass" {
    const ids = [_]ast.Value{ .{ .int = 1 }, .{ .int = 2 } };
    const wheres = [_]ast.WhereClause{
        .{
            .condition = .{
                .column = "id",
                .op = .in,
                .value = .{ .array = &ids },
            },
        },
        .{
            .condition = .{
                .column = "age",
                .op = .between,
                .value = .{ .range = .{ .low = 18, .high = 65 } },
            },
        },
        .{
            .condition = .{
                .column = "tenant_id",
                .op = .in,
                .value = .{ .param = 1 },
            },
        },
    };
    const cmd = QailCmd.get("users").where(&wheres);

    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: empty in condition rejected" {
    const empty = [_]ast.Value{};
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "role",
            .op = .in,
            .value = .{ .array = &empty },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("condition.value", err.field);
}

test "sanitize: malformed between condition rejected" {
    const one = [_]ast.Value{.{ .int = 18 }};
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "age",
            .op = .between,
            .value = .{ .array = &one },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("condition.value", err.field);
}

test "sanitize: exists operator shape rejected" {
    const where = [_]ast.WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .exists,
            .value = .{ .int = 1 },
        },
    }};
    const cmd = QailCmd.get("users").where(&where);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("condition.value", err.field);
}

test "sanitize: cast type fragments allow safe postgres types" {
    const amount = Expr.col("amount");
    const cols = [_]Expr{.{ .cast = .{
        .expr = &amount,
        .target_type = "numeric(10, 2)",
    } }};
    const cmd = QailCmd.get("orders").select(&cols);

    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: cast type fragments reject statement content" {
    const name = Expr.col("name");
    const cols = [_]Expr{.{ .cast = .{
        .expr = &name,
        .target_type = "text); DROP TABLE users; --",
    } }};
    const cmd = QailCmd.get("users").select(&cols);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("expr.cast_type", err.field);
}

test "sanitize: column definition fragments are validated" {
    const safe_constraints = [_]ast.Constraint{.{ .default = "'semi;inside'" }};
    const safe_cols = [_]Expr{Expr.defWithConstraints("note", "text", &safe_constraints)};
    const safe_cmd = QailCmd.make("events").select(&safe_cols);
    try std.testing.expect(validateCmd(&safe_cmd) == null);

    const unsafe_constraints = [_]ast.Constraint{.{ .default = "0; DROP TABLE users; --" }};
    const unsafe_cols = [_]Expr{Expr.defWithConstraints("score", "integer", &unsafe_constraints)};
    const unsafe_cmd = QailCmd.make("events").select(&unsafe_cols);
    const err = validateCmd(&unsafe_cmd).?;
    try std.testing.expectEqualStrings("column_def.default", err.field);
}

test "sanitize: special function keyword fragments rejected" {
    const created_at = Expr.col("created_at");
    const cols = [_]Expr{.{ .special_func = .{
        .name = "EXTRACT",
        .args = &[_]ast.expr.SpecialFuncArg{.{ .keyword = "FROM; DROP", .expr = &created_at }},
    } }};
    const cmd = QailCmd.get("users").select(&cols);

    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("expr.special_func_kw", err.field);
}

test "sanitize: alter add constraint checks payload fragment" {
    const safe = QailCmd.alterAddConstraint("events", "events_kind_check", "kind <> 'semi;inside'");
    try std.testing.expect(validateCmd(&safe) == null);

    const unsafe = QailCmd.alterAddConstraint("users", "users_active_check", "active); DROP TABLE users; --");
    const err = validateCmd(&unsafe).?;
    try std.testing.expectEqualStrings("payload", err.field);
}

test "sanitize: merge inline source alias passes" {
    const on = [_]ast.Condition{.{
        .left = Expr.col("orders.id"),
        .op = .eq,
        .value = ast.Value.fromColumn("s.order_id"),
    }};
    const clauses = [_]ast.MergeClause{.{
        .match_kind = .matched,
        .action = .do_nothing,
    }};
    const merge = ast.Merge{
        .source = ast.MergeSource.fromTable("stage_orders s"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("orders").withMerge(merge);
    try std.testing.expect(validateCmd(&cmd) == null);
}

test "sanitize: malformed merge source table reference rejected" {
    const on = [_]ast.Condition{.{
        .left = Expr.col("orders.id"),
        .op = .eq,
        .value = ast.Value.fromColumn("stage_orders.order_id"),
    }};
    const clauses = [_]ast.MergeClause{.{
        .match_kind = .matched,
        .action = .do_nothing,
    }};
    const merge = ast.Merge{
        .source = ast.MergeSource.fromTable("stage_orders DROP TABLE x"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("orders").withMerge(merge);
    const err = validateCmd(&cmd).?;
    try std.testing.expectEqualStrings("merge.source.table", err.field);
}

test "sanitize: merge validates source and action expressions" {
    const on = [_]ast.Condition{.{
        .left = Expr.col("users.id"),
        .op = .eq,
        .value = ast.Value.fromColumn("s.id"),
    }};
    const assignments = [_]ast.MergeAssignment{.{
        .column = "name",
        .expr = Expr.col("s.name"),
    }};
    const clauses = [_]ast.MergeClause{.{
        .match_kind = .matched,
        .action = .{ .update = &assignments },
    }};
    const merge = ast.Merge{
        .source = ast.MergeSource.fromTableAs("staging_users", "s"),
        .on = &on,
        .clauses = &clauses,
    };
    const cmd = QailCmd.mergeInto("users").withMerge(merge);
    try std.testing.expect(validateCmd(&cmd) == null);

    const bad_assignments = [_]ast.MergeAssignment{.{
        .column = "name",
        .expr = .{ .raw = "pg_sleep(1)" },
    }};
    const bad_clauses = [_]ast.MergeClause{.{
        .match_kind = .matched,
        .action = .{ .update = &bad_assignments },
    }};
    const bad_merge = ast.Merge{
        .source = ast.MergeSource.fromTableAs("staging_users", "s"),
        .on = &on,
        .clauses = &bad_clauses,
    };
    const bad_cmd = QailCmd.mergeInto("users").withMerge(bad_merge);
    const err = validateCmd(&bad_cmd).?;
    try std.testing.expectEqualStrings("expr.raw", err.field);
}
