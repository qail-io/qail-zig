//! QAIL Formatter - Outputs canonical v2 QAIL syntax.
//!
//! Formats QailCmd into human-readable QAIL text format.
//! Based on qail.rs/qail-core/src/fmt/mod.rs

const std = @import("std");
const ast = @import("ast/mod.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Value = ast.Value;

/// QAIL Formatter for outputting canonical v2 syntax
pub const Formatter = struct {
    allocator: std.mem.Allocator,
    indent_level: usize,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Formatter {
        return .{
            .allocator = allocator,
            .indent_level = 0,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.buffer.deinit(self.allocator);
    }

    /// Format a QailCmd into QAIL text
    pub fn format(self: *Formatter, cmd: *const QailCmd) ![]const u8 {
        try self.visitCmd(cmd);
        return self.buffer.items;
    }

    /// Get owned formatted output
    pub fn toOwnedSlice(self: *Formatter) ![]u8 {
        return try self.buffer.toOwnedSlice(self.allocator);
    }

    fn write(self: *Formatter, s: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, s);
    }

    fn writeChar(self: *Formatter, c: u8) !void {
        try self.buffer.append(self.allocator, c);
    }

    fn indent(self: *Formatter) !void {
        for (0..self.indent_level) |_| {
            try self.write("  ");
        }
    }

    fn visitCmd(self: *Formatter, cmd: *const QailCmd) !void {
        // Action and Table
        const action_str = switch (cmd.kind) {
            .get => "get",
            .set => "set",
            .del => "del",
            .add => "add",
            .put => "put",
            .make => "make",
            .drop => "drop",
            .truncate => "truncate",
            else => "unknown",
        };
        try self.write(action_str);
        try self.writeChar(' ');
        try self.write(cmd.table);
        try self.writeChar('\n');

        // Columns (fields)
        if (cmd.columns.len > 0 and !isAllStar(cmd.columns)) {
            try self.indent();
            try self.write("fields\n");
            self.indent_level += 1;
            for (cmd.columns, 0..) |col, i| {
                try self.indent();
                try self.formatColumn(&col);
                if (i < cmd.columns.len - 1) {
                    try self.write(",\n");
                } else {
                    try self.writeChar('\n');
                }
            }
            self.indent_level -= 1;
        }

        // Joins
        for (cmd.joins) |join| {
            try self.indent();
            const join_type = switch (join.kind) {
                .inner => "join ",
                .left => "left join ",
                .right => "right join ",
                .full => "full join ",
                .cross => "cross join ",
            };
            try self.write(join_type);
            try self.write(join.table);
            try self.writeChar('\n');
        }

        // Where clauses
        if (cmd.where_clauses.len > 0) {
            try self.indent();
            try self.write("where ");
            for (cmd.where_clauses, 0..) |clause, i| {
                if (i > 0) {
                    try self.write(" and ");
                }
                try self.write(clause.condition.column);
                const op_str = switch (clause.condition.op) {
                    .eq => " = ",
                    .ne => " != ",
                    .gt => " > ",
                    .gte => " >= ",
                    .lt => " < ",
                    .lte => " <= ",
                    .like => " like ",
                    .ilike => " ilike ",
                    .is_null => " is null",
                    .is_not_null => " is not null",
                    .in => " in ",
                    .not_in => " not in ",
                    else => " ? ",
                };
                try self.write(op_str);
                if (clause.condition.op != .is_null and clause.condition.op != .is_not_null) {
                    try self.formatValue(&clause.condition.value);
                }
            }
            try self.writeChar('\n');
        }

        // Order by
        if (cmd.order_by.len > 0) {
            try self.indent();
            try self.write("order by\n");
            self.indent_level += 1;
            for (cmd.order_by, 0..) |ob, i| {
                try self.indent();
                try self.write(ob.column);
                if (ob.order == .desc or ob.order == .desc_nulls_first or ob.order == .desc_nulls_last) {
                    try self.write(" desc");
                }
                if (i < cmd.order_by.len - 1) {
                    try self.write(",\n");
                } else {
                    try self.writeChar('\n');
                }
            }
            self.indent_level -= 1;
        }

        // Limit / Offset
        if (cmd.limit_val) |n| {
            try self.indent();
            try self.write("limit ");
            try self.writeInt(n);
            try self.writeChar('\n');
        }
        if (cmd.offset_val) |n| {
            try self.indent();
            try self.write("offset ");
            try self.writeInt(n);
            try self.writeChar('\n');
        }
    }

    fn writeInt(self: *Formatter, n: i64) !void {
        var buf: [20]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
        try self.write(str);
    }

    fn formatColumn(self: *Formatter, col: *const Expr) !void {
        switch (col.*) {
            .star => try self.write("*"),
            .named => |name| try self.write(name),
            .aliased => |a| {
                try self.write(a.name);
                try self.write(" as ");
                try self.write(a.alias);
            },
            .aggregate => |agg| {
                const func_name = switch (agg.func) {
                    .count => "count",
                    .sum => "sum",
                    .avg => "avg",
                    .min => "min",
                    .max => "max",
                    .array_agg => "array_agg",
                    .string_agg => "string_agg",
                    .json_agg => "json_agg",
                    else => "func",
                };
                try self.write(func_name);
                try self.writeChar('(');
                try self.write(agg.column);
                try self.writeChar(')');
            },
            .func_call => |f| {
                try self.write(f.name);
                try self.write("(...)");
            },
            else => try self.write("/* TODO */"),
        }
    }

    fn formatValue(self: *Formatter, val: *const Value) !void {
        switch (val.*) {
            .null => try self.write("null"),
            .bool => |b| try self.write(if (b) "true" else "false"),
            .int => |n| try self.writeInt(n),
            .string => |s| {
                try self.writeChar('\'');
                try self.write(s);
                try self.writeChar('\'');
            },
            .param => |p| {
                try self.writeChar('$');
                try self.writeInt(@intCast(p));
            },
            .column => |c| try self.write(c),
            else => try self.writeChar('?'),
        }
    }
};

fn isAllStar(cols: []const Expr) bool {
    if (cols.len != 1) return false;
    return cols[0] == .star;
}

// ==================== Tests ====================

test "format simple get" {
    const allocator = std.testing.allocator;
    var formatter = Formatter.init(allocator);
    defer formatter.deinit();

    var cmd = QailCmd.get("users");
    _ = try formatter.format(&cmd);

    const output = formatter.buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "get users") != null);
}

test "format with columns" {
    const allocator = std.testing.allocator;
    var formatter = Formatter.init(allocator);
    defer formatter.deinit();

    var cmd = QailCmd.get("users");
    const cols = [_]Expr{ Expr{ .named = "id" }, Expr{ .named = "email" } };
    cmd.columns = &cols;

    _ = try formatter.format(&cmd);
    const output = formatter.buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "fields") != null);
}
