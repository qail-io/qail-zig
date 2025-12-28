// QAIL Zig Integration Test - PostgreSQL 18 (Zig 0.16 API)

const std = @import("std");
const qail = @import("qail");

const Io = std.Io;
const Threaded = Io.Threaded;
const PgDriver = qail.PgDriver;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig Integration Test - PostgreSQL 18 (Zig 0.16)      ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create Io instance (Zig 0.16 pattern)
    var threaded = Threaded.init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Connect to PostgreSQL
    std.debug.print("🔌 Connecting to PostgreSQL (127.0.0.1:5432)...\n", .{});

    var driver = PgDriver.connect(
        allocator,
        io,
        "127.0.0.1",
        5432,
        "orion",
        "postgres",
    ) catch |err| {
        std.debug.print("❌ Connection failed: {}\n", .{err});
        std.debug.print("\n   Make sure PostgreSQL is running on port 5432\n", .{});
        return;
    };
    defer driver.deinit();

    std.debug.print("✅ Connected!\n\n", .{});

    // Test 1: Simple SELECT from system catalog (AST-Native - no raw SQL!)
    std.debug.print("📋 Test 1: SELECT from pg_database...\n", .{});

    const cols1 = [_]qail.Expr{
        qail.Expr.col("datname"),
        qail.Expr.col("oid"),
    };
    const cmd1 = qail.QailCmd.get("pg_database").select(&cols1).limit(5);

    const rows1 = driver.fetchAll(&cmd1) catch |err| {
        std.debug.print("   ❌ Query failed: {}\n", .{err});
        return;
    };

    std.debug.print("   ✅ Returned {} rows:\n", .{rows1.len});
    for (rows1) |row| {
        const name = row.getString(0) orelse "(null)";
        std.debug.print("       - {s}\n", .{name});
    }
    for (rows1) |*row| row.deinit();
    allocator.free(rows1);

    std.debug.print("\n", .{});

    std.debug.print("\n✅ All integration tests passed!\n", .{});
}
