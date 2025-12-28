// Async Connection Test
//
// Test the new AsyncConnection with timeout support.

const std = @import("std");
const qail = @import("qail");

const AsyncConnection = qail.driver.AsyncConnection;
const Connection = qail.driver.Connection;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig - Async Connection Test                          ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Test 1: Connect timeout to non-existent host
    std.debug.print("📋 Test 1: Connection timeout (500ms to unreachable IP)...\n", .{});
    {
        const start = std.time.Instant.now() catch unreachable;
        const result = AsyncConnection.connect(allocator, "10.255.255.1", 5432, 500);
        const end = std.time.Instant.now() catch unreachable;
        const elapsed_ms = @as(f64, @floatFromInt(end.since(start))) / 1_000_000.0;

        if (result) |*conn| {
            var c = conn.*;
            c.close();
            std.debug.print("   ❌ FAIL: Should have timed out but connected!\n", .{});
        } else |err| {
            if (err == error.ConnectionTimeout) {
                std.debug.print("   ✅ PASS: Timed out after {d:.0}ms (expected ~500ms)\n", .{elapsed_ms});
            } else {
                std.debug.print("   ⚠️  Got error {s} after {d:.0}ms\n", .{ @errorName(err), elapsed_ms });
            }
        }
    }

    // Test 2: Successful async connection
    std.debug.print("\n📋 Test 2: Async connection to PostgreSQL (5s timeout)...\n", .{});
    {
        const start = std.time.Instant.now() catch unreachable;
        var conn = AsyncConnection.connect(allocator, "127.0.0.1", 5432, 5000) catch |err| {
            std.debug.print("   ❌ FAIL: {s}\n", .{@errorName(err)});
            return;
        };
        defer conn.close();

        const end = std.time.Instant.now() catch unreachable;
        const elapsed_ms = @as(f64, @floatFromInt(end.since(start))) / 1_000_000.0;
        std.debug.print("   ✅ Connected in {d:.2}ms\n", .{elapsed_ms});

        std.debug.print("   📡 Starting up with auth...\n", .{});
        conn.startup("orion", "postgres", null) catch |err| {
            std.debug.print("   ❌ Startup failed: {s}\n", .{@errorName(err)});
            return;
        };
        std.debug.print("   ✅ Authenticated!\n", .{});
    }

    // Test 3: Sync connection with timeout
    std.debug.print("\n📋 Test 3: Sync Connection.connectWithTimeout (5s)...\n", .{});
    {
        const start = std.time.Instant.now() catch unreachable;
        var conn = Connection.connectWithTimeout(allocator, "127.0.0.1", 5432, 5000) catch |err| {
            std.debug.print("   ❌ FAIL: {s}\n", .{@errorName(err)});
            return;
        };
        defer conn.close();

        const end = std.time.Instant.now() catch unreachable;
        const elapsed_ms = @as(f64, @floatFromInt(end.since(start))) / 1_000_000.0;
        std.debug.print("   ✅ Connected in {d:.2}ms\n", .{elapsed_ms});

        conn.startup("orion", "postgres", null) catch |err| {
            std.debug.print("   ❌ Startup failed: {s}\n", .{@errorName(err)});
            return;
        };
        std.debug.print("   ✅ Authenticated!\n", .{});
    }

    std.debug.print("\n✅ All async connection tests complete!\n", .{});
}
