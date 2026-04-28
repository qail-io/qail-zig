// Error Test - Verify public AST execution parses PostgreSQL errors.
// Run: zig build error-test

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const PgDriver = qail.driver.driver.PgDriver;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Testing error detection with an AST divide-by-zero query...\n", .{});

    var driver = try PgDriver.connect(allocator, "127.0.0.1", 5432, "orion", "postgres");
    defer driver.deinit();

    const one = Expr.int(1);
    const zero = Expr.int(0);
    const div_expr: Expr = .{
        .binary = .{
            .left = &one,
            .op = .div,
            .right = &zero,
            .alias = null,
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{div_expr})
        .limit(1);

    if (driver.fetchAll(&cmd)) |rows| {
        for (rows) |*row| row.deinit();
        allocator.free(rows);
        std.debug.print("NO ERROR: divide-by-zero query unexpectedly succeeded\n", .{});
        return error.ExpectedQueryError;
    } else |err| switch (err) {
        error.QueryError => {
            std.debug.print("ERROR DETECTED: public AST path parsed PostgreSQL error response\n", .{});
        },
        else => return err,
    }
}
