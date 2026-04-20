//! Query Execution Utilities
//!
//! Helper functions for query execution and statement caching.
//! Port of qail.rs/qail-pg/src/driver/query.rs

const std = @import("std");
const ast = @import("../ast/mod.zig");
const QailCmd = ast.QailCmd;
const max_wire_message_len: usize = std.math.maxInt(i32);

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
    order: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    max_size: usize,
    hits: usize = 0,
    misses: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) StatementCache {
        return .{
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .order = .empty,
            .allocator = allocator,
            .max_size = if (max_size == 0) 1 else max_size,
        };
    }

    pub fn deinit(self: *StatementCache) void {
        self.clear();
        self.entries.deinit();
        self.order.deinit(self.allocator);
    }

    /// Get or create a statement name for SQL
    pub fn getOrCreate(self: *StatementCache, sql: []const u8) ![]const u8 {
        var result = try self.getOrCreateWithStatus(sql);
        defer result.deinit(self.allocator);
        return result.name;
    }

    /// Result of a cache lookup
    pub const LookupResult = struct {
        name: []const u8,
        was_hit: bool,
        evicted_stmt_name: ?[]const u8 = null,

        pub fn deinit(self: *LookupResult, allocator: std.mem.Allocator) void {
            if (self.evicted_stmt_name) |name| allocator.free(name);
            self.evicted_stmt_name = null;
        }
    };

    /// Get or create a statement name, reporting whether it was a cache hit
    pub fn getOrCreateWithStatus(self: *StatementCache, sql: []const u8) !LookupResult {
        if (self.entries.get(sql)) |entry| {
            self.hits += 1;
            try self.touch(entry.sql);
            return .{ .name = entry.name, .was_hit = true };
        }

        self.misses += 1;
        var evicted_stmt_name: ?[]const u8 = null;
        errdefer if (evicted_stmt_name) |name| self.allocator.free(name);

        // Generate new statement name
        const name = try sqlToStmtName(self.allocator, sql);
        errdefer self.allocator.free(name);

        // Evict if at capacity
        if (self.entries.count() >= self.max_size) {
            if (self.popLru()) |evicted| {
                evicted_stmt_name = evicted.name;
                self.allocator.free(evicted.sql);
            }
        }

        const sql_key = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(sql_key);

        // Insert new entry
        const entry = CacheEntry{
            .name = name,
            .sql = sql_key,
            .param_count = countParams(sql),
        };
        try self.entries.put(sql_key, entry);
        errdefer {
            const removed = self.entries.fetchRemove(sql_key).?;
            self.allocator.free(removed.value.name);
            self.allocator.free(removed.value.sql);
        }
        try self.touch(sql_key);

        return .{
            .name = name,
            .was_hit = false,
            .evicted_stmt_name = evicted_stmt_name,
        };
    }

    /// Check if statement is cached
    pub fn contains(self: *const StatementCache, sql: []const u8) bool {
        return self.entries.contains(sql);
    }

    /// Remove a cached statement entry by SQL key.
    pub fn remove(self: *StatementCache, sql: []const u8) bool {
        const removed = self.entries.fetchRemove(sql) orelse return false;
        self.removeOrderKey(removed.value.sql);
        self.allocator.free(removed.value.name);
        self.allocator.free(removed.value.sql);
        return true;
    }

    /// Clear all cached statement entries.
    pub fn clear(self: *StatementCache) void {
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.sql);
        }
        self.entries.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
    }

    /// Cache hit rate
    pub fn hitRate(self: *const StatementCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    fn touch(self: *StatementCache, key: []const u8) !void {
        self.removeOrderKey(key);
        try self.order.append(self.allocator, key);
    }

    fn removeOrderKey(self: *StatementCache, key: []const u8) void {
        var i: usize = 0;
        while (i < self.order.items.len) {
            if (std.mem.eql(u8, self.order.items[i], key)) {
                _ = self.order.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn popLru(self: *StatementCache) ?CacheEntry {
        while (self.order.items.len > 0) {
            const lru_key = self.order.orderedRemove(0);
            if (self.entries.fetchRemove(lru_key)) |removed| {
                return removed.value;
            }
        }
        return null;
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
    if (sql.len < 2) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < sql.len - 1) : (i += 1) {
        if (sql[i] == '$' and std.ascii.isDigit(sql[i + 1])) {
            count += 1;
        }
    }
    return count;
}

fn addLenChecked(total: *usize, add: usize) !void {
    total.* = std.math.add(usize, total.*, add) catch return error.MessageTooLarge;
}

fn toWireU32Len(total: usize) !u32 {
    if (total > max_wire_message_len) return error.MessageTooLarge;
    return @intCast(total);
}

fn toWireI32Len(total: usize) !i32 {
    if (total > max_wire_message_len) return error.MessageTooLarge;
    return @intCast(total);
}

/// Build extended query message bytes (Parse + Bind + Execute + Sync)
pub fn buildExtendedQuery(
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const ?[]const u8,
) ![]u8 {
    if (params.len > std.math.maxInt(i16)) return error.TooManyParameters;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Parse message
    try buf.append(allocator, 'P'); // message type
    const parse_len_pos = buf.items.len;
    try buf.appendNTimes(allocator, 0, 4); // length placeholder

    try buf.appendSlice(allocator, ""); // unnamed statement
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, sql);
    try buf.append(allocator, 0);
    try buf.appendNTimes(allocator, 0, 2); // no param types

    // Update Parse length
    const parse_len = try toWireU32Len(std.math.sub(usize, buf.items.len, parse_len_pos) catch return error.MessageTooLarge);
    std.mem.writeInt(u32, buf.items[parse_len_pos..][0..4], parse_len, .big);

    // Bind message
    try buf.append(allocator, 'B');
    const bind_len_pos = buf.items.len;
    try buf.appendNTimes(allocator, 0, 4);

    try buf.append(allocator, 0); // portal name
    try buf.append(allocator, 0); // statement name
    try buf.appendNTimes(allocator, 0, 2); // format codes
    std.mem.writeInt(u16, buf.items[buf.items.len - 2 ..][0..2], @intCast(params.len), .big);

    for (params) |param| {
        if (param) |p| {
            _ = try toWireI32Len(p.len);
            try buf.appendNTimes(allocator, 0, 4);
            std.mem.writeInt(i32, buf.items[buf.items.len - 4 ..][0..4], try toWireI32Len(p.len), .big);
            try buf.appendSlice(allocator, p);
        } else {
            try buf.appendNTimes(allocator, 0, 4);
            std.mem.writeInt(i32, buf.items[buf.items.len - 4 ..][0..4], -1, .big);
        }
    }
    try buf.appendNTimes(allocator, 0, 2); // result format codes

    const bind_len = try toWireU32Len(std.math.sub(usize, buf.items.len, bind_len_pos) catch return error.MessageTooLarge);
    std.mem.writeInt(u32, buf.items[bind_len_pos..][0..4], bind_len, .big);

    // Execute message
    try buf.append(allocator, 'E');
    try buf.appendNTimes(allocator, 0, 4);
    std.mem.writeInt(u32, buf.items[buf.items.len - 4 ..][0..4], 9, .big);
    try buf.append(allocator, 0); // portal name
    try buf.appendNTimes(allocator, 0, 4); // max rows (0 = unlimited)

    // Sync message
    try buf.append(allocator, 'S');
    try buf.appendNTimes(allocator, 0, 4);
    std.mem.writeInt(u32, buf.items[buf.items.len - 4 ..][0..4], 4, .big);

    return try buf.toOwnedSlice(allocator);
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

test "buildExtendedQuery encodes parse-bind-execute-sync" {
    const allocator = std.testing.allocator;
    const params = [_]?[]const u8{"42"};
    const bytes = try buildExtendedQuery(allocator, "SELECT $1::int", &params);
    defer allocator.free(bytes);

    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(u8, 'P'), bytes[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 'B') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 'E') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 'S') != null);
}

