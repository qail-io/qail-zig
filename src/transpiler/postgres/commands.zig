const std = @import("std");

const ast = struct {
    pub const cmd = @import("../../ast/cmd.zig");
    pub const expr = @import("../../ast/expr.zig");
    pub const QailCmd = cmd.QailCmd;
};

const QailCmd = ast.QailCmd;
const render = @import("render.zig");

pub fn writeSelect(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("SELECT ");

    if (cmd.distinct) {
        try writer.writeAll("DISTINCT ");
    }

    if (cmd.columns.len == 0) {
        try writer.writeAll("*");
    } else {
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }

    if (cmd.only_table) {
        try writer.writeAll(" FROM ONLY ");
    } else {
        try writer.writeAll(" FROM ");
    }
    try writer.writeAll(cmd.table);

    if (cmd.sample_method) |method| {
        try writer.print(" TABLESAMPLE {s}(", .{method.toSql()});
        if (cmd.sample_percent) |pct| {
            try writer.print("{d}", .{pct});
        }
        try writer.writeAll(")");
        if (cmd.sample_seed) |seed| {
            try writer.print(" REPEATABLE({d})", .{seed});
        }
    }

    if (cmd.table_alias) |alias| {
        try writer.writeAll(" AS ");
        try writer.writeAll(alias);
    }

    for (cmd.joins) |join| {
        try writer.print(" {s} ", .{join.kind.toSql()});
        try writer.writeAll(join.table);
        if (join.alias) |alias| {
            try writer.writeAll(" AS ");
            try writer.writeAll(alias);
        }
        try writer.writeAll(" ON ");
        try writer.writeAll(join.on_left);
        try writer.writeAll(" = ");
        try writer.writeAll(join.on_right);
    }

    try render.writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.group_by.len > 0) {
        try writer.writeAll(" GROUP BY ");
        for (cmd.group_by, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(col);
        }
    }

    if (cmd.having_clauses.len > 0) {
        try writer.writeAll(" HAVING ");
        for (cmd.having_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try render.writeCondition(writer, &clause.condition);
        }
    }

    if (cmd.order_by.len > 0) {
        try writer.writeAll(" ORDER BY ");
        for (cmd.order_by, 0..) |order, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(order.column);
            try writer.print(" {s}", .{order.order.toSql()});
        }
    }

    if (cmd.limit_val) |limit| {
        try writer.print(" LIMIT {d}", .{limit});
    }

    if (cmd.offset_val) |offset| {
        try writer.print(" OFFSET {d}", .{offset});
    }

    if (cmd.fetch_count) |count| {
        if (cmd.fetch_with_ties) {
            try writer.print(" FETCH FIRST {d} ROWS WITH TIES", .{count});
        } else {
            try writer.print(" FETCH FIRST {d} ROWS ONLY", .{count});
        }
    }

    if (cmd.lock_mode) |lock| {
        try writer.print(" {s}", .{lock.toSql()});
    }
}

