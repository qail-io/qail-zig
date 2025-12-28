//! Pure Zig Metrics for PostgreSQL Driver
//!
//! Zero-dependency observability with thread-safe atomic counters,
//! latency histogram, and Prometheus export.

const std = @import("std");

/// Latency bucket boundaries in nanoseconds
const BUCKET_BOUNDS_NS = [_]u64{
    1_000_000, // <1ms
    5_000_000, // <5ms
    10_000_000, // <10ms
    50_000_000, // <50ms
    100_000_000, // <100ms
    500_000_000, // <500ms
    1_000_000_000, // <1s
    std.math.maxInt(u64), // >1s
};

/// Pool metrics with thread-safe atomic counters.
pub const PoolMetrics = struct {
    // === Query Counters ===
    queries_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queries_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rows_returned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // === Connection Counters ===
    connections_created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connections_closed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // === Latency Histogram (8 buckets) ===
    latency_buckets: [8]std.atomic.Value(u64) = .{
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
        std.atomic.Value(u64).init(0),
    },
    latency_sum_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // === Pool State ===
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    idle: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    waiting: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Create a new metrics instance (all zeros)
    pub fn init() PoolMetrics {
        return .{};
    }

    /// Record a completed query
    pub fn recordQuery(self: *PoolMetrics, duration_ns: u64, rows: u64, success: bool) void {
        _ = self.queries_total.fetchAdd(1, .monotonic);
        if (!success) {
            _ = self.queries_failed.fetchAdd(1, .monotonic);
        }
        _ = self.rows_returned.fetchAdd(rows, .monotonic);
        _ = self.latency_sum_ns.fetchAdd(duration_ns, .monotonic);

        // Find bucket
        inline for (BUCKET_BOUNDS_NS, 0..) |bound, i| {
            if (duration_ns < bound) {
                _ = self.latency_buckets[i].fetchAdd(1, .monotonic);
                return;
            }
        }
    }

    /// Record connection created
    pub fn recordConnectionCreated(self: *PoolMetrics) void {
        _ = self.connections_created.fetchAdd(1, .monotonic);
    }

    /// Record connection closed
    pub fn recordConnectionClosed(self: *PoolMetrics) void {
        _ = self.connections_closed.fetchAdd(1, .monotonic);
    }

    /// Update pool state
    pub fn updatePoolState(self: *PoolMetrics, active_count: u32, idle_count: u32) void {
        self.active.store(active_count, .monotonic);
        self.idle.store(idle_count, .monotonic);
    }

    /// Increment waiting count
    pub fn incWaiting(self: *PoolMetrics) void {
        _ = self.waiting.fetchAdd(1, .monotonic);
    }

    /// Decrement waiting count
    pub fn decWaiting(self: *PoolMetrics) void {
        _ = self.waiting.fetchSub(1, .monotonic);
    }

    /// Calculate approximate percentile (p50, p95, p99)
    /// Returns latency in nanoseconds
    pub fn percentile(self: *const PoolMetrics, p: f64) u64 {
        const total = self.queries_total.load(.monotonic);
        if (total == 0) return 0;

        const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total)) * p));
        var cumulative: u64 = 0;

        for (BUCKET_BOUNDS_NS, 0..) |bound, i| {
            cumulative += self.latency_buckets[i].load(.monotonic);
            if (cumulative >= target) {
                return bound;
            }
        }
        return BUCKET_BOUNDS_NS[7];
    }

    /// Get average latency in nanoseconds
    pub fn avgLatencyNs(self: *const PoolMetrics) u64 {
        const total = self.queries_total.load(.monotonic);
        if (total == 0) return 0;
        return self.latency_sum_ns.load(.monotonic) / total;
    }

    /// Get queries per second (requires external timing)
    pub fn queriesPerSecond(self: *const PoolMetrics, elapsed_seconds: f64) f64 {
        if (elapsed_seconds <= 0) return 0;
        return @as(f64, @floatFromInt(self.queries_total.load(.monotonic))) / elapsed_seconds;
    }

    /// Export metrics in Prometheus text format
    pub fn toPrometheus(self: *const PoolMetrics, writer: anytype) !void {
        // Counters
        try writer.print("# TYPE qail_queries_total counter\nqail_queries_total {d}\n", .{self.queries_total.load(.monotonic)});
        try writer.print("# TYPE qail_queries_failed counter\nqail_queries_failed {d}\n", .{self.queries_failed.load(.monotonic)});
        try writer.print("# TYPE qail_rows_total counter\nqail_rows_total {d}\n", .{self.rows_returned.load(.monotonic)});
        try writer.print("# TYPE qail_connections_created counter\nqail_connections_created {d}\n", .{self.connections_created.load(.monotonic)});
        try writer.print("# TYPE qail_connections_closed counter\nqail_connections_closed {d}\n", .{self.connections_closed.load(.monotonic)});

        // Histogram
        try writer.writeAll("# TYPE qail_query_latency_seconds histogram\n");
        var cumulative: u64 = 0;
        const labels = [_][]const u8{ "0.001", "0.005", "0.01", "0.05", "0.1", "0.5", "1", "+Inf" };
        for (labels, 0..) |label, i| {
            cumulative += self.latency_buckets[i].load(.monotonic);
            try writer.print("qail_query_latency_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ label, cumulative });
        }
        try writer.print("qail_query_latency_seconds_sum {d}\n", .{self.latency_sum_ns.load(.monotonic) / 1_000_000_000});
        try writer.print("qail_query_latency_seconds_count {d}\n", .{self.queries_total.load(.monotonic)});

        // Gauges
        try writer.print("# TYPE qail_pool_active gauge\nqail_pool_active {d}\n", .{self.active.load(.monotonic)});
        try writer.print("# TYPE qail_pool_idle gauge\nqail_pool_idle {d}\n", .{self.idle.load(.monotonic)});
        try writer.print("# TYPE qail_pool_waiting gauge\nqail_pool_waiting {d}\n", .{self.waiting.load(.monotonic)});
    }

    /// Reset all counters (for testing)
    pub fn reset(self: *PoolMetrics) void {
        self.queries_total.store(0, .monotonic);
        self.queries_failed.store(0, .monotonic);
        self.rows_returned.store(0, .monotonic);
        self.connections_created.store(0, .monotonic);
        self.connections_closed.store(0, .monotonic);
        self.latency_sum_ns.store(0, .monotonic);
        for (&self.latency_buckets) |*bucket| {
            bucket.store(0, .monotonic);
        }
        self.active.store(0, .monotonic);
        self.idle.store(0, .monotonic);
        self.waiting.store(0, .monotonic);
    }
};

