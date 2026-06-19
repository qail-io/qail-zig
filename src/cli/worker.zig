//! Sync worker CLI module.
//!
//! Implements `qail worker` for hybrid mode by polling `_qail_queue` and
//! syncing rows to Qdrant over REST.

const std = @import("std");
const identifier_safety = @import("identifier_safety.zig");
const io_compat = @import("../runtime/io.zig");
const qdrant_safety = @import("qdrant_safety.zig");
const ast = @import("../ast/mod.zig");
const process = @import("../runtime/process.zig");

const Allocator = std.mem.Allocator;
const print = std.debug.print;
const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Assignment = ast.Assignment;
const WhereClause = ast.WhereClause;
const OrderBy = ast.OrderBy;
const Value = ast.Value;
const PgDriver = @import("../driver/mod.zig").driver.PgDriver;

const MAX_CONFIG_BYTES = 4 * 1024 * 1024;
const STALE_RECOVERY_INTERVAL_MS: i64 = 30_000;
const STALE_PROCESSING_WINDOW_SECS: u64 = 10 * 60;

const SyncRule = struct {
    source_table: []u8,
    target_collection: []u8,
    trigger_column: ?[]u8 = null,

    fn deinit(self: *SyncRule, allocator: Allocator) void {
        allocator.free(self.source_table);
        allocator.free(self.target_collection);
        if (self.trigger_column) |value| allocator.free(value);
        self.trigger_column = null;
    }
};

const WorkerConfig = struct {
    project_mode: ?[]u8 = null,
    postgres_url: ?[]u8 = null,
    qdrant_url: ?[]u8 = null,
    sync_rules: std.ArrayList(SyncRule) = .empty,

    fn deinit(self: *WorkerConfig, allocator: Allocator) void {
        if (self.project_mode) |value| allocator.free(value);
        if (self.postgres_url) |value| allocator.free(value);
        if (self.qdrant_url) |value| allocator.free(value);
        self.project_mode = null;
        self.postgres_url = null;
        self.qdrant_url = null;
        for (self.sync_rules.items) |*rule| rule.deinit(allocator);
        self.sync_rules.deinit(allocator);
    }
};

const SyncRuleBuilder = struct {
    source_table: ?[]u8 = null,
    target_collection: ?[]u8 = null,
    trigger_column: ?[]u8 = null,

    fn hasAnyField(self: *const SyncRuleBuilder) bool {
        return self.source_table != null or self.target_collection != null or self.trigger_column != null;
    }

    fn deinit(self: *SyncRuleBuilder, allocator: Allocator) void {
        if (self.source_table) |value| allocator.free(value);
        if (self.target_collection) |value| allocator.free(value);
        if (self.trigger_column) |value| allocator.free(value);
        self.source_table = null;
        self.target_collection = null;
        self.trigger_column = null;
    }
};

const QueueItem = struct {
    id: i64,
    ref_table: []u8,
    ref_id: []u8,
    operation: []u8,

    fn deinit(self: *QueueItem, allocator: Allocator) void {
        allocator.free(self.ref_table);
        allocator.free(self.ref_id);
        allocator.free(self.operation);
        self.ref_table = &.{};
        self.ref_id = &.{};
        self.operation = &.{};
    }
};

const Section = enum {
    none,
    project,
    postgres,
    qdrant,
    sync,
    other,
};

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

const TableHeader = struct {
    is_array: bool,
    name: []const u8,
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn statusCode(status: std.http.Status) u10 {
    return @intFromEnum(status);
}

fn statusSuccess(status: std.http.Status) bool {
    const code = statusCode(status);
    return code >= 200 and code < 300;
}

fn trimBaseUrl(url: []const u8) []const u8 {
    var out = std.mem.trim(u8, url, " \t\r\n");
    while (out.len > 1 and out[out.len - 1] == '/') {
        out = out[0 .. out.len - 1];
    }
    return out;
}

fn redactUrlAlloc(allocator: Allocator, raw_url: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, raw_url, "://") orelse return allocator.dupe(u8, raw_url);
    const auth_start = scheme_end + 3;
    const auth_end = std.mem.indexOfScalarPos(u8, raw_url, auth_start, '@') orelse return allocator.dupe(u8, raw_url);
    const auth = raw_url[auth_start..auth_end];
    const colon = std.mem.indexOfScalar(u8, auth, ':') orelse return allocator.dupe(u8, raw_url);
    const user = auth[0..colon];

    return std.fmt.allocPrint(allocator, "{s}{s}:***{s}", .{
        raw_url[0..auth_start],
        user,
        raw_url[auth_end..],
    });
}

