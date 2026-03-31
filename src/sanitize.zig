//! AST structural sanitization for untrusted input.
//!
//! This validator is intended for ASTs that originate from untrusted sources
//! (binary endpoints, external APIs, etc.). It rejects unsafe identifiers and
//! any raw SQL escape hatches that bypass the AST.

const std = @import("std");
const ast = @import("ast/mod.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Condition = ast.Condition;
const Value = ast.Value;
const PolicyDef = ast.PolicyDef;
const TableConstraint = ast.TableConstraint;

pub const SanitizeError = struct {
    field: []const u8,
    value: []const u8,
    reason: []const u8,
};

const MAX_IDENT_LEN: usize = 63; // Postgres NAMEDATALEN - 1

fn isSafeIdent(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_IDENT_LEN) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn isSafeParam(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn shortValue(value: []const u8) []const u8 {
    return if (value.len > 40) value[0..40] else value;
}

fn identError(field: []const u8, value: []const u8) SanitizeError {
    return .{
        .field = field,
        .value = shortValue(value),
        .reason = "identifiers must match [a-zA-Z0-9_.] and be <= 63 chars",
    };
}

fn rawError(field: []const u8) SanitizeError {
    return .{
        .field = field,
        .value = "",
        .reason = "raw SQL fragments are not allowed in untrusted ASTs",
    };
}

fn checkIdent(field: []const u8, value: []const u8) ?SanitizeError {
    if (!isSafeIdent(value)) return identError(field, value);
    return null;
}

fn checkParam(field: []const u8, value: []const u8) ?SanitizeError {
    if (!isSafeParam(value)) {
        return .{
            .field = field,
            .value = shortValue(value),
            .reason = "parameter names must match [a-zA-Z0-9_]",
        };
    }
    return null;
}

fn checkValue(field: []const u8, value: *const Value) ?SanitizeError {
    return switch (value.*) {
        .column => |c| checkIdent(field, c),
        .function => |f| checkIdent(field, f),
        .named_param => |p| checkParam(field, p),
        .array => |arr| blk: {
            for (arr) |v| {
                if (checkValue(field, &v)) |err| break :blk err;
            }
            break :blk null;
        },
        else => null,
    };
}

fn checkCondition(cond: *const Condition) ?SanitizeError {
    if (cond.column.len != 0) {
        if (checkIdent("condition.column", cond.column)) |err| return err;
    } else {
        if (checkExpr("condition.left", &cond.left)) |err| return err;
    }
    if (checkValue("condition.value", &cond.value)) |err| return err;
    return null;
}

fn checkJsonPath(key: []const u8) ?SanitizeError {
    // Allow numeric indexes, otherwise enforce safe identifier.
    if (std.fmt.parseInt(i64, key, 10)) |_| {
        return null;
    } else |_| {}
    return checkIdent("json.path", key);
}

fn checkExpr(field: []const u8, expr: *const Expr) ?SanitizeError {
    return switch (expr.*) {
        .star => null,
        .named => |name| checkIdent(field, name),
        .aliased => |a| blk: {
            if (checkIdent(field, a.name)) |err| break :blk err;
            break :blk checkIdent("expr.alias", a.alias);
        },
        .aggregate => |a| blk: {
            if (!(a.column.len == 1 and a.column[0] == '*')) {
                if (checkIdent(field, a.column)) |err| break :blk err;
            }
            if (a.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .literal => |v| checkValue("expr.literal", &v),
        .binary => |b| blk: {
            if (checkExpr(field, b.left)) |err| break :blk err;
            if (checkExpr(field, b.right)) |err| break :blk err;
            if (b.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .json_access => |j| blk: {
            if (checkIdent(field, j.column)) |err| break :blk err;
            for (j.path) |seg| {
                if (checkJsonPath(seg.key)) |err| break :blk err;
            }
            if (j.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .func_call => |f| blk: {
            if (checkIdent("expr.func", f.name)) |err| break :blk err;
            for (f.args) |*arg| {
                if (checkExpr("expr.arg", arg)) |err| break :blk err;
            }
            if (f.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .case_expr => |c| blk: {
            for (c.when_clauses) |*w| {
                if (checkCondition(&w.condition)) |err| break :blk err;
                if (checkExpr("expr.case", &w.result)) |err| break :blk err;
            }
            if (c.else_value) |else_expr| {
                if (checkExpr("expr.case_else", else_expr)) |err| break :blk err;
            }
            if (c.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .subquery => |_| rawError("expr.subquery"),
        .exists_subquery => |_| rawError("expr.exists_subquery"),
        .coalesce => |c| blk: {
            for (c.exprs) |*e| {
                if (checkExpr("expr.coalesce", e)) |err| break :blk err;
            }
            if (c.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .cast => |c| blk: {
            if (checkExpr(field, c.expr)) |err| break :blk err;
            if (checkIdent("expr.cast_type", c.target_type)) |err| break :blk err;
            if (c.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .column_def => |d| blk: {
            if (checkIdent("column_def.name", d.name)) |err| break :blk err;
            if (checkIdent("column_def.type", d.data_type)) |err| break :blk err;
            if (d.default_value != null or d.references != null) break :blk rawError("column_def.raw");
            break :blk null;
        },
        .window => |w| blk: {
            if (w.name.len != 0) {
                if (checkIdent("window.name", w.name)) |err| break :blk err;
            }
            if (checkIdent("window.func", w.func)) |err| break :blk err;
            for (w.partition) |p| {
                if (checkIdent("window.partition", p)) |err| break :blk err;
            }
            for (w.order) |o| {
                if (checkIdent("window.order", o.column)) |err| break :blk err;
            }
            if (w.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .col_mod => |m| checkExpr(field, m.col),
        .special_func => |s| blk: {
            if (checkIdent("expr.special_func", s.name)) |err| break :blk err;
            for (s.args) |arg| {
                if (arg.keyword) |kw| {
                    if (checkIdent("expr.special_func_kw", kw)) |err| break :blk err;
                }
                if (checkExpr("expr.special_func_arg", arg.expr)) |err| break :blk err;
            }
            if (s.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .array_constructor => |a| blk: {
            for (a.elements) |*e| {
                if (checkExpr("expr.array", e)) |err| break :blk err;
            }
            if (a.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .row_constructor => |r| blk: {
            for (r.elements) |*e| {
                if (checkExpr("expr.row", e)) |err| break :blk err;
            }
            if (r.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .subscript => |s| blk: {
            if (checkExpr("expr.subscript.base", s.base)) |err| break :blk err;
            if (checkExpr("expr.subscript.index", s.index)) |err| break :blk err;
            if (s.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .collate => |c| blk: {
            if (checkExpr("expr.collate", c.expr)) |err| break :blk err;
            if (checkIdent("expr.collation", c.collation)) |err| break :blk err;
            if (c.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .field_access => |f| blk: {
            if (checkExpr("expr.field_access", f.expr)) |err| break :blk err;
            if (checkIdent("expr.field", f.field)) |err| break :blk err;
            if (f.alias) |alias| {
                if (checkIdent("expr.alias", alias)) |err| break :blk err;
            }
            break :blk null;
        },
        .unary => |u| checkExpr(field, u.operand),
        .raw => |_| rawError("expr.raw"),
    };
}

fn checkPolicy(policy: *const PolicyDef) ?SanitizeError {
    if (checkIdent("policy.name", policy.name)) |err| return err;
    if (checkIdent("policy.table", policy.table)) |err| return err;
    if (policy.role) |role| {
        if (checkIdent("policy.role", role)) |err| return err;
    }
    if (policy.using_expr) |using_expr| {
        var expr = using_expr;
        if (checkExpr("policy.using", &expr)) |err| return err;
    }
    if (policy.with_check_expr) |with_check_expr| {
        var expr = with_check_expr;
        if (checkExpr("policy.with_check", &expr)) |err| return err;
    }
    if (policy.using_sql != null or policy.with_check_sql != null) {
        return rawError("policy.raw");
    }
    return null;
}

fn checkConstraint(constraint: TableConstraint) ?SanitizeError {
    return switch (constraint) {
        .unique => |cols| blk: {
            for (cols) |c| {
                if (checkIdent("constraint.column", c)) |err| break :blk err;
            }
            break :blk null;
        },
        .primary_key => |cols| blk: {
            for (cols) |c| {
                if (checkIdent("constraint.column", c)) |err| break :blk err;
            }
            break :blk null;
        },
        .foreign_key => |fk| blk: {
            for (fk.columns) |c| {
                if (checkIdent("constraint.column", c)) |err| break :blk err;
            }
            if (checkIdent("constraint.ref_table", fk.ref_table)) |err| break :blk err;
            for (fk.ref_columns) |c| {
                if (checkIdent("constraint.ref_column", c)) |err| break :blk err;
            }
            break :blk null;
        },
        .check => |_| rawError("constraint.check"),
    };
}

/// Validate a QailCmd AST from an untrusted source.
///
/// Returns null when valid, or a SanitizeError describing the first violation.
pub fn validateCmd(cmd: *const QailCmd) ?SanitizeError {
    // Block dangerous actions from untrusted paths.
    switch (cmd.kind) {
        .call, .do_block, .session_set, .session_reset, .raw => {
            return .{
                .field = "command",
                .value = "",
                .reason = "procedural or raw actions are not allowed in untrusted ASTs",
            };
        },
        else => {},
    }

    if (cmd.table.len != 0) {
        if (checkIdent("table", cmd.table)) |err| return err;
    }
    if (cmd.table_alias) |alias| {
        if (checkIdent("table_alias", alias)) |err| return err;
    }

    for (cmd.columns) |*col| {
        if (checkExpr("columns", col)) |err| return err;
    }
    for (cmd.distinct_on) |*col| {
        if (checkExpr("distinct_on", col)) |err| return err;
    }
    for (cmd.returning) |*col| {
        if (checkExpr("returning", col)) |err| return err;
    }

    for (cmd.where_clauses) |*clause| {
        if (checkCondition(&clause.condition)) |err| return err;
    }
    for (cmd.having_clauses) |*clause| {
        if (checkCondition(&clause.condition)) |err| return err;
    }

    for (cmd.joins) |join| {
        if (checkIdent("join.table", join.table)) |err| return err;
        if (join.alias) |alias| {
            if (checkIdent("join.alias", alias)) |err| return err;
        }
        if (checkIdent("join.on_left", join.on_left)) |err| return err;
        if (checkIdent("join.on_right", join.on_right)) |err| return err;
    }

    for (cmd.order_by) |order| {
        if (checkIdent("order_by", order.column)) |err| return err;
    }
    for (cmd.group_by) |col| {
        if (checkIdent("group_by", col)) |err| return err;
    }

    for (cmd.assignments) |assign| {
        if (checkIdent("assignment.column", assign.column)) |err| return err;
        if (checkValue("assignment.value", &assign.value)) |err| return err;
    }
    for (cmd.insert_values) |*val| {
        if (checkValue("insert_values", val)) |err| return err;
    }

    if (cmd.on_conflict) |oc| {
        for (oc.columns) |c| {
            if (checkIdent("on_conflict.column", c)) |err| return err;
        }
        for (oc.update_columns) |u| {
            if (checkIdent("on_conflict.update", u.column)) |err| return err;
            if (checkValue("on_conflict.value", &u.value)) |err| return err;
        }
    }

    for (cmd.ctes) |cte| {
        if (checkIdent("cte.name", cte.name)) |err| return err;
        for (cte.columns) |c| {
            if (checkIdent("cte.column", c)) |err| return err;
        }
        if (cte.source_table) |table| {
            if (checkIdent("cte.source_table", table)) |err| return err;
        }
        if (cte.base_sql.len != 0) return rawError("cte.base_sql");
        if (cte.base_query) |query| {
            if (validateCmd(query)) |err| return err;
        }
        if (cte.recursive_query) |query| {
            if (validateCmd(query)) |err| return err;
        }
    }

    for (cmd.set_ops) |set_op| {
        if (set_op.query_sql.len != 0) return rawError("set_ops.query_sql");
        if (set_op.query) |query| {
            if (validateCmd(query)) |err| return err;
        }
    }
    if (cmd.source_query_sql != null) return rawError("source_query_sql");
    if (cmd.source_query) |query| {
        if (validateCmd(query)) |err| return err;
    }

    for (cmd.from_tables) |t| {
        if (checkIdent("from_tables", t)) |err| return err;
    }
    for (cmd.using_tables) |t| {
        if (checkIdent("using_tables", t)) |err| return err;
    }

    if (cmd.policy_def) |*p| {
        if (checkPolicy(p)) |err| return err;
    }

    if (cmd.index_def) |idx| {
        if (checkIdent("index.name", idx.name)) |err| return err;
        if (checkIdent("index.table", idx.table)) |err| return err;
        for (idx.columns) |c| {
            if (checkIdent("index.column", c)) |err| return err;
        }
    }

    for (cmd.table_constraints) |constraint| {
        if (checkConstraint(constraint)) |err| return err;
    }

    if (cmd.channel) |ch| {
        if (checkIdent("channel", ch)) |err| return err;
    }
    if (cmd.savepoint_name) |name| {
        if (checkIdent("savepoint", name)) |err| return err;
    }

    for (cmd.privileges) |p| {
        if (checkIdent("privilege", p)) |err| return err;
    }

    if (cmd.vector_name) |name| {
        if (checkIdent("vector_name", name)) |err| return err;
    }

    if (cmd.raw_sql != null) return rawError("raw_sql");

    return null;
}

test {
    _ = @import("sanitize/tests.zig");
}
