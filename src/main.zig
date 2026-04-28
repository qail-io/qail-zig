// QAIL Zig Example - Pure Zig PostgreSQL Driver
//
// This demonstrates the AST-native query building approach.
// No public raw SQL input: app code builds AST commands.

const std = @import("std");
const qail = @import("qail");

const print = std.debug.print;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║  QAIL Zig Native - Pure Zig PostgreSQL Driver              ║\n", .{});
    print("║  AST-Native: no public raw SQL input                       ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});

    // ==================== Example 1: Simple SELECT ====================
    print("📦 Example 1: Simple SELECT\n", .{});
    const cols1 = [_]qail.ast.Expr{ qail.ast.Expr.col("id"), qail.ast.Expr.col("name"), qail.ast.Expr.col("email") };
    const query1 = qail.ast.QailCmd.get("users")
        .select(&cols1)
        .limit(10);

    // Show SQL representation (for debugging only)
    const sql1 = try qail.transpiler.toSql(allocator, &query1);
    defer allocator.free(sql1);
    print("   SQL (debug): {s}\n\n", .{sql1});

    // ==================== Example 2: Aggregates ====================
    print("📦 Example 2: Aggregate Query\n", .{});
    const cols2 = [_]qail.ast.Expr{
        qail.ast.Expr.count(),
        qail.ast.Expr.sum("amount"),
        qail.ast.Expr.avg("price"),
    };
    const query2 = qail.ast.QailCmd.get("orders")
        .select(&cols2)
        .distinct_();

    const sql2 = try qail.transpiler.toSql(allocator, &query2);
    defer allocator.free(sql2);
    print("   SQL (debug): {s}\n\n", .{sql2});

    // ==================== Example 3: Complex Query ====================
    print("📦 Example 3: Complex Query with JOIN\n", .{});
    const cols3 = [_]qail.ast.Expr{ qail.ast.Expr.col("u.name"), qail.ast.Expr.col("o.total") };
    const joins = [_]qail.ast.Join{.{
        .kind = .inner,
        .table = "orders",
        .alias = "o",
        .on_left = "u.id",
        .on_right = "o.user_id",
    }};
    const query3 = qail.ast.QailCmd.get("users")
        .alias("u")
        .select(&cols3)
        .join(&joins)
        .limit(5);

    const sql3 = try qail.transpiler.toSql(allocator, &query3);
    defer allocator.free(sql3);
    print("   SQL (debug): {s}\n\n", .{sql3});

    // ==================== Key Point ====================
    print("═══════════════════════════════════════════════════════════════\n", .{});
    print("💡 Note: SQL shown above is for DEBUGGING ONLY!\n", .{});
    print("   App path: AST commands → checked internal PostgreSQL frames\n", .{});
    print("   Public raw SQL command payloads are rejected.\n", .{});
    print("═══════════════════════════════════════════════════════════════\n", .{});
    print("\n✅ QAIL Zig Native is working!\n", .{});
}