fn nowEpochSeconds() !u64 {
    const now = std.Io.Clock.now(.real, io_compat.runtimeIo()).toSeconds();
    if (now < 0) return error.InvalidSystemClock;
    return @intCast(now);
}

fn formatEpochSecondsIso8601Alloc(allocator: Allocator, epoch_secs: u64) ![]u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn nowTimestampIso8601Alloc(allocator: Allocator) ![]u8 {
    return formatEpochSecondsIso8601Alloc(allocator, try nowEpochSeconds());
}

fn timestampIso8601SecondsAgoAlloc(allocator: Allocator, seconds_ago: u64) ![]u8 {
    const now = try nowEpochSeconds();
    const target = if (now > seconds_ago) now - seconds_ago else 0;
    return formatEpochSecondsIso8601Alloc(allocator, target);
}

fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io_compat.runtimeIo(),
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn replaceOwnedField(allocator: Allocator, dest: *?[]u8, value: []u8) void {
    if (dest.*) |old| allocator.free(old);
    dest.* = value;
}

fn splitKeyValue(line: []const u8) ?KeyValue {
    var in_single = false;
    var in_double = false;
    var escaped = false;

    for (line, 0..) |ch, idx| {
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (in_single) {
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '=') {
            return .{
                .key = std.mem.trim(u8, line[0..idx], " \t\r"),
                .value = std.mem.trim(u8, line[idx + 1 ..], " \t\r"),
            };
        }
    }
    return null;
}

fn parseTableHeader(line: []const u8) ?TableHeader {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;

    if (line.len >= 4 and line[1] == '[' and line[line.len - 2] == ']') {
        const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t\r");
        if (name.len == 0) return null;
        return .{ .is_array = true, .name = name };
    }

    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    if (name.len == 0) return null;
    return .{ .is_array = false, .name = name };
}

fn stripInlineComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var escaped = false;

    for (line, 0..) |ch, idx| {
        if (in_double) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') in_double = false;
            continue;
        }
        if (in_single) {
            if (ch == '\'') in_single = false;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '#') return line[0..idx];
    }
    return line;
}

fn parseTomlStringLike(allocator: Allocator, raw: []const u8) ![]u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return error.InvalidConfig;

    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return parseDoubleQuotedString(allocator, value[1 .. value.len - 1]);
    }
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        return allocator.dupe(u8, value[1 .. value.len - 1]);
    }
    return allocator.dupe(u8, value);
}

fn parseDoubleQuotedString(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch != '\\') {
            try out.append(allocator, ch);
            continue;
        }
        if (i + 1 >= value.len) return error.InvalidConfig;
        i += 1;
        const esc = value[i];
        const decoded: u8 = switch (esc) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            else => esc,
        };
        try out.append(allocator, decoded);
    }

    return out.toOwnedSlice(allocator);
}

fn flushCurrentSyncRule(
    allocator: Allocator,
    config: *WorkerConfig,
    current_sync: *?SyncRuleBuilder,
) !void {
    if (current_sync.* == null) return;

    var rule = current_sync.*.?;
    current_sync.* = null;
    errdefer rule.deinit(allocator);

    if (!rule.hasAnyField()) return;
    if (rule.source_table == null or rule.target_collection == null) {
        return error.InvalidConfig;
    }
    if (!identifier_safety.isValidQualifiedIdentifier(rule.source_table.?)) return error.InvalidConfig;
    if (rule.trigger_column) |column| {
        if (!identifier_safety.isValidBareIdentifier(column)) return error.InvalidConfig;
    }
    try qdrant_safety.validatePathSegment(rule.target_collection.?);

    try config.sync_rules.append(allocator, .{
        .source_table = rule.source_table.?,
        .target_collection = rule.target_collection.?,
        .trigger_column = rule.trigger_column,
    });

    rule.source_table = null;
    rule.target_collection = null;
    rule.trigger_column = null;
}

