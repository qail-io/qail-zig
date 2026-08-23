const std = @import("std");

const ast = struct {
    pub const cmd = @import("../../ast/cmd.zig");
    pub const expr = @import("../../ast/expr.zig");
    pub const QailCmd = cmd.QailCmd;
};

const QailCmd = ast.QailCmd;
const render = @import("render.zig");

pub fn writeSelect(writer: anytype, cmd: *const QailCmd) !void {
    try validateSelectShape(cmd);

    try writer.writeAll("SELECT ");

    if (cmd.distinct) {
        try writer.writeAll("DISTINCT ");
    }

    if (cmd.columns.len == 0) {
        try writer.writeAll("*");
    } else {
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExprWithContext(writer, &col, cmd);
        }
    }

    if (cmd.only_table) {
        try writer.writeAll(" FROM ONLY ");
    } else {
        try writer.writeAll(" FROM ");
    }
    try render.writeTableReferenceOrError(writer, cmd.table);

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
        try render.writeIdentifierOrError(writer, alias);
    }

    for (cmd.joins) |join| {
        try writer.print(" {s} ", .{join.kind.toSql()});
        try render.writeTableReferenceOrError(writer, join.table);
        if (join.alias) |alias| {
            try writer.writeAll(" AS ");
            try render.writeIdentifierOrError(writer, alias);
        }
        try writer.writeAll(" ON ");
        try render.writeColumnReference(writer, join.on_left, cmd);
        try writer.writeAll(" = ");
        try render.writeColumnReference(writer, join.on_right, cmd);
    }

    try render.writeWhereClausesWithContext(writer, cmd.where_clauses, cmd);

    if (cmd.group_by.len > 0) {
        try writer.writeAll(" GROUP BY ");
        for (cmd.group_by, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeColumnReference(writer, col, cmd);
        }
    }

    if (cmd.having_clauses.len > 0) {
        try writer.writeAll(" HAVING ");
        for (cmd.having_clauses, 0..) |clause, i| {
            if (i > 0) {
                try writer.print(" {s} ", .{clause.logical_op.toSql()});
            }
            try render.writeConditionWithContext(writer, &clause.condition, cmd);
        }
    }

    if (cmd.order_by.len > 0) {
        try writer.writeAll(" ORDER BY ");
        for (cmd.order_by, 0..) |order, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeColumnReference(writer, order.column, cmd);
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
        if (cmd.skip_locked) try writer.writeAll(" SKIP LOCKED");
    }
}

pub fn writeUpdate(writer: anytype, cmd: *const QailCmd) !void {
    try validateUpdateShape(cmd);

    if (cmd.only_table) {
        try writer.writeAll("UPDATE ONLY ");
    } else {
        try writer.writeAll("UPDATE ");
    }
    try render.writeTableReferenceOrError(writer, cmd.table);
    if (cmd.table_alias) |alias| {
        try writer.writeAll(" AS ");
        try render.writeIdentifierOrError(writer, alias);
    }
    try writer.writeAll(" SET ");

    for (cmd.assignments, 0..) |assign, i| {
        if (i > 0) try writer.writeAll(", ");
        try render.writeIdentifierOrError(writer, assign.column);
        try writer.writeAll(" = ");
        try render.writeValueWithContext(writer, &assign.value, cmd);
    }

    if (cmd.from_tables.len > 0) {
        try writer.writeAll(" FROM ");
        for (cmd.from_tables, 0..) |table, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeTableReferenceOrError(writer, table);
        }
    }

    try render.writeWhereClausesWithContext(writer, cmd.where_clauses, cmd);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExprWithContext(writer, &col, cmd);
        }
    }
}

pub fn writeDelete(writer: anytype, cmd: *const QailCmd) !void {
    if (cmd.only_table) {
        try writer.writeAll("DELETE FROM ONLY ");
    } else {
        try writer.writeAll("DELETE FROM ");
    }
    try render.writeTableReferenceOrError(writer, cmd.table);
    if (cmd.table_alias) |alias| {
        try writer.writeAll(" AS ");
        try render.writeIdentifierOrError(writer, alias);
    }

    if (cmd.using_tables.len > 0) {
        try writer.writeAll(" USING ");
        for (cmd.using_tables, 0..) |table, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeTableReferenceOrError(writer, table);
        }
    }

    try render.writeWhereClausesWithContext(writer, cmd.where_clauses, cmd);

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExprWithContext(writer, &col, cmd);
        }
    }
}

