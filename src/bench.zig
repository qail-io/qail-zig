//! QAIL Zig Native Benchmark
//!
//! Benchmarks AST → Wire Protocol encoding throughput

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const AstEncoder = qail.protocol.AstEncoder;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig Native Benchmark - AST → Wire Encoding           ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Warmup
    std.debug.print("🔥 Warming up...\n", .{});
    _ = try benchmarkEncoding(allocator, 10_000);

    // Benchmark runs
    std.debug.print("\n📊 Running benchmarks...\n\n", .{});

    const runs = [_]u64{ 100_000, 1_000_000, 10_000_000, 50_000_000 };

    for (runs) |count| {
        const result = try benchmarkEncoding(allocator, count);
        printResult(count, result);
    }

    std.debug.print("\n✅ Benchmark complete!\n", .{});
}

fn benchmarkEncoding(allocator: std.mem.Allocator, iterations: u64) !u64 {
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();

    // Build a representative query
    const cols = [_]Expr{ Expr.col("id"), Expr.col("name"), Expr.col("email") };

    const start = std.time.Instant.now() catch unreachable;

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const cmd = QailCmd.get("users").select(&cols).limit(10);
        try encoder.encodeQuery(&cmd);
    }

    const end = std.time.Instant.now() catch unreachable;
    return end.since(start);
}

fn printResult(iterations: u64, nanos: u64) void {
    const ms = @as(f64, @floatFromInt(nanos)) / 1_000_000.0;
    const per_op_ns = @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(iterations));
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(nanos)) / 1_000_000_000.0);

    if (iterations >= 1_000_000) {
        std.debug.print("  {d:>3}M iterations: {d:>8.2} ms  ({d:>6.1} ns/op, {d:>8.2}M ops/sec)\n", .{
            iterations / 1_000_000,
            ms,
            per_op_ns,
            ops_per_sec / 1_000_000.0,
        });
    } else {
        std.debug.print("  {d:>3}K iterations: {d:>8.2} ms  ({d:>6.1} ns/op, {d:>8.2}M ops/sec)\n", .{
            iterations / 1_000,
            ms,
            per_op_ns,
            ops_per_sec / 1_000_000.0,
        });
    }
}