fn loadConfig(allocator: Allocator) !WorkerConfig {
    const raw = try readFileAlloc(allocator, "qail.toml", MAX_CONFIG_BYTES);
    defer allocator.free(raw);

    var config = WorkerConfig{};
    errdefer config.deinit(allocator);

    var section: Section = .none;
    var current_sync: ?SyncRuleBuilder = null;
    errdefer if (current_sync) |*rule| rule.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const no_comment = stripInlineComment(line_raw);
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;

        if (parseTableHeader(line)) |header| {
            if (header.is_array and std.ascii.eqlIgnoreCase(header.name, "sync")) {
                try flushCurrentSyncRule(allocator, &config, &current_sync);
                current_sync = SyncRuleBuilder{};
                section = .sync;
                continue;
            }

            if (section == .sync) {
                try flushCurrentSyncRule(allocator, &config, &current_sync);
            }

            if (!header.is_array and std.ascii.eqlIgnoreCase(header.name, "project")) {
                section = .project;
            } else if (!header.is_array and std.ascii.eqlIgnoreCase(header.name, "postgres")) {
                section = .postgres;
            } else if (!header.is_array and std.ascii.eqlIgnoreCase(header.name, "qdrant")) {
                section = .qdrant;
            } else {
                section = .other;
            }
            continue;
        }

        const kv = splitKeyValue(line) orelse continue;
        const parsed = try parseTomlStringLike(allocator, kv.value);
        var value_assigned = false;

        switch (section) {
            .project => {
                if (std.mem.eql(u8, kv.key, "mode")) {
                    replaceOwnedField(allocator, &config.project_mode, parsed);
                    value_assigned = true;
                }
            },
            .postgres => {
                if (std.mem.eql(u8, kv.key, "url")) {
                    replaceOwnedField(allocator, &config.postgres_url, parsed);
                    value_assigned = true;
                }
            },
            .qdrant => {
                if (std.mem.eql(u8, kv.key, "url")) {
                    replaceOwnedField(allocator, &config.qdrant_url, parsed);
                    value_assigned = true;
                }
            },
            .sync => {
                if (current_sync == null) current_sync = SyncRuleBuilder{};
                var rule = &current_sync.?;
                if (std.mem.eql(u8, kv.key, "source_table")) {
                    replaceOwnedField(allocator, &rule.source_table, parsed);
                    value_assigned = true;
                }
                if (std.mem.eql(u8, kv.key, "target_collection")) {
                    replaceOwnedField(allocator, &rule.target_collection, parsed);
                    value_assigned = true;
                }
                if (std.mem.eql(u8, kv.key, "trigger_column")) {
                    replaceOwnedField(allocator, &rule.trigger_column, parsed);
                    value_assigned = true;
                }
            },
            .none, .other => {
                if (std.mem.eql(u8, kv.key, "project.mode")) {
                    replaceOwnedField(allocator, &config.project_mode, parsed);
                    value_assigned = true;
                }
            },
        }

        if (!value_assigned) allocator.free(parsed);
    }

    try flushCurrentSyncRule(allocator, &config, &current_sync);
    return config;
}

fn resolvePostgresUrl(allocator: Allocator, config: *const WorkerConfig) ![]u8 {
    if (process.getEnvVarOwned(allocator, "QAIL_DATABASE_URL")) |value| return value else |_| {}
    if (process.getEnvVarOwned(allocator, "DATABASE_URL")) |value| return value else |_| {}
    if (config.postgres_url) |value| return allocator.dupe(u8, value);
    return error.MissingPostgresUrl;
}

fn resolveQdrantUrl(allocator: Allocator, config: *const WorkerConfig) ![]u8 {
    if (process.getEnvVarOwned(allocator, "QDRANT_URL")) |value| return value else |_| {}
    if (config.qdrant_url) |value| return allocator.dupe(u8, value);
    return error.MissingQdrantUrl;
}

fn deinitFetchedRows(allocator: Allocator, rows: []@import("../driver/row.zig").PgRow) void {
    for (rows) |*row| {
        var owned = row.*;
        owned.deinit();
    }
    allocator.free(rows);
}

fn qdrantRequest(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
) !HttpResponse {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io_compat.runtimeIo(),
    };
    defer client.deinit();

    var response_body = io_compat.AllocatingWriter.init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = response_body.writer(),
    });

    return .{
        .status = result.status,
        .body = try response_body.toOwnedSlice(),
    };
}

fn buildDeletePayload(allocator: Allocator, ref_id: []const u8) ![]u8 {
    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{\"points\":[");
    try qdrant_safety.writePointId(writer, ref_id);
    try writer.writeAll("]}");
    return try out.toOwnedSlice();
}

fn buildUpsertPayload(allocator: Allocator, ref_id: []const u8, vector: []const f32) ![]u8 {
    try qdrant_safety.validateVector(vector);

    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    const writer = out.writer();

    try writer.writeAll("{\"points\":[{\"id\":");
    try qdrant_safety.writePointId(writer, ref_id);
    try writer.writeAll(",\"vector\":[");
    for (vector, 0..) |value, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{d}", .{value});
    }
    try writer.writeAll("],\"payload\":{}}]}");
    return try out.toOwnedSlice();
}