pub fn writeInsert(writer: anytype, cmd: *const QailCmd, include_conflict: bool) !void {
    try validateInsertShape(cmd);

    try writer.writeAll("INSERT INTO ");
    try render.writeIdentifierOrError(writer, cmd.table);

    if (!cmd.default_values and cmd.columns.len > 0) {
        try writer.writeAll(" (");
        for (cmd.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try writeInsertTargetColumn(writer, &col);
        }
        try writer.writeAll(")");
    } else if (!cmd.default_values and cmd.columns.len == 0 and cmd.assignments.len > 0) {
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
    } else if (cmd.source_query) |source_query| {
        try writer.writeByte(' ');
        try writeNestedQueryableCmd(writer, source_query);
    } else if (cmd.raw_sql) |source_sql| {
        try writer.writeByte(' ');
        const checked_source = render.checkedReadOnlySubquerySql(source_sql) orelse return error.InvalidReadOnlySubquery;
        try writer.writeAll(checked_source);
    } else if (cmd.insert_values.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.insert_values, 0..) |value, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeValueWithContext(writer, &value, cmd);
        }
        try writer.writeAll(")");
    } else if (cmd.assignments.len > 0) {
        try writer.writeAll(" VALUES (");
        for (cmd.assignments, 0..) |assign, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeValueWithContext(writer, &assign.value, cmd);
        }
        try writer.writeAll(")");
    } else {
        return error.MissingInsertValues;
    }

    if (include_conflict or cmd.on_conflict != null) {
        if (cmd.on_conflict) |conflict| {
            try writer.writeAll(" ON CONFLICT");
            if (conflict.columns.len > 0) {
                try writer.writeAll(" (");
                for (conflict.columns, 0..) |col, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try render.writeIdentifierOrError(writer, col);
                }
                try writer.writeAll(")");
            }

            switch (conflict.action) {
                .do_nothing => try writer.writeAll(" DO NOTHING"),
                .do_update => {
                    const updates = if (conflict.update_columns.len != 0) conflict.update_columns else cmd.assignments;
                    try writer.writeAll(" DO UPDATE SET ");
                    for (updates, 0..) |assign, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try render.writeIdentifierOrError(writer, assign.column);
                        try writer.writeAll(" = ");
                        if (conflict.update_columns.len != 0) {
                            try render.writeValueWithContext(writer, &assign.value, cmd);
                        } else {
                            try writer.writeAll("EXCLUDED.");
                            try render.writeIdentifierOrError(writer, assign.column);
                        }
                    }
                    if (conflict.where_conditions.len > 0) {
                        try writer.writeAll(" WHERE ");
                        for (conflict.where_conditions, 0..) |*condition, i| {
                            if (i > 0) try writer.writeAll(" AND ");
                            try render.writeConditionWithContext(writer, condition, cmd);
                        }
                    }
                },
            }
        } else {
            try writer.writeAll(" ON CONFLICT DO NOTHING");
        }
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExprWithContext(writer, &col, cmd);
        }
    }
}

fn writeNestedQueryableCmd(writer: anytype, cmd: *const QailCmd) anyerror!void {
    return switch (cmd.kind) {
        .get, .with, .search, .over => writeSelect(writer, cmd),
        else => error.UnsupportedNestedQueryCommand,
    };
}

fn writeInsertTargetColumn(writer: anytype, column: *const ast.expr.Expr) !void {
    switch (column.*) {
        .named => |name| try render.writeIdentifierOrError(writer, name),
        else => return error.InvalidInsertColumn,
    }
}

fn validateSelectShape(cmd: *const QailCmd) !void {
    if (cmd.assignments.len != 0) return error.InvalidSelectShape;
    if (cmd.fetch_with_ties and cmd.order_by.len == 0) return error.FetchWithTiesRequiresOrderBy;
    if (cmd.skip_locked and cmd.lock_mode == null) return error.SkipLockedRequiresLockMode;

    if (cmd.sample_method != null and cmd.sample_percent == null) return error.MissingTableSamplePercent;
    if (cmd.sample_percent) |pct| {
        if (!std.math.isFinite(pct) or pct < 0 or pct > 100) return error.InvalidTableSamplePercent;
        if (cmd.sample_method == null) return error.MissingTableSampleMethod;
    }
}

fn validateInsertShape(cmd: *const QailCmd) !void {
    const has_values = cmd.insert_values.len != 0;
    const has_assignments = cmd.assignments.len != 0;
    const has_source = cmd.source_query != null;
    const has_raw_source = cmd.raw_sql != null;

    if (cmd.default_values) {
        if (cmd.columns.len != 0 or has_values or has_assignments or has_source or has_raw_source) {
            return error.InvalidInsertShape;
        }
        try validateOnConflictShape(cmd);
        return;
    }

    if (has_source and (has_raw_source or has_values or has_assignments)) return error.InvalidInsertShape;
    if (has_raw_source and (has_values or has_assignments)) return error.InvalidInsertShape;
    if (has_values and has_assignments) return error.InvalidInsertShape;
    if (!has_source and !has_raw_source and !has_values and !has_assignments) return error.MissingInsertValues;

    if (cmd.columns.len != 0) {
        try validateInsertTargetColumns(cmd.columns);
        const value_count = if (has_values) cmd.insert_values.len else if (has_assignments) cmd.assignments.len else 0;
        if (value_count != 0 and cmd.columns.len != value_count) return error.InvalidInsertShape;
    } else if (has_assignments) {
        try validateAssignmentTargets(cmd.assignments);
    }

    try validateOnConflictShape(cmd);
}

fn validateUpdateShape(cmd: *const QailCmd) !void {
    if (cmd.assignments.len == 0) return error.MissingUpdateAssignments;
    if (cmd.columns.len != 0) return error.InvalidUpdateShape;
    try validateAssignmentTargets(cmd.assignments);
}

