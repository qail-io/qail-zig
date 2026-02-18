// QAIL Zig — AST Build + Transpile Benchmark
//
// Measures pure CPU time, split into two phases:
//   Phase A: Build AST + Transpile (combined)
//   Phase B: Transpile Only (pre-built AST)
//
// Uses c_allocator (libc malloc/free) to match Rust's system allocator.
// Uses doNotOptimizeAway to prevent dead code elimination.
//
// No I/O, no database. Run with:
//
//   zig build ast-bench
//

const std = @import("std");
const qail = @import("qail");
const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const Value = qail.ast.Value;
const Operator = qail.ast.Operator;
const WhereClause = qail.ast.WhereClause;
const OrderBy = qail.ast.OrderBy;
const Assignment = qail.ast.Assignment;
const Join = qail.ast.Join;
const transpiler = qail.transpiler;

const ITERATIONS: u64 = 1_000_000;
const WARMUP: u64 = 10_000;

// ─────────────────────────────────────────────────────────
// Pre-built AST constants (used in Phase B — transpile only)
// Zig evaluates these at comptime, so the AST is free.
// ─────────────────────────────────────────────────────────
const T1_CMD = QailCmd.get("users");
const T2_CMD = QailCmd.get("orders")
    .select(&.{
        Expr.col("id"),
        Expr.col("total"),
        Expr.col("status"),
    })
    .where(&.{
    .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } } },
    .{ .condition = .{ .column = "total", .op = .gt, .value = .{ .int = 100 } } },
});
const T3_CMD = QailCmd.get("products")
    .select(&.{
        Expr.col("id"),
        Expr.col("name"),
        Expr.col("price"),
        Expr.col("stock"),
    })
    .where(&.{
        .{ .condition = .{ .column = "price", .op = .gte, .value = .{ .float = 9.99 } } },
        .{ .condition = .{ .column = "stock", .op = .gt, .value = .{ .int = 0 } } },
    })
    .orderBy(&.{
        .{ .column = "price", .order = .asc },
    })
    .limit(25)
    .offset(50);
const T4_CMD = QailCmd.add("events")
    .values(&.{
    .{ .column = "name", .value = .{ .string = "click" } },
    .{ .column = "user_id", .value = .{ .string = "u-123" } },
    .{ .column = "timestamp", .value = .{ .string = "2026-01-01" } },
    .{ .column = "payload", .value = .{ .string = "{}" } },
    .{ .column = "version", .value = .{ .int = 1 } },
});
const T5_CMD = QailCmd.set("users")
    .values(&.{
        .{ .column = "email", .value = .{ .string = "new@mail.com" } },
        .{ .column = "updated_at", .value = .{ .string = "2026-01-01T00:00:00Z" } },
    })
    .where(&.{
    .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .string = "abc-123" } } },
});
const T6_CMD = QailCmd.get("orders")
    .select(&.{
        Expr.col("users.name"),
        Expr{ .aggregate = .{ .column = "*", .func = .count } },
        Expr{ .aggregate = .{ .column = "orders.total", .func = .sum } },
    })
    .join(&.{
        .{ .table = "users", .on_left = "orders.user_id", .on_right = "users.id", .kind = .left },
    })
    .where(&.{
        .{ .condition = .{ .column = "orders.status", .op = .eq, .value = .{ .string = "completed" } } },
    })
    .groupBy(&.{"users.name"})
    .havingClauses(&.{
        .{ .condition = .{ .column = "count", .op = .gte, .value = .{ .int = 5 } } },
    })
    .orderBy(&.{
        .{ .column = "users.name", .order = .asc },
    })
    .limit(100);