fn getCollectionVectorSize(allocator: Allocator, qdrant_url: []const u8, collection: []const u8) !usize {
    try qdrant_safety.validatePathSegment(collection);

    const base = trimBaseUrl(qdrant_url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}", .{ base, collection });
    defer allocator.free(endpoint);

    const response = try qdrantRequest(allocator, .GET, endpoint, null);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) return error.QdrantCollectionInfoFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), response.body, .{});
    const root = parsed.value;
    if (root != .object) return error.InvalidQdrantResponse;

    const result = root.object.get("result") orelse return error.InvalidQdrantResponse;
    if (result != .object) return error.InvalidQdrantResponse;

    const config = result.object.get("config") orelse return error.InvalidQdrantResponse;
    if (config != .object) return error.InvalidQdrantResponse;

    const params = config.object.get("params") orelse return error.InvalidQdrantResponse;
    if (params != .object) return error.InvalidQdrantResponse;

    const vectors = params.object.get("vectors") orelse return error.InvalidQdrantResponse;
    if (vectors == .object) {
        if (vectors.object.get("size")) |size_value| {
            switch (size_value) {
                .integer => |v| if (v > 0) return @intCast(v),
                .float => |v| if (qdrantVectorSizeFloat(v)) |size| return size,
                else => {},
            }
        }

        var it = vectors.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            if (entry.value_ptr.object.get("size")) |named_size| {
                switch (named_size) {
                    .integer => |v| if (v > 0) return @intCast(v),
                    .float => |v| if (qdrantVectorSizeFloat(v)) |size| return size,
                    else => {},
                }
            }
        }
    }

    return error.InvalidQdrantResponse;
}

fn qdrantVectorSizeFloat(value: f64) ?usize {
    if (!std.math.isFinite(value) or value <= 0) return null;
    if (@floor(value) != value) return null;
    if (value > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(value);
}

fn hashEmbedding(allocator: Allocator, text: []const u8, dim: usize) ![]f32 {
    if (dim == 0) return error.InvalidQdrantVector;

    const vector = try allocator.alloc(f32, dim);
    const hash_seed = std.hash.Wyhash.hash(0, text);
    for (vector, 0..) |*slot, idx| {
        const mixed = hash_seed ^ (@as(u64, idx) *% 0x9E3779B97F4A7C15);
        const bucket = @as(f32, @floatFromInt(mixed % 1000));
        slot.* = (bucket / 1000.0) - 0.5;
    }
    return vector;
}

fn qdrantDeletePoint(allocator: Allocator, qdrant_url: []const u8, collection: []const u8, ref_id: []const u8) !void {
    try qdrant_safety.validatePathSegment(collection);

    const base = trimBaseUrl(qdrant_url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}/points/delete?wait=true", .{ base, collection });
    defer allocator.free(endpoint);

    const payload = try buildDeletePayload(allocator, ref_id);
    defer allocator.free(payload);

    const response = try qdrantRequest(allocator, .POST, endpoint, payload);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Qdrant delete failed ({d}): {s}\n", .{ statusCode(response.status), response.body });
        return error.QdrantDeleteFailed;
    }
}

fn qdrantUpsertPoint(
    allocator: Allocator,
    qdrant_url: []const u8,
    collection: []const u8,
    ref_id: []const u8,
    vector: []const f32,
) !void {
    try qdrant_safety.validatePathSegment(collection);

    const base = trimBaseUrl(qdrant_url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}/points?wait=true", .{ base, collection });
    defer allocator.free(endpoint);

    const payload = try buildUpsertPayload(allocator, ref_id, vector);
    defer allocator.free(payload);

    const response = try qdrantRequest(allocator, .PUT, endpoint, payload);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Qdrant upsert failed ({d}): {s}\n", .{ statusCode(response.status), response.body });
        return error.QdrantUpsertFailed;
    }
}

fn fetchPendingItems(allocator: Allocator, pg: *PgDriver, limit: u32) ![]QueueItem {
    const cols = [_]Expr{
        Expr.col("id"),
        Expr.col("ref_table"),
        Expr.col("ref_id"),
        Expr.col("operation"),
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "pending" } } },
        .{ .condition = .{ .column = "retry_count", .op = .lt, .value = .{ .int = 5 } } },
    };
    const order = [_]OrderBy{
        .{ .column = "id", .order = .asc },
    };

    const rows = try pg.fetchAll(
        &QailCmd.get("_qail_queue")
            .select(&cols)
            .where(&where)
            .orderBy(&order)
            .limit(@as(i64, limit)),
    );
    defer deinitFetchedRows(allocator, rows);

    var items = try allocator.alloc(QueueItem, rows.len);
    var item_count: usize = 0;
    errdefer {
        for (items[0..item_count]) |*item| item.deinit(allocator);
        allocator.free(items);
    }

    for (rows, 0..) |row, i| {
        const ref_table = row.getString(1) orelse "";
        const ref_id = row.getString(2) orelse "";
        const operation = row.getString(3) orelse "";
        items[i] = .{
            .id = row.getInt64(0) orelse 0,
            .ref_table = try allocator.dupe(u8, ref_table),
            .ref_id = try allocator.dupe(u8, ref_id),
            .operation = try allocator.dupe(u8, operation),
        };
        item_count += 1;
    }
    return items;
}