fn validateOnConflictShape(cmd: *const QailCmd) !void {
    const conflict = cmd.on_conflict orelse return;

    try validateWriteTargetNames(conflict.columns);
    switch (conflict.action) {
        .do_nothing => {},
        .do_update => {
            if (conflict.columns.len == 0) return error.InvalidOnConflictShape;
            const updates = if (conflict.update_columns.len != 0) conflict.update_columns else cmd.assignments;
            if (updates.len == 0) return error.InvalidOnConflictShape;
            try validateAssignmentTargets(updates);
        },
    }
}

fn validateInsertTargetColumns(columns: []const ast.expr.Expr) !void {
    for (columns, 0..) |column, i| {
        const name = switch (column) {
            .named => |name| name,
            else => return error.InvalidInsertColumn,
        };
        if (!isBareIdentifier(name)) return error.InvalidInsertColumn;

        for (columns[0..i]) |prev| {
            const prev_name = switch (prev) {
                .named => |p| p,
                else => continue,
            };
            if (std.ascii.eqlIgnoreCase(prev_name, name)) return error.DuplicateWriteTarget;
        }
    }
}

fn validateAssignmentTargets(assignments: []const ast.cmd.Assignment) !void {
    for (assignments, 0..) |assignment, i| {
        if (!isBareIdentifier(assignment.column)) return error.InvalidWriteTarget;
        for (assignments[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.column, assignment.column)) return error.DuplicateWriteTarget;
        }
    }
}

fn validateWriteTargetNames(columns: []const []const u8) !void {
    for (columns, 0..) |column, i| {
        if (!isBareIdentifier(column)) return error.InvalidWriteTarget;
        for (columns[0..i]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev, column)) return error.DuplicateWriteTarget;
        }
    }
}

pub fn writeTruncate(writer: anytype, cmd: *const QailCmd) !void {
    try writer.writeAll("TRUNCATE ");
    try render.writeIdentifierOrError(writer, cmd.table);
}

pub fn writeMerge(writer: anytype, cmd: *const QailCmd) !void {
    const merge = cmd.merge orelse return error.MissingMergeSpec;
    try validateMergeShape(&merge);

    try writer.writeAll("MERGE INTO ");
    try render.writeTableReferenceOrError(writer, cmd.table);

    if (merge.target_alias) |alias| {
        try writer.writeAll(" AS ");
        try render.writeIdentifierOrError(writer, alias);
    }

    try writer.writeAll(" USING ");
    try writeMergeSource(writer, &merge.source);

    try writer.writeAll(" ON ");
    try writeConditions(writer, merge.on, cmd);

    for (merge.clauses) |clause| {
        try writer.writeAll(" WHEN ");
        switch (clause.match_kind) {
            .matched => try writer.writeAll("MATCHED"),
            .not_matched_by_target => try writer.writeAll("NOT MATCHED BY TARGET"),
            .not_matched_by_source => try writer.writeAll("NOT MATCHED BY SOURCE"),
        }

        if (clause.condition.len > 0) {
            try writer.writeAll(" AND ");
            try writeConditions(writer, clause.condition, cmd);
        }

        try writer.writeAll(" THEN ");
        try writeMergeAction(writer, &clause.action, cmd);
    }

    if (cmd.returning.len > 0) {
        try writer.writeAll(" RETURNING ");
        for (cmd.returning, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try render.writeExprWithContext(writer, &col, cmd);
        }
    }
}

fn writeMergeSource(writer: anytype, source: *const ast.cmd.MergeSource) !void {
    switch (source.*) {
        .table => |table| {
            try render.writeTableReferenceOrError(writer, table.name);
            if (table.alias) |alias| {
                try writer.writeAll(" AS ");
                try render.writeIdentifierOrError(writer, alias);
            }
        },
        .query => |query| {
            try writer.writeByte('(');
            try writeSelect(writer, query.query);
            try writer.writeByte(')');
            if (query.alias) |alias| {
                try writer.writeAll(" AS ");
                try render.writeIdentifierOrError(writer, alias);
            }
        },
    }
}

fn writeConditions(writer: anytype, conditions: []const ast.expr.Condition, cmd: ?*const QailCmd) !void {
    if (conditions.len == 0) return error.MissingMergeCondition;
    for (conditions, 0..) |*condition, i| {
        if (i > 0) try writer.writeAll(" AND ");
        try render.writeConditionWithContext(writer, condition, cmd);
    }
}

fn writeMergeAction(writer: anytype, action: *const ast.cmd.MergeAction, cmd: ?*const QailCmd) !void {
    switch (action.*) {
        .update => |assignments| {
            try writer.writeAll("UPDATE SET ");
            for (assignments, 0..) |assignment, i| {
                if (i > 0) try writer.writeAll(", ");
                try render.writeIdentifierOrError(writer, assignment.column);
                try writer.writeAll(" = ");
                var expr = assignment.expr;
                try render.writeExprWithContext(writer, &expr, cmd);
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
                try render.writeExprWithContext(writer, &expr, cmd);
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
        .get, .with => {},
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
