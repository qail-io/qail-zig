# Quick Start

```zig
const std = @import("std");
const qail = @import("qail");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var driver = try qail.PgDriver.connect(allocator, "127.0.0.1", 5432, "postgres", "mydb");
    defer driver.deinit();

    const cmd = qail.QailCmd.get("users")
        .select(&.{ qail.Expr.col("id"), qail.Expr.col("email") })
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

- `qail.PgDriver.connect(...)`
- `qail.driver.PgPool.init(...)`
- `qail.driver.Pipeline.init(...)`
- `qail.validateAst(...)`

## Practical Direction

- Use `PgDriver` for direct command execution and AST-native reads/writes.
- Use `Pipeline` for high-throughput prepared batches.
- Use `PgPool` for concurrent prepared singles and scoped workloads.
- Validate untrusted AST input with `qail.validateAst` before execution.