// ==================== Tests ====================

test "PoolMetrics init" {
    var m = PoolMetrics.init();
    try std.testing.expectEqual(@as(u64, 0), m.queries_total.load(.monotonic));
}

test "PoolMetrics recordQuery" {
    var m = PoolMetrics.init();
    m.recordQuery(500_000, 10, true); // 0.5ms, 10 rows, success
    m.recordQuery(2_000_000, 5, true); // 2ms
    m.recordQuery(99_000_000, 0, false); // 99ms (< 100ms), failed

    try std.testing.expectEqual(@as(u64, 3), m.queries_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.queries_failed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 15), m.rows_returned.load(.monotonic));

    // Check buckets
    try std.testing.expectEqual(@as(u64, 1), m.latency_buckets[0].load(.monotonic)); // <1ms
    try std.testing.expectEqual(@as(u64, 1), m.latency_buckets[1].load(.monotonic)); // <5ms
    try std.testing.expectEqual(@as(u64, 1), m.latency_buckets[4].load(.monotonic)); // <100ms
}

test "PoolMetrics percentile" {
    var m = PoolMetrics.init();
    // Add 100 queries: 90 fast (<1ms), 10 slow (>1s)
    for (0..90) |_| {
        m.recordQuery(500_000, 1, true);
    }
    for (0..10) |_| {
        m.recordQuery(2_000_000_000, 1, true);
    }

    // p50 should be <1ms bucket
    try std.testing.expectEqual(@as(u64, 1_000_000), m.percentile(0.5));
    // p99 should be >1s bucket
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), m.percentile(0.99));
}

test "PoolMetrics prometheus export" {
    var m = PoolMetrics.init();
    m.recordQuery(5_000_000, 10, true);
    m.recordConnectionCreated();

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try m.toPrometheus(fbs.writer());

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "qail_queries_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "qail_connections_created 1") != null);
}
