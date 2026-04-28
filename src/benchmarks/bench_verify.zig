// Verification Benchmark - Audits public Pipeline completion counts.
// Run: zig build verify

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const WhereClause = qail.ast.cmd.WhereClause;
const Connection = qail.driver.connection.Connection;
const Pipeline = qail.driver.pipeline.Pipeline;

const QUERIES_PER_BATCH: usize = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("Verifying public Pipeline completion counts...\n", .{});

    var conn = try Connection.connect(allocator, "127.0.0.1", 5432);
    defer conn.close();
    try conn.startup("orion", "postgres", null);

    var pipeline = Pipeline.init(&conn, allocator);
    defer pipeline.deinit();

    const where = [_]WhereClause{.{
        .condition = .{
            .column = "id",
            .op = .lte,
            .value = .{ .param = 1 },
        },
    }};
    const cmd = QailCmd.get("harbors")
        .select(&.{ Expr.col("id"), Expr.col("name") })
        .where(&where);
    var stmt = try pipeline.prepare(&cmd);
    defer stmt.deinit();

    var total_commands: usize = 0;
    const text_params = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

    for (0..10) |batch| {
        var param_values: [QUERIES_PER_BATCH][1]?[]const u8 = undefined;
        var param_rows: [QUERIES_PER_BATCH][]const ?[]const u8 = undefined;
        for (0..QUERIES_PER_BATCH) |i| {
            param_values[i][0] = text_params[i % text_params.len];
            param_rows[i] = param_values[i][0..];
        }

        const completed = try pipeline.pipelinePreparedFast(&stmt, param_rows[0..]);
        std.debug.print("Batch {}: {} commands completed\n", .{ batch, completed });
        total_commands += completed;
    }

    std.debug.print("\nVerification Results (10 batches):\n", .{});
    std.debug.print("  Total Commands: {} (Expected: 1000)\n", .{total_commands});

    if (total_commands != 1000) {
        std.debug.print("FAILED: Did not receive all query responses\n", .{});
        return error.MissingQueryResponses;
    }

    std.debug.print("PASSED: Received full public Pipeline response counts\n", .{});
}
