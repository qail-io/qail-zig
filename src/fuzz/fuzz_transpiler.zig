//! Fuzz test: Transpiler toSql
//!
//! Goal: toSql() must NEVER panic on any structured QailCmd.
//! We construct realistic query shapes from fuzz bytes, exercising
//! the SQL injection attack surface.
//!
//! Port of qail.rs/pg/fuzz/fuzz_targets/ast_encode.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const transpiler = @import("../transpiler/mod.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;

/// Split fuzz bytes into up to N null-terminated strings
fn splitStrings(data: []const u8, comptime max: usize) [max][]const u8 {
    var result: [max][]const u8 = .{""} ** max;
    var i: usize = 0;
    var start: usize = 0;

    for (data, 0..) |byte, pos| {
        if (byte == 0 and i < max) {
            result[i] = data[start..pos];
            i += 1;
            start = pos + 1;
        }
    }
    // Capture remaining
    if (i < max and start < data.len) {
        result[i] = data[start..];
    }
    return result;
}

fn fuzzTranspilerInput(input: []const u8) anyerror!void {
    if (input.len < 2) return;

    const parts = splitStrings(input, 4);
    const table = parts[0];
    const col1 = if (parts[1].len > 0) parts[1] else "id";
    const val = if (parts[2].len > 0) parts[2] else "test";
    const col2 = if (parts[3].len > 0) parts[3] else "name";

    // Skip empty table names
    if (table.len == 0) return;

    const allocator = std.testing.allocator;

    // 1) SELECT with columns
    {
        const cols = [_]Expr{ Expr.col(col1), Expr.col(col2) };
        const wheres = [_]ast.WhereClause{
            .{ .condition = .{ .column = col1, .op = .eq, .value = .{ .string = val } } },
        };
        const cmd = QailCmd.get(table).select(&cols).where(&wheres);
        const sql = transpiler.toSql(allocator, &cmd) catch return;
        allocator.free(sql);
    }

    // 2) INSERT with values
    {
        const assigns = [_]ast.Assignment{
            .{ .column = col1, .value = .{ .string = val } },
            .{ .column = col2, .value = .{ .string = val } },
        };
        const cmd = QailCmd.add(table).values(&assigns);
        const sql = transpiler.toSql(allocator, &cmd) catch return;
        allocator.free(sql);
    }

    // 3) UPDATE with filter
    {
        const assigns = [_]ast.Assignment{
            .{ .column = col1, .value = .{ .string = val } },
        };
        const wheres = [_]ast.WhereClause{
            .{ .condition = .{ .column = col1, .op = .eq, .value = .{ .string = val } } },
        };
        const cmd = QailCmd.set(table).values(&assigns).where(&wheres);
        const sql = transpiler.toSql(allocator, &cmd) catch return;
        allocator.free(sql);
    }

    // 4) DELETE with filter
    {
        const wheres = [_]ast.WhereClause{
            .{ .condition = .{ .column = col1, .op = .eq, .value = .{ .string = val } } },
        };
        const cmd = QailCmd.del(table).where(&wheres);
        const sql = transpiler.toSql(allocator, &cmd) catch return;
        allocator.free(sql);
    }
}

fn fuzzTranspiler(_: @TypeOf(.{}), smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n: usize = @intCast(smith.slice(&buf));
    try fuzzTranspilerInput(buf[0..n]);
}

test "fuzz: transpiler toSql never panics on structured queries" {
    try std.testing.fuzz(.{}, fuzzTranspiler, .{});
}
