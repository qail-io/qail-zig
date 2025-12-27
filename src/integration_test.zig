//! QAIL Zig Integration Test
//!
//! Tests against a real PostgreSQL database (swb-staging)

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const PgDriver = qail.PgDriver;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig Integration Test - PostgreSQL 18                 ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Connect to swb-staging (local PostgreSQL)
    std.debug.print("🔌 Connecting to PostgreSQL (127.0.0.1:5432)...\n", .{});

    var driver = PgDriver.connect(
        allocator,
        "127.0.0.1",
        5432,
        "orion",
        "postgres",
    ) catch |err| {
        std.debug.print("❌ Connection failed: {}\n", .{err});
        std.debug.print("\n   Make sure PostgreSQL is running on port 5432\n", .{});
        std.debug.print("   with database 'swb-staging' accessible\n\n", .{});
        return;
    };
    defer driver.deinit();

    std.debug.print("✅ Connected!\n\n", .{});

    // Test 1: Simple SELECT
    std.debug.print("📦 Test 1: SELECT version()\n", .{});
    {
        const cmd = QailCmd.raw("SELECT version()");
        const rows = driver.fetchAll(&cmd) catch |err| {
            std.debug.print("   ❌ Query failed: {}\n", .{err});
            return;
        };
        defer {
            for (rows) |*row| {
                row.deinit();
            }
            allocator.free(rows);
        }

        if (rows.len > 0) {
            if (rows[0].getString(0)) |version| {
                std.debug.print("   ✅ {s}\n\n", .{version});
            }
        }
    }

    // Test 2: AST-Native SELECT
    std.debug.print("📦 Test 2: AST-Native Query\n", .{});
    {
        const cols = [_]Expr{ Expr.col("table_name"), Expr.col("table_type") };
        const cmd = QailCmd.get("information_schema.tables")
            .select(&cols)
            .limit(5);

        // Show what SQL would look like (debug only)
        const sql = try qail.transpiler.toSql(allocator, &cmd);
        defer allocator.free(sql);
        std.debug.print("   SQL (debug): {s}\n", .{sql});

        const rows = driver.fetchAll(&cmd) catch |err| {
            std.debug.print("   ❌ Query failed: {}\n", .{err});
            return;
        };
        defer {
            for (rows) |*row| {
                row.deinit();
            }
            allocator.free(rows);
        }

        std.debug.print("   ✅ Found {d} tables:\n", .{rows.len});
        for (rows) |row| {
            const name = row.getString(0) orelse "?";
            const typ = row.getString(1) orelse "?";
            std.debug.print("      - {s} ({s})\n", .{ name, typ });
        }
    }

    std.debug.print("\n✅ Integration tests passed!\n", .{});
}