// ─────────────────────────────────────────────────────────
// Phase A: Build + Transpile tier functions
// ─────────────────────────────────────────────────────────
fn buildAndTranspile1(alloc: std.mem.Allocator) usize {
    const cmd = QailCmd.get("users");
    const sql = transpiler.toSql(alloc, &cmd) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn buildAndTranspile2(alloc: std.mem.Allocator) usize {
    const cmd = QailCmd.get("orders")
        .select(&.{ Expr.col("id"), Expr.col("total"), Expr.col("status") })
        .where(&.{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } } },
        .{ .condition = .{ .column = "total", .op = .gt, .value = .{ .int = 100 } } },
    });
    const sql = transpiler.toSql(alloc, &cmd) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn buildAndTranspile3(alloc: std.mem.Allocator) usize {
    const cmd = QailCmd.get("products")
        .select(&.{ Expr.col("id"), Expr.col("name"), Expr.col("price"), Expr.col("stock") })
        .where(&.{
            .{ .condition = .{ .column = "price", .op = .gte, .value = .{ .float = 9.99 } } },
            .{ .condition = .{ .column = "stock", .op = .gt, .value = .{ .int = 0 } } },
        })
        .orderBy(&.{.{ .column = "price", .order = .asc }})
        .limit(25)
        .offset(50);
    const sql = transpiler.toSql(alloc, &cmd) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn buildAndTranspile4(alloc: std.mem.Allocator) usize {
    const cmd = QailCmd.add("events")
        .values(&.{
        .{ .column = "name", .value = .{ .string = "click" } },
        .{ .column = "user_id", .value = .{ .string = "u-123" } },
        .{ .column = "timestamp", .value = .{ .string = "2026-01-01" } },
        .{ .column = "payload", .value = .{ .string = "{}" } },
        .{ .column = "version", .value = .{ .int = 1 } },
    });
    const sql = transpiler.toSql(alloc, &cmd) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn buildAndTranspile5(alloc: std.mem.Allocator) usize {
    const cmd = QailCmd.set("users")
        .values(&.{
            .{ .column = "email", .value = .{ .string = "new@mail.com" } },
            .{ .column = "updated_at", .value = .{ .string = "2026-01-01T00:00:00Z" } },
        })
        .where(&.{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .string = "abc-123" } } },
    });
    const sql = transpiler.toSql(alloc, &cmd) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn buildAndTranspile6(alloc: std.mem.Allocator) usize {
    const cmd = QailCmd.get("orders")
        .select(&.{
            Expr.col("users.name"),
            Expr{ .aggregate = .{ .column = "*", .func = .count } },
            Expr{ .aggregate = .{ .column = "orders.total", .func = .sum } },
        })
        .join(&.{.{ .table = "users", .on_left = "orders.user_id", .on_right = "users.id", .kind = .left }})
        .where(&.{
            .{ .condition = .{ .column = "orders.status", .op = .eq, .value = .{ .string = "completed" } } },
        })
        .groupBy(&.{"users.name"})
        .havingClauses(&.{
            .{ .condition = .{ .column = "count", .op = .gte, .value = .{ .int = 5 } } },
        })
        .orderBy(&.{.{ .column = "users.name", .order = .asc }})
        .limit(100);
    const sql = transpiler.toSql(alloc, &cmd) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

// ─────────────────────────────────────────────────────────
// Phase B: Transpile-only tier functions (pre-built AST)
// ─────────────────────────────────────────────────────────
fn transpileOnly1(alloc: std.mem.Allocator) usize {
    const sql = transpiler.toSql(alloc, &T1_CMD) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn transpileOnly2(alloc: std.mem.Allocator) usize {
    const sql = transpiler.toSql(alloc, &T2_CMD) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn transpileOnly3(alloc: std.mem.Allocator) usize {
    const sql = transpiler.toSql(alloc, &T3_CMD) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn transpileOnly4(alloc: std.mem.Allocator) usize {
    const sql = transpiler.toSql(alloc, &T4_CMD) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn transpileOnly5(alloc: std.mem.Allocator) usize {
    const sql = transpiler.toSql(alloc, &T5_CMD) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

fn transpileOnly6(alloc: std.mem.Allocator) usize {
    const sql = transpiler.toSql(alloc, &T6_CMD) catch return 0;
    defer alloc.free(sql);
    std.mem.doNotOptimizeAway(sql.ptr);
    return sql.len;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  qail-zig (Zig) — AST Build + Transpile Benchmark    ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Iterations: {d:>10} per tier                    ║\n", .{ITERATIONS});
    std.debug.print("║  Warmup:     {d:>10}                              ║\n", .{WARMUP});
    std.debug.print("║  Mode:       ReleaseFast (optimized)                  ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var total_bytes: u64 = 0;

    // ─────────────────────────────────────────────────────
    // Phase A: Build + Transpile (combined)
    // ─────────────────────────────────────────────────────
    std.debug.print("  ── Phase A: Build AST + Transpile (combined) ──\n\n", .{});

    total_bytes += bench(allocator, "T1 — SELECT *", buildAndTranspile1);
    total_bytes += bench(allocator, "T2 — SELECT WHERE", buildAndTranspile2);
    total_bytes += bench(allocator, "T3 — ORDER/LIMIT", buildAndTranspile3);
    total_bytes += bench(allocator, "T4 — INSERT 5 cols", buildAndTranspile4);
    total_bytes += bench(allocator, "T5 — UPDATE WHERE", buildAndTranspile5);
    total_bytes += bench(allocator, "T6 — JOIN/GROUP/HAVING", buildAndTranspile6);

    // ─────────────────────────────────────────────────────
    // Phase B: Transpile Only (pre-built AST)
    // ─────────────────────────────────────────────────────
    std.debug.print("\n  ── Phase B: Transpile Only (pre-built AST) ──\n\n", .{});

    total_bytes += bench(allocator, "T1 — SELECT *", transpileOnly1);
    total_bytes += bench(allocator, "T2 — SELECT WHERE", transpileOnly2);
    total_bytes += bench(allocator, "T3 — ORDER/LIMIT", transpileOnly3);
    total_bytes += bench(allocator, "T4 — INSERT 5 cols", transpileOnly4);
    total_bytes += bench(allocator, "T5 — UPDATE WHERE", transpileOnly5);
    total_bytes += bench(allocator, "T6 — JOIN/GROUP/HAVING", transpileOnly6);

    // ─────────────────────────────────────────────────────
    // Sample SQL — prove the transpiler is actually working
    // ─────────────────────────────────────────────────────
    std.debug.print("\n────────────────────────────────────────────────────────\n", .{});
    std.debug.print("  Total SQL bytes produced: {d} (consumed to prevent DCE)\n", .{total_bytes});
    std.debug.print("\n  Sample SQL outputs:\n", .{});

    {
        const sql = try transpiler.toSql(allocator, &T1_CMD);
        defer allocator.free(sql);
        std.debug.print("    T1: {s}\n", .{sql});
    }
    {
        const sql = try transpiler.toSql(allocator, &T6_CMD);
        defer allocator.free(sql);
        std.debug.print("    T6: {s}\n", .{sql});
    }
    std.debug.print("\n", .{});
}

/// Benchmark harness — takes a regular function pointer (not comptime).
fn bench(
    allocator: std.mem.Allocator,
    label: []const u8,
    run_fn: *const fn (std.mem.Allocator) usize,
) u64 {
    // Warmup
    var sink: u64 = 0;
    for (0..WARMUP) |_| {
        sink +%= run_fn(allocator);
    }
    std.mem.doNotOptimizeAway(&sink);

    // Timed run
    const start = std.time.Instant.now() catch unreachable;
    for (0..ITERATIONS) |_| {
        sink +%= run_fn(allocator);
    }
    std.mem.doNotOptimizeAway(&sink);
    const end = std.time.Instant.now() catch unreachable;
    const elapsed_ns = end.since(start);
    const ns_per = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
    const ops_per_sec = @as(f64, @floatFromInt(ITERATIONS)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("  {s:<22} {d:>7.0} ns/op  {d:>12.0} ops/s\n", .{ label, ns_per, ops_per_sec });

    return sink;
}