test "buildExtendedQuery rejects too many params" {
    const allocator = std.testing.allocator;
    const too_many_count = @as(usize, std.math.maxInt(i16)) + 1;
    const params = try allocator.alloc(?[]const u8, too_many_count);
    defer allocator.free(params);
    for (params) |*p| p.* = null;

    try std.testing.expectError(error.TooManyParameters, buildExtendedQuery(allocator, "SELECT 1", params));
}

test "buildExtendedQuery rejects oversized param value" {
    const allocator = std.testing.allocator;
    const too_large_len: usize = @as(usize, std.math.maxInt(i32)) + 1;
    const huge_param = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];
    const params = [_]?[]const u8{huge_param};

    try std.testing.expectError(error.MessageTooLarge, buildExtendedQuery(allocator, "SELECT $1", &params));
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

test "StatementCache reports evicted statement name on miss at capacity" {
    const allocator = std.testing.allocator;
    var cache = StatementCache.init(allocator, 1);
    defer cache.deinit();

    {
        var first = try cache.getOrCreateWithStatus("SELECT 1");
        defer first.deinit(allocator);
        try std.testing.expect(!first.was_hit);
        try std.testing.expect(first.evicted_stmt_name == null);
    }

    var second = try cache.getOrCreateWithStatus("SELECT 2");
    defer second.deinit(allocator);
    try std.testing.expect(!second.was_hit);
    try std.testing.expect(second.evicted_stmt_name != null);
}

test "StatementCache eviction uses LRU order" {
    const allocator = std.testing.allocator;
    var cache = StatementCache.init(allocator, 2);
    defer cache.deinit();

    _ = try cache.getOrCreate("SELECT 1");
    _ = try cache.getOrCreate("SELECT 2");

    // Touch SELECT 1 so SELECT 2 becomes least-recently-used.
    _ = try cache.getOrCreate("SELECT 1");

    var third = try cache.getOrCreateWithStatus("SELECT 3");
    defer third.deinit(allocator);

    try std.testing.expect(cache.contains("SELECT 1"));
    try std.testing.expect(!cache.contains("SELECT 2"));
    try std.testing.expect(cache.contains("SELECT 3"));
}

test "StatementCache remove clears entry by sql key" {
    const allocator = std.testing.allocator;
    var cache = StatementCache.init(allocator, 4);
    defer cache.deinit();

    _ = try cache.getOrCreate("SELECT 42");
    try std.testing.expect(cache.contains("SELECT 42"));
    try std.testing.expect(cache.remove("SELECT 42"));
    try std.testing.expect(!cache.contains("SELECT 42"));
    try std.testing.expect(!cache.remove("SELECT 42"));
}

test "StatementCache clear removes all entries" {
    const allocator = std.testing.allocator;
    var cache = StatementCache.init(allocator, 8);
    defer cache.deinit();

    _ = try cache.getOrCreate("SELECT 1");
    _ = try cache.getOrCreate("SELECT 2");
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    try std.testing.expect(!cache.contains("SELECT 1"));
    try std.testing.expect(!cache.contains("SELECT 2"));
}