pub fn writeUpdate(writer: anytype, cmd: *const QailCmd) !void {
    if (cmd.only_table) {
        try writer.writeAll("UPDATE ONLY ");
    } else {
        try writer.writeAll("UPDATE ");
    }
    try writer.writeAll(cmd.table);
    try writer.writeAll(" SET ");

    for (cmd.assignments, 0..) |assign, i| {
        if (i > 0) try writer.writeAll(", ");
        try render.writeIdentifierOrError(writer, assign.column);
        try writer.writeAll(" = ");
        try render.writeValue(writer, &assign.value);
    }

    try render.writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

pub fn writeDelete(writer: anytype, cmd: *const QailCmd) !void {
    if (cmd.only_table) {
        try writer.writeAll("DELETE FROM ONLY ");
    } else {
        try writer.writeAll("DELETE FROM ");
    }
    try writer.writeAll(cmd.table);

    try render.writeWhereClauses(writer, cmd.where_clauses);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

pub fn writeInsert(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("INSERT INTO ");
    try writer.writeAll(cmd.table);

    if (!cmd.default_values and cmd.assignments.len > 0) {
        try writer.writeAll(" (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeIdentifierOrError(writer, assign.column);
        }
        try writer.writeAll(")");
    }

    if (cmd.overriding) |ovr| {
        try writer.print(" {s}", .{ovr.toSql()});
    }

    if (cmd.default_values) {
        try writer.writeAll(" DEFAULT VALUES");
    } else if (cmd.assignments.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeValue(writer, &assign.value);
        }
        try writer.writeAll(")");
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

pub fn writeTruncate(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("TRUNCATE ");
    try writer.writeAll(cmd.table);
}

pub fn writeMerge(writer: anytype, cmd: *const QailCmd) !void {
    const merge = cmd.merge orelse return error.MissingMergeSpec;
    try validateMergeShape(&merge);

    try writer.writeAll("MERGE INTO ");
    try writer.writeAll(cmd.table);

    if (merge.target_alias) |alias| {
        try writer.writeAll(" AS ");
        try writer.writeAll(alias);
    }

    try writer.writeAll(" USING ");
    try writeMergeSource(writer, &merge.source);

    try writer.writeAll(" ON ");
    try writeConditions(writer, merge.on);

    for (merge.clauses) |clause| {
        try writer.writeAll(" WHEN ");
        switch (clause.match_kind) {
            .matched => try writer.writeAll("MATCHED"),
            .not_matched_by_target => try writer.writeAll("NOT MATCHED BY TARGET"),
            .not_matched_by_source => try writer.writeAll("NOT MATCHED BY SOURCE"),
        }

        if (clause.condition.len > 0) {
            try writer.writeAll(" AND ");
            try writeConditions(writer, clause.condition);
        }

        try writer.writeAll(" THEN ");
        try writeMergeAction(writer, &clause.action);
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExpr(writer, &col);
        }
    }
}

fn writeMergeSource(writer: anytype, source: *const ast.cmd.MergeSource) !void {
    switch (source.*) {
        .table => |table| {
            try writer.writeAll(table.name);
            if (table.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
        .query => |query| {
            try writer.writeByte('(');
            try writeSelect(writer, query.query);
            try writer.writeByte(')');
            if (query.alias) |alias| {
                try writer.writeAll(" AS ");
                try writer.writeAll(alias);
            }
        },
    }
}

fn writeConditions(writer: anytype, conditions: []const ast.expr.Condition) !void {
    if (conditions.len == 0) return error.MissingMergeCondition;
    for (conditions, 0..) |*condition, i| {
        if (i > 0) try writer.writeAll(" AND ");
        try render.writeCondition(writer, condition);
    }
}

fn writeMergeAction(writer: anytype, action: *const ast.cmd.MergeAction) !void {
    switch (action.*) {
        .update => |assignments| {
            try writer.writeAll("UPDATE SET ");
            for (assignments, 0..) |assignment, i| {
                if (i > 0) try writer.writeAll(", ");
                try render.writeIdentifierOrError(writer, assignment.column);
                try writer.writeAll(" = ");
                var expr = assignment.expr;
                try render.writeExpr(writer, &expr);
            }
        },
        .insert => |insert| {
            try writer.writeAll("INSERT");
            if (insert.columns.len > 0) {
                try writer.writeAll(" (");
                for (insert.columns, 0..) |column, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try render.writeIdentifierOrError(writer, column);
                }
                try writer.writeByte(')');
            }
            try writer.writeAll(" VALUES (");
            for (insert.values, 0..) |value, i| {
                if (i > 0) try writer.writeAll(", ");
                var expr = value;
                try render.writeExpr(writer, &expr);
            }
            try writer.writeByte(')');
        },
        .delete => try writer.writeAll("DELETE"),
        .do_nothing => try writer.writeAll("DO NOTHING"),
    }
}

fn validateMergeShape(merge: *const ast.cmd.Merge) !void {
    if (merge.target_alias) |alias| {
        if (!isBareIdentifier(alias)) return error.InvalidMergeTargetAlias;
    }

    switch (merge.source) {
        .table => |table| {
            if (std.mem.trim(u8, table.name, " \t\r\n").len == 0) return error.MissingMergeSource;
            if (table.alias) |alias| {
                if (!isBareIdentifier(alias)) return error.InvalidMergeSourceAlias;
            }
        },
        .query => |query| {
            if (query.alias) |alias| {
                if (!isBareIdentifier(alias)) return error.InvalidMergeSourceAlias;
            }
            if (!isReadOnlyMergeSource(query.query)) return error.InvalidMergeSourceQuery;
        },
    }

    if (merge.on.len == 0) return error.MissingMergeCondition;
    if (merge.clauses.len == 0) return error.MissingMergeClause;

    for (merge.clauses) |clause| {
        switch (clause.action) {
            .insert => |insert| {
                if (clause.match_kind == .matched) return error.InvalidMergeActionShape;
                if (clause.match_kind == .not_matched_by_source) return error.InvalidMergeActionShape;
                if (insert.values.len == 0) return error.MissingMergeInsertValues;
                if (insert.columns.len > 0 and insert.columns.len != insert.values.len) return error.InvalidMergeInsertShape;
                try validateMergeWriteTargets(insert.columns);
            },
            .update => |assignments| {
                if (clause.match_kind == .not_matched_by_target) return error.InvalidMergeActionShape;
                if (assignments.len == 0) return error.MissingMergeUpdateAssignments;
                try validateMergeAssignments(assignments);
            },
            .delete => {
                if (clause.match_kind == .not_matched_by_target) return error.InvalidMergeActionShape;
            },
            .do_nothing => {},
        }
    }
}

fn validateMergeAssignments(assignments: []const ast.cmd.MergeAssignment) !void {
    for (assignments, 0..) |assignment, i| {
        if (!isBareIdentifier(assignment.column)) return error.InvalidMergeWriteTarget;
        for (assignments[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.column, assignment.column)) return error.DuplicateMergeWriteTarget;
        }
    }
}

fn validateMergeWriteTargets(columns: []const []const u8) !void {
    for (columns, 0..) |column, i| {
        if (!isBareIdentifier(column)) return error.InvalidMergeWriteTarget;
        for (columns[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev, column)) return error.DuplicateMergeWriteTarget;
        }
    }
}

fn isReadOnlyMergeSource(cmd: *const QailCmd) bool {
    switch (cmd.kind) {
        .get, .with, .cnt, .search, .over => {},
        else => return false,
    }

    for (cmd.ctes) |cte| {
        if (cte.base_query) |query| {
            if (!isReadOnlyMergeSource(query)) return false;
        }
        if (cte.recursive_query) |query| {
            if (!isReadOnlyMergeSource(query)) return false;
        }
    }
    for (cmd.set_ops) |set_op| {
        if (set_op.query) |query| {
            if (!isReadOnlyMergeSource(query)) return false;
        }
    }

    return true;
}

fn isBareIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    const first = value[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (value[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}