fn claimItem(allocator: Allocator, pg: *PgDriver, id: i64) !bool {
    const now_ts = try nowTimestampIso8601Alloc(allocator);
    defer allocator.free(now_ts);

    const values = [_]Assignment{
        .{ .column = "status", .value = .{ .string = "processing" } },
        .{ .column = "processed_at", .value = .{ .timestamp = now_ts } },
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = id } } },
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "pending" } } },
    };
    const cmd = QailCmd.set("_qail_queue").values(&values).where(&where);
    const affected = try pg.execute(&cmd);
    return affected > 0;
}

fn markProcessed(allocator: Allocator, pg: *PgDriver, id: i64) !void {
    const now_ts = try nowTimestampIso8601Alloc(allocator);
    defer allocator.free(now_ts);

    const values = [_]Assignment{
        .{ .column = "status", .value = .{ .string = "processed" } },
        .{ .column = "processed_at", .value = .{ .timestamp = now_ts } },
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = id } } },
    };
    const cmd = QailCmd.set("_qail_queue").values(&values).where(&where);
    _ = try pg.execute(&cmd);
}

fn fetchRetryCount(allocator: Allocator, pg: *PgDriver, id: i64) !u64 {
    const cols = [_]Expr{Expr.col("retry_count")};
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = id } } },
    };
    const rows = try pg.fetchAll(&QailCmd.get("_qail_queue").select(&cols).where(&where).limit(1));
    defer deinitFetchedRows(allocator, rows);
    if (rows.len == 0) return 0;
    const current = rows[0].getInt64(0) orelse 0;
    if (current <= 0) return 0;
    return @intCast(current);
}

fn markFailed(allocator: Allocator, pg: *PgDriver, id: i64, msg: []const u8) !void {
    const bounded_message = if (msg.len > 400) msg[0..400] else msg;
    const current_retry = fetchRetryCount(allocator, pg, id) catch 0;
    const next_retry: i64 = if (current_retry >= std.math.maxInt(i64))
        std.math.maxInt(i64)
    else
        @intCast(current_retry + 1);
    const values = [_]Assignment{
        .{ .column = "status", .value = .{ .string = "failed" } },
        .{ .column = "retry_count", .value = .{ .int = next_retry } },
        .{ .column = "error_message", .value = .{ .string = bounded_message } },
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = id } } },
    };
    const cmd = QailCmd.set("_qail_queue").values(&values).where(&where);
    _ = try pg.execute(&cmd);
}

fn appendQueueIdsMatching(
    allocator: Allocator,
    pg: *PgDriver,
    where: []const WhereClause,
    ids: *std.ArrayList(i64),
) !void {
    const cols = [_]Expr{Expr.col("id")};
    const order = [_]OrderBy{
        .{ .column = "id", .order = .asc },
    };

    const rows = try pg.fetchAll(
        &QailCmd.get("_qail_queue")
            .select(&cols)
            .where(where)
            .orderBy(&order)
            .limit(128),
    );
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const id = row.getInt64(0) orelse continue;
        try ids.append(allocator, id);
    }
}

fn recoverStaleJobs(allocator: Allocator, pg: *PgDriver) !usize {
    const stale_before = try timestampIso8601SecondsAgoAlloc(allocator, STALE_PROCESSING_WINDOW_SECS);
    defer allocator.free(stale_before);

    const stale_where = [_]WhereClause{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "processing" } } },
        .{ .condition = .{ .column = "processed_at", .op = .lt, .value = .{ .timestamp = stale_before } } },
    };
    const null_processed_where = [_]WhereClause{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "processing" } } },
        .{ .condition = .{ .column = "processed_at", .op = .is_null, .value = Value.null } },
    };

    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(allocator);
    try appendQueueIdsMatching(allocator, pg, &stale_where, &ids);
    try appendQueueIdsMatching(allocator, pg, &null_processed_where, &ids);

    var recovered: usize = 0;
    for (ids.items) |id| {
        const current_retry = fetchRetryCount(allocator, pg, id) catch 0;
        const next_retry: i64 = if (current_retry >= std.math.maxInt(i64))
            std.math.maxInt(i64)
        else
            @intCast(current_retry + 1);
        const values = [_]Assignment{
            .{ .column = "status", .value = .{ .string = "pending" } },
            .{ .column = "retry_count", .value = .{ .int = next_retry } },
        };
        const retry_where = [_]WhereClause{
            .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = id } } },
            .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "processing" } } },
        };
        const cmd = QailCmd.set("_qail_queue").values(&values).where(&retry_where);
        const affected = pg.execute(&cmd) catch 0;
        if (affected > 0) recovered += 1;
    }
    return recovered;
}

