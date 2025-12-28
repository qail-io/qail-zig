//! Query Execution Utilities
//!
//! Helper functions for query execution and statement caching.
//! Port of qail.rs/qail-pg/src/driver/query.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const QailCmd = ast.QailCmd;

/// Query execution mode
pub const QueryMode = enum {
    /// Simple query protocol (text)
    simple,
    /// Extended query protocol (binary, prepared)
    extended,
    /// Pipelined execution (batch)
    pipelined,
};

/// Query result statistics
pub const QueryStats = struct {
    rows_affected: ?u64 = null,
    rows_returned: usize = 0,
    duration_ns: u64 = 0,
    cached: bool = false,
};

/// Prepared statement cache entry
pub const CacheEntry = struct {
    name: []const u8,
    sql: []const u8,
    param_count: usize,
    use_count: usize = 0,
};

/// Statement cache using LRU eviction
pub const StatementCache = struct {
    entries: std.StringHashMap(CacheEntry),
    allocator: std.mem.Allocator,
    max_size: usize,
    hits: usize = 0,
    misses: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) StatementCache {
        return .{
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *StatementCache) void {
        // Free all allocated statement names
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
    }

    /// Get or create a statement name for SQL
    pub fn getOrCreate(self: *StatementCache, sql: []const u8) ![]const u8 {
        if (self.entries.get(sql)) |entry| {
            self.hits += 1;
            return entry.name;
        }

        self.misses += 1;

        // Generate new statement name
        const name = try sqlToStmtName(self.allocator, sql);

        // Evict if at capacity
        if (self.entries.count() >= self.max_size) {
            // Simple eviction: remove first entry
            var iter = self.entries.iterator();
            if (iter.next()) |first| {
                _ = self.entries.remove(first.key_ptr.*);
            }
        }

        // Insert new entry
        const entry = CacheEntry{
            .name = name,
            .sql = sql,
            .param_count = countParams(sql),
        };
        try self.entries.put(sql, entry);

        return name;
    }

    /// Check if statement is cached
    pub fn contains(self: *const StatementCache, sql: []const u8) bool {
        return self.entries.contains(sql);
    }

    /// Cache hit rate
    pub fn hitRate(self: *const StatementCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// Generate statement name from SQL hash
pub fn sqlToStmtName(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(sql);
    const hash = hasher.final();

    return try std.fmt.allocPrint(allocator, "s{x:0>16}", .{hash});
}

/// Count $N parameters in SQL
pub fn countParams(sql: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < sql.len - 1) : (i += 1) {
        if (sql[i] == '$' and std.ascii.isDigit(sql[i + 1])) {
            count += 1;
        }
    }
    return count;
}

/// Build extended query message bytes (Parse + Bind + Execute + Sync)
pub fn buildExtendedQuery(
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const ?[]const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Parse message
    try buf.append('P'); // message type
    const parse_len_pos = buf.items.len;
    try buf.appendNTimes(0, 4); // length placeholder

    try buf.appendSlice(""); // unnamed statement
    try buf.append(0);
    try buf.appendSlice(sql);
    try buf.append(0);
    try buf.appendNTimes(0, 2); // no param types

    // Update Parse length
    const parse_len: u32 = @intCast(buf.items.len - parse_len_pos);
    std.mem.writeInt(u32, buf.items[parse_len_pos..][0..4], parse_len, .big);

    // Bind message
    try buf.append('B');
    const bind_len_pos = buf.items.len;
    try buf.appendNTimes(0, 4);

    try buf.append(0); // portal name
    try buf.append(0); // statement name
    try buf.appendNTimes(0, 2); // format codes
    std.mem.writeInt(u16, buf.items[buf.items.len - 2 ..][0..2], @intCast(params.len), .big);

    for (params) |param| {
        if (param) |p| {
            std.mem.writeInt(i32, buf.items[buf.items.len..][0..4], @intCast(p.len), .big);
            try buf.appendNTimes(0, 4);
            try buf.appendSlice(p);
        } else {
            std.mem.writeInt(i32, buf.items[buf.items.len..][0..4], -1, .big);
            try buf.appendNTimes(0, 4);
        }
    }
    try buf.appendNTimes(0, 2); // result format codes

    const bind_len: u32 = @intCast(buf.items.len - bind_len_pos);
    std.mem.writeInt(u32, buf.items[bind_len_pos..][0..4], bind_len, .big);

    // Execute message
    try buf.append('E');
    try buf.appendNTimes(0, 4);
    std.mem.writeInt(u32, buf.items[buf.items.len - 4 ..][0..4], 9, .big);
    try buf.append(0); // portal name
    try buf.appendNTimes(0, 4); // max rows (0 = unlimited)

    // Sync message
    try buf.append('S');
    try buf.appendNTimes(0, 4);
    std.mem.writeInt(u32, buf.items[buf.items.len - 4 ..][0..4], 4, .big);

    return try buf.toOwnedSlice();
}

// ==================== Tests ====================

test "sqlToStmtName" {
    const allocator = std.testing.allocator;

    const name1 = try sqlToStmtName(allocator, "SELECT * FROM users");
    defer allocator.free(name1);

    const name2 = try sqlToStmtName(allocator, "SELECT * FROM users");
    defer allocator.free(name2);

    // Same SQL = same name
    try std.testing.expectEqualStrings(name1, name2);

    // Different SQL = different name
    const name3 = try sqlToStmtName(allocator, "SELECT * FROM orders");
    defer allocator.free(name3);

    try std.testing.expect(!std.mem.eql(u8, name1, name3));
}

test "countParams" {
    try std.testing.expectEqual(@as(usize, 0), countParams("SELECT * FROM users"));
    try std.testing.expectEqual(@as(usize, 1), countParams("SELECT * FROM users WHERE id = $1"));
    try std.testing.expectEqual(@as(usize, 2), countParams("SELECT * FROM users WHERE id = $1 AND name = $2"));
}

test "StatementCache" {
    const allocator = std.testing.allocator;
    var cache = StatementCache.init(allocator, 10);
    defer cache.deinit();

    const name1 = try cache.getOrCreate("SELECT * FROM users");
    const name2 = try cache.getOrCreate("SELECT * FROM users");

    // Same SQL returns same name (cached)
    try std.testing.expectEqualStrings(name1, name2);
    try std.testing.expectEqual(@as(usize, 1), cache.hits);
    try std.testing.expectEqual(@as(usize, 1), cache.misses);
}
