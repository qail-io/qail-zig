# Quick Start

```zig
const std = @import("std");
const qail = @import("qail");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var driver = try qail.driver.driver.PgDriver.connect(allocator, "127.0.0.1", 5432, "postgres", "mydb");
    defer driver.deinit();

    const cmd = qail.ast.QailCmd.get("users")
        .select(&.{ qail.ast.Expr.col("id"), qail.ast.Expr.col("email") })
        .where(&.{.{ .condition = .{ .column = "active", .op = .eq, .value = .{ .bool = true } } }})
        .limit(10);

    const rows = try driver.fetchAll(&cmd);
    defer {
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }
}
```

## High-Level Entry Points

- `qail.driver.driver.PgDriver.connect(...)`
- `qail.driver.driver.PgDriver.connectUrl(...)`
- `qail.driver.pool.PgPool.init(...)`
- `qail.driver.pipeline.Pipeline.init(...)`
- `qail.validateAst(...)`

## Practical Direction

- Use `PgDriver` for direct command execution and AST-native reads/writes.
- Use `Pipeline` for high-throughput prepared batches.
- Use `PgPool` for concurrent prepared singles and scoped workloads.
- Validate untrusted AST input with `qail.validateAst` before execution.