fn findSyncRule(config: *const WorkerConfig, source_table: []const u8) ?*const SyncRule {
    for (config.sync_rules.items) |*rule| {
        if (std.mem.eql(u8, rule.source_table, source_table)) return rule;
    }
    return null;
}

fn fetchTriggerText(allocator: Allocator, pg: *PgDriver, source_table: []const u8, trigger_col: []const u8, ref_id: []const u8) !?[]u8 {
    const cols = [_]Expr{Expr.col(trigger_col)};
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .string = ref_id } } },
    };
    const rows = try pg.fetchAll(&QailCmd.get(source_table).select(&cols).where(&where).limit(1));
    defer deinitFetchedRows(allocator, rows);
    if (rows.len == 0) return null;
    const text = rows[0].getString(0) orelse return null;
    return try allocator.dupe(u8, text);
}

fn processItem(
    allocator: Allocator,
    config: *const WorkerConfig,
    pg: *PgDriver,
    qdrant_url: []const u8,
    vector_dim_cache: *std.StringHashMap(usize),
    item: QueueItem,
) !void {
    const rule = findSyncRule(config, item.ref_table) orelse return error.NoSyncRule;

    if (std.ascii.eqlIgnoreCase(item.operation, "DELETE")) {
        try qdrantDeletePoint(allocator, qdrant_url, rule.target_collection, item.ref_id);
        return;
    }

    const trigger_col = rule.trigger_column orelse "description";
    const maybe_text = try fetchTriggerText(allocator, pg, item.ref_table, trigger_col, item.ref_id);
    defer if (maybe_text) |text| allocator.free(text);

    if (maybe_text == null) {
        try qdrantDeletePoint(allocator, qdrant_url, rule.target_collection, item.ref_id);
        return;
    }

    const dim = blk: {
        if (vector_dim_cache.get(rule.target_collection)) |cached| break :blk cached;
        const discovered = getCollectionVectorSize(allocator, qdrant_url, rule.target_collection) catch 1536;
        const key = try allocator.dupe(u8, rule.target_collection);
        errdefer allocator.free(key);
        try vector_dim_cache.put(key, discovered);
        break :blk discovered;
    };

    const embedding = try hashEmbedding(allocator, maybe_text.?, dim);
    defer allocator.free(embedding);
    try qdrantUpsertPoint(allocator, qdrant_url, rule.target_collection, item.ref_id, embedding);
}

fn processBatch(
    allocator: Allocator,
    config: *const WorkerConfig,
    pg: *PgDriver,
    qdrant_url: []const u8,
    batch_size: u32,
    vector_dim_cache: *std.StringHashMap(usize),
) !usize {
    const pending = try fetchPendingItems(allocator, pg, batch_size);
    defer {
        for (pending) |*item| item.deinit(allocator);
        allocator.free(pending);
    }
    if (pending.len == 0) return 0;

    var processed: usize = 0;
    for (pending) |item| {
        const claimed = claimItem(allocator, pg, item.id) catch false;
        if (!claimed) continue;

        processItem(allocator, config, pg, qdrant_url, vector_dim_cache, item) catch |err| {
            const msg = @errorName(err);
            markFailed(allocator, pg, item.id, msg) catch {};
            continue;
        };
        try markProcessed(allocator, pg, item.id);
        processed += 1;
    }
    return processed;
}

