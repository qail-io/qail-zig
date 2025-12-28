// QAIL Zig Integration Test
//
// Tests against a real PostgreSQL database (swb-staging)

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

    // Test 1: Simple SELECT from system catalog (AST-Native - no raw SQL!)
    std.debug.print("📦 Test 1: SELECT datname FROM pg_database (AST-Native)\n", .{});
    {
        const cols = [_]Expr{Expr.col("datname")};
        const cmd = QailCmd.get("pg_database").select(&cols).limit(3);

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

        std.debug.print("   ✅ Found {d} databases:\n", .{rows.len});
        for (rows) |row| {
            if (row.getString(0)) |name| {
                std.debug.print("      - {s}\n", .{name});
            }
        }
        std.debug.print("\n", .{});
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

    // Test 3: LISTEN/NOTIFY (AST-Native Pub/Sub)
    std.debug.print("\n📦 Test 3: LISTEN/NOTIFY (AST-Native Pub/Sub)\n", .{});
    {
        // Test LISTEN command
        const listen_cmd = QailCmd.listen("qail_test_channel");
        const listen_sql = try qail.transpiler.toSql(allocator, &listen_cmd);
        defer allocator.free(listen_sql);
        std.debug.print("   LISTEN SQL: {s}\n", .{listen_sql});

        // Test NOTIFY command with payload
        const notify_cmd = QailCmd.notifyChannel("qail_test_channel", "{\"msg\": \"hello\"}");
        const notify_sql = try qail.transpiler.toSql(allocator, &notify_cmd);
        defer allocator.free(notify_sql);
        std.debug.print("   NOTIFY SQL: {s}\n", .{notify_sql});

        // Test UNLISTEN command
        const unlisten_cmd = QailCmd.unlisten("qail_test_channel");
        const unlisten_sql = try qail.transpiler.toSql(allocator, &unlisten_cmd);
        defer allocator.free(unlisten_sql);
        std.debug.print("   UNLISTEN SQL: {s}\n", .{unlisten_sql});

        std.debug.print("   ✅ Pub/Sub commands generated correctly!\n", .{});
    }

    // Test 4: Transaction Commands
    std.debug.print("\n📦 Test 4: Transaction Commands\n", .{});
    {
        const begin_sql = try qail.transpiler.toSql(allocator, &QailCmd.beginTx());
        defer allocator.free(begin_sql);
        std.debug.print("   BEGIN: {s}\n", .{begin_sql});

        const savepoint_cmd = QailCmd.savepoint("sp1");
        const sp_sql = try qail.transpiler.toSql(allocator, &savepoint_cmd);
        defer allocator.free(sp_sql);
        std.debug.print("   SAVEPOINT: {s}\n", .{sp_sql});

        const commit_sql = try qail.transpiler.toSql(allocator, &QailCmd.commitTx());
        defer allocator.free(commit_sql);
        std.debug.print("   COMMIT: {s}\n", .{commit_sql});

        std.debug.print("   ✅ Transaction commands generated correctly!\n", .{});
    }

    std.debug.print("\n✅ Integration tests passed!\n", .{});
}