pub fn make(comptime Cli: type) type {
    const WorkerCmd = Cli.WorkerCmd;

    return struct {
        pub fn runWorker(allocator: Allocator, cmd: WorkerCmd) !void {
            var config = try loadConfig(allocator);
            defer config.deinit(allocator);

            const mode = config.project_mode orelse return error.InvalidProjectMode;
            if (!std.ascii.eqlIgnoreCase(mode, "hybrid")) return error.InvalidProjectMode;
            if (config.sync_rules.items.len == 0) return error.NoSyncRules;

            const postgres_url = try resolvePostgresUrl(allocator, &config);
            defer allocator.free(postgres_url);
            const qdrant_url = try resolveQdrantUrl(allocator, &config);
            defer allocator.free(qdrant_url);
            const redacted_pg_url = try redactUrlAlloc(allocator, postgres_url);
            defer allocator.free(redacted_pg_url);

            print("🔄 QAIL Worker Daemon\n", .{});
            print("PostgreSQL: {s}\n", .{redacted_pg_url});
            print("Qdrant: {s}\n", .{qdrant_url});
            print("Poll interval: {d}ms\n", .{cmd.interval_ms});
            print("Batch size: {d}\n", .{cmd.batch_size});

            var pg = try PgDriver.connectUrl(allocator, postgres_url);
            defer pg.deinit();

            var vector_dim_cache = std.StringHashMap(usize).init(allocator);
            defer {
                var it = vector_dim_cache.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                vector_dim_cache.deinit();
            }

            var last_recovery_ms: i64 = std.math.minInt(i64);
            while (true) {
                const now_ms = std.Io.Clock.now(.awake, io_compat.runtimeIo()).toMilliseconds();
                const should_recover = if (last_recovery_ms == std.math.minInt(i64))
                    true
                else
                    (now_ms - last_recovery_ms) >= STALE_RECOVERY_INTERVAL_MS;
                if (should_recover) {
                    const recovered = recoverStaleJobs(allocator, &pg) catch |err| blk: {
                        print("Worker stale-recovery error: {}\n", .{err});
                        break :blk 0;
                    };
                    last_recovery_ms = now_ms;
                    if (recovered > 0) {
                        print("↺ Recovered {d} stale queue item(s)\n", .{recovered});
                    }
                }

                const processed_count = processBatch(
                    allocator,
                    &config,
                    &pg,
                    qdrant_url,
                    cmd.batch_size,
                    &vector_dim_cache,
                ) catch |err| {
                    print("Worker batch error: {}\n", .{err});
                    std.Io.sleep(io_compat.runtimeIo(), std.Io.Duration.fromSeconds(1), .awake) catch {};
                    continue;
                };

                if (processed_count > 0) {
                    print("✓ Processed {d} queue item(s)\n", .{processed_count});
                    continue;
                }

                const sleep_ms: i64 = if (cmd.interval_ms > std.math.maxInt(i64))
                    std.math.maxInt(i64)
                else
                    @intCast(cmd.interval_ms);
                std.Io.sleep(io_compat.runtimeIo(), std.Io.Duration.fromMilliseconds(sleep_ms), .awake) catch {};
            }
        }
    };
}

test "load worker config parses hybrid urls and sync rules" {
    const allocator = std.testing.allocator;
    const raw =
        \\[project]
        \\mode = "hybrid"
        \\
        \\[postgres]
        \\url = "postgres://localhost/mydb"
        \\
        \\[qdrant]
        \\url = "http://localhost:6333"
        \\
        \\[[sync]]
        \\source_table = "products"
        \\target_collection = "products_search"
        \\trigger_column = "description"
    ;

    var config = WorkerConfig{};
    errdefer config.deinit(allocator);

    // Reuse parser flow through temporary file.
    const path = "tmp_worker_test.qail.toml";
    defer std.Io.Dir.cwd().deleteFile(io_compat.runtimeIo(), path) catch {};
    try std.Io.Dir.cwd().writeFile(io_compat.runtimeIo(), .{ .sub_path = path, .data = raw });

    const saved = try readFileAlloc(allocator, path, MAX_CONFIG_BYTES);
    defer allocator.free(saved);

    // Parse through the same parser logic as loadConfig.
    var section: Section = .none;
    var current_sync: ?SyncRuleBuilder = null;
    errdefer if (current_sync) |*rule| rule.deinit(allocator);
    var lines = std.mem.splitScalar(u8, saved, '\n');
    while (lines.next()) |line_raw| {
        const no_comment = stripInlineComment(line_raw);
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        if (parseTableHeader(line)) |header| {
            if (header.is_array and std.ascii.eqlIgnoreCase(header.name, "sync")) {
                try flushCurrentSyncRule(allocator, &config, &current_sync);
                current_sync = SyncRuleBuilder{};
                section = .sync;
                continue;
            }
            if (!header.is_array and std.ascii.eqlIgnoreCase(header.name, "project")) section = .project else if (!header.is_array and std.ascii.eqlIgnoreCase(header.name, "postgres")) section = .postgres else if (!header.is_array and std.ascii.eqlIgnoreCase(header.name, "qdrant")) section = .qdrant else section = .other;
            continue;
        }
        const kv = splitKeyValue(line) orelse continue;
        const parsed = try parseTomlStringLike(allocator, kv.value);
        var assigned = false;
        switch (section) {
            .project => if (std.mem.eql(u8, kv.key, "mode")) {
                replaceOwnedField(allocator, &config.project_mode, parsed);
                assigned = true;
            },
            .postgres => if (std.mem.eql(u8, kv.key, "url")) {
                replaceOwnedField(allocator, &config.postgres_url, parsed);
                assigned = true;
            },
            .qdrant => if (std.mem.eql(u8, kv.key, "url")) {
                replaceOwnedField(allocator, &config.qdrant_url, parsed);
                assigned = true;
            },
            .sync => {
                if (current_sync == null) current_sync = SyncRuleBuilder{};
                var rule = &current_sync.?;
                if (std.mem.eql(u8, kv.key, "source_table")) {
                    replaceOwnedField(allocator, &rule.source_table, parsed);
                    assigned = true;
                }
                if (std.mem.eql(u8, kv.key, "target_collection")) {
                    replaceOwnedField(allocator, &rule.target_collection, parsed);
                    assigned = true;
                }
                if (std.mem.eql(u8, kv.key, "trigger_column")) {
                    replaceOwnedField(allocator, &rule.trigger_column, parsed);
                    assigned = true;
                }
            },
            .none, .other => {},
        }
        if (!assigned) allocator.free(parsed);
    }
    try flushCurrentSyncRule(allocator, &config, &current_sync);

    try std.testing.expect(config.project_mode != null);
    try std.testing.expectEqualStrings("hybrid", config.project_mode.?);
    try std.testing.expect(config.postgres_url != null);
    try std.testing.expect(config.qdrant_url != null);
    try std.testing.expectEqual(@as(usize, 1), config.sync_rules.items.len);
    try std.testing.expectEqualStrings("products", config.sync_rules.items[0].source_table);
    try std.testing.expectEqualStrings("products_search", config.sync_rules.items[0].target_collection);

    config.deinit(allocator);
}

test "worker config rejects unsafe qdrant collection path segment" {
    const allocator = std.testing.allocator;
    var config = WorkerConfig{};
    defer config.deinit(allocator);

    var current_sync: ?SyncRuleBuilder = .{
        .source_table = try allocator.dupe(u8, "products"),
        .target_collection = try allocator.dupe(u8, "products/delete?wait=false"),
        .trigger_column = null,
    };

    try std.testing.expectError(
        error.InvalidQdrantPathSegment,
        flushCurrentSyncRule(allocator, &config, &current_sync),
    );
    if (current_sync) |*rule| rule.deinit(allocator);
}

test "worker config rejects unsafe generated qail identifiers" {
    const allocator = std.testing.allocator;
    var config = WorkerConfig{};
    defer config.deinit(allocator);

    var bad_table: ?SyncRuleBuilder = .{
        .source_table = try allocator.dupe(u8, "products; drop table users"),
        .target_collection = try allocator.dupe(u8, "products_search"),
        .trigger_column = null,
    };
    try std.testing.expectError(error.InvalidConfig, flushCurrentSyncRule(allocator, &config, &bad_table));
    if (bad_table) |*rule| rule.deinit(allocator);

    var bad_column: ?SyncRuleBuilder = .{
        .source_table = try allocator.dupe(u8, "products"),
        .target_collection = try allocator.dupe(u8, "products_search"),
        .trigger_column = try allocator.dupe(u8, "description; drop table users"),
    };
    try std.testing.expectError(error.InvalidConfig, flushCurrentSyncRule(allocator, &config, &bad_column));
    if (bad_column) |*rule| rule.deinit(allocator);
}

test "worker qdrant payloads reject unsafe point ids and vectors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidQdrantPointId, buildDeletePayload(allocator, ""));
    try std.testing.expectError(error.InvalidQdrantPointId, buildDeletePayload(allocator, "-1"));
    try std.testing.expectError(
        error.InvalidQdrantVector,
        buildUpsertPayload(allocator, "42", &[_]f32{std.math.inf(f32)}),
    );

    const payload = try buildUpsertPayload(allocator, "42", &[_]f32{ 0.1, -0.2 });
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"id\":42") != null);
}

test "redactUrlAlloc masks password in authority" {
    const allocator = std.testing.allocator;
    const redacted = try redactUrlAlloc(allocator, "postgres://orion:secret@localhost:5432/qail");
    defer allocator.free(redacted);
    try std.testing.expectEqualStrings("postgres://orion:***@localhost:5432/qail", redacted);
}

test "formatEpochSecondsIso8601Alloc formats unix epoch" {
    const allocator = std.testing.allocator;
    const iso = try formatEpochSecondsIso8601Alloc(allocator, 0);
    defer allocator.free(iso);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", iso);
}
