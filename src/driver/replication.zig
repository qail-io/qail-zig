const std = @import("std");
const row_mod = @import("row.zig");
const io_compat = @import("../runtime/io.zig");

const PgRow = row_mod.PgRow;

pub const MAX_REPLICATION_OPTIONS: usize = 64;
pub const MAX_REPLICATION_OPTION_VALUE_BYTES: usize = 16 * 1024;
pub const MAX_REPLICATION_XLOGDATA_BYTES: usize = 16 * 1024 * 1024;

/// Startup metadata from `IDENTIFY_SYSTEM`.
pub const IdentifySystem = struct {
    system_id: []u8,
    timeline: u32,
    xlog_pos: []u8,
    dbname: ?[]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IdentifySystem) void {
        self.allocator.free(self.system_id);
        self.allocator.free(self.xlog_pos);
        if (self.dbname) |dbname| self.allocator.free(dbname);
    }
};

/// Output from `CREATE_REPLICATION_SLOT ... LOGICAL ...`.
pub const ReplicationSlotInfo = struct {
    slot_name: []u8,
    consistent_point: []u8,
    snapshot_name: ?[]u8,
    output_plugin: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplicationSlotInfo) void {
        self.allocator.free(self.slot_name);
        self.allocator.free(self.consistent_point);
        if (self.snapshot_name) |snapshot_name| self.allocator.free(snapshot_name);
        self.allocator.free(self.output_plugin);
    }
};

/// Logical replication option (`k 'v'`) used by START_REPLICATION.
pub const ReplicationOption = struct {
    key: []const u8,
    value: []const u8,
};

/// Metadata returned by START_REPLICATION CopyBoth response.
pub const ReplicationStreamStart = struct {
    format: u8,
    column_formats: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplicationStreamStart) void {
        self.allocator.free(self.column_formats);
    }
};

/// Replication XLogData message (`CopyData('w'...)`).
pub const ReplicationXLogData = struct {
    wal_start: u64,
    wal_end: u64,
    server_time_micros: i64,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplicationXLogData) void {
        self.allocator.free(self.data);
    }
};

/// Primary keepalive message (`CopyData('k'...)`).
pub const ReplicationKeepalive = struct {
    wal_end: u64,
    server_time_micros: i64,
    reply_requested: bool,
};

/// Replication stream message parsed from CopyData payload.
pub const ReplicationStreamMessage = union(enum) {
    xlog_data: ReplicationXLogData,
    keepalive: ReplicationKeepalive,
    raw: struct {
        tag: u8,
        payload: []u8,
        allocator: std.mem.Allocator,
    },

    pub fn deinit(self: *ReplicationStreamMessage) void {
        switch (self.*) {
            .xlog_data => |*x| x.deinit(),
            .keepalive => {},
            .raw => |r| r.allocator.free(r.payload),
        }
    }
};

pub fn parseLsnText(lsn: []const u8) !u64 {
    const slash = std.mem.indexOfScalar(u8, lsn, '/') orelse return error.InvalidLsn;
    if (slash == 0 or slash == lsn.len - 1) return error.InvalidLsn;
    if (std.mem.indexOfScalarPos(u8, lsn, slash + 1, '/') != null) return error.InvalidLsn;

    const high = std.fmt.parseInt(u32, lsn[0..slash], 16) catch return error.InvalidLsn;
    const low = std.fmt.parseInt(u32, lsn[slash + 1 ..], 16) catch return error.InvalidLsn;
    return (@as(u64, high) << 32) | low;
}

pub fn buildCreateLogicalReplicationSlotSql(
    allocator: std.mem.Allocator,
    slot_name: []const u8,
    output_plugin: []const u8,
    temporary: bool,
    two_phase: bool,
) ![]u8 {
    try validateIdent("slot_name", slot_name);
    try validateIdent("output_plugin", output_plugin);

    var sql: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator, "CREATE_REPLICATION_SLOT ");
    try sql.appendSlice(allocator, slot_name);
    if (temporary) try sql.appendSlice(allocator, " TEMPORARY");
    try sql.appendSlice(allocator, " LOGICAL ");
    try sql.appendSlice(allocator, output_plugin);
    if (two_phase) try sql.appendSlice(allocator, " TWO_PHASE");

    return try sql.toOwnedSlice(allocator);
}

pub fn buildDropReplicationSlotSql(
    allocator: std.mem.Allocator,
    slot_name: []const u8,
    wait: bool,
) ![]u8 {
    try validateIdent("slot_name", slot_name);

    var sql: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator, "DROP_REPLICATION_SLOT ");
    try sql.appendSlice(allocator, slot_name);
    if (wait) try sql.appendSlice(allocator, " WAIT");
    return try sql.toOwnedSlice(allocator);
}

pub fn buildStartLogicalReplicationSql(
    allocator: std.mem.Allocator,
    slot_name: []const u8,
    start_lsn: []const u8,
    options: []const ReplicationOption,
) ![]u8 {
    try validateIdent("slot_name", slot_name);
    _ = try parseLsnText(start_lsn);

    if (options.len > MAX_REPLICATION_OPTIONS) return error.InvalidReplicationOption;

    var sql: std.ArrayListUnmanaged(u8) = .empty;
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator, "START_REPLICATION SLOT ");
    try sql.appendSlice(allocator, slot_name);
    try sql.appendSlice(allocator, " LOGICAL ");
    try sql.appendSlice(allocator, start_lsn);

    if (options.len != 0) {
        try sql.appendSlice(allocator, " (");
        for (options, 0..) |opt, i| {
            try validateIdent("replication option key", opt.key);
            if (opt.value.len > MAX_REPLICATION_OPTION_VALUE_BYTES) return error.InvalidReplicationOption;

            if (i > 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, opt.key);
            try sql.append(allocator, ' ');

            const literal = try quoteReplicationOptionLiteralAlloc(allocator, opt.value);
            defer allocator.free(literal);
            try sql.appendSlice(allocator, literal);
        }
        try sql.append(allocator, ')');
    }

    return try sql.toOwnedSlice(allocator);
}

pub fn parseIdentifySystemRow(allocator: std.mem.Allocator, row: *const PgRow) !IdentifySystem {
    const system_id_raw = row.getString(0) orelse return error.InvalidReplicationResponse;
    const timeline_raw = row.getString(1) orelse return error.InvalidReplicationResponse;
    const xlog_pos_raw = row.getString(2) orelse return error.InvalidReplicationResponse;

    const timeline = std.fmt.parseInt(u32, timeline_raw, 10) catch return error.InvalidReplicationResponse;
    const system_id = try allocator.dupe(u8, system_id_raw);
    errdefer allocator.free(system_id);
    const xlog_pos = try allocator.dupe(u8, xlog_pos_raw);
    errdefer allocator.free(xlog_pos);

    var dbname: ?[]u8 = null;
    if (row.getString(3)) |dbname_raw| {
        if (dbname_raw.len != 0) {
            dbname = try allocator.dupe(u8, dbname_raw);
        }
    }

    return .{
        .system_id = system_id,
        .timeline = timeline,
        .xlog_pos = xlog_pos,
        .dbname = dbname,
        .allocator = allocator,
    };
}

pub fn parseCreateSlotRow(allocator: std.mem.Allocator, row: *const PgRow) !ReplicationSlotInfo {
    const slot_name_raw = row.getString(0) orelse return error.InvalidReplicationResponse;
    const consistent_point_raw = row.getString(1) orelse return error.InvalidReplicationResponse;
    const output_plugin_raw = row.getString(3) orelse return error.InvalidReplicationResponse;

    const slot_name = try allocator.dupe(u8, slot_name_raw);
    errdefer allocator.free(slot_name);
    const consistent_point = try allocator.dupe(u8, consistent_point_raw);
    errdefer allocator.free(consistent_point);
    const output_plugin = try allocator.dupe(u8, output_plugin_raw);
    errdefer allocator.free(output_plugin);

    var snapshot_name: ?[]u8 = null;
    if (row.getString(2)) |snapshot_name_raw| {
        if (snapshot_name_raw.len != 0) {
            snapshot_name = try allocator.dupe(u8, snapshot_name_raw);
        }
    }

    return .{
        .slot_name = slot_name,
        .consistent_point = consistent_point,
        .snapshot_name = snapshot_name,
        .output_plugin = output_plugin,
        .allocator = allocator,
    };
}

pub fn parseReplicationCopyData(allocator: std.mem.Allocator, payload: []const u8) !ReplicationStreamMessage {
    if (payload.len == 0) return error.InvalidReplicationCopyData;

    switch (payload[0]) {
        'w' => {
            if (payload.len < 25) return error.InvalidReplicationCopyData;

            const wal_start = std.mem.readInt(u64, payload[1..9], .big);
            const wal_end = std.mem.readInt(u64, payload[9..17], .big);
            const server_time_micros = std.mem.readInt(i64, payload[17..25], .big);

            if (wal_end < wal_start) return error.InvalidReplicationCopyData;

            const data_len = payload.len - 25;
            if (data_len > MAX_REPLICATION_XLOGDATA_BYTES) return error.InvalidReplicationCopyData;

            return .{ .xlog_data = .{
                .wal_start = wal_start,
                .wal_end = wal_end,
                .server_time_micros = server_time_micros,
                .data = try allocator.dupe(u8, payload[25..]),
                .allocator = allocator,
            } };
        },
        'k' => {
            if (payload.len != 18) return error.InvalidReplicationCopyData;

            const wal_end = std.mem.readInt(u64, payload[1..9], .big);
            const server_time_micros = std.mem.readInt(i64, payload[9..17], .big);
            const reply_requested = switch (payload[17]) {
                0 => false,
                1 => true,
                else => return error.InvalidReplicationCopyData,
            };

            return .{ .keepalive = .{
                .wal_end = wal_end,
                .server_time_micros = server_time_micros,
                .reply_requested = reply_requested,
            } };
        },
        else => {
            return .{ .raw = .{
                .tag = payload[0],
                .payload = try allocator.dupe(u8, payload[1..]),
                .allocator = allocator,
            } };
        },
    }
}

pub fn buildStandbyStatusUpdatePayload(
    write_lsn: u64,
    flush_lsn: u64,
    apply_lsn: u64,
    reply_requested: bool,
) [34]u8 {
    var payload: [34]u8 = undefined;
    payload[0] = 'r';
    std.mem.writeInt(u64, payload[1..9], write_lsn, .big);
    std.mem.writeInt(u64, payload[9..17], flush_lsn, .big);
    std.mem.writeInt(u64, payload[17..25], apply_lsn, .big);
    std.mem.writeInt(i64, payload[25..33], postgresEpochMicrosNow(), .big);
    payload[33] = if (reply_requested) 1 else 0;
    return payload;
}

pub fn sendCopyData(conn: anytype, data: []const u8) !void {
    if (data.len > std.math.maxInt(i32) - 4) return error.CopyDataTooLarge;
    const len: u32 = @intCast(data.len + 4);
    var header: [5]u8 = undefined;
    header[0] = 'd';
    std.mem.writeInt(u32, header[1..5], len, .big);
    try conn.send(&header);
    try conn.send(data);
}

fn validateIdent(kind: []const u8, ident: []const u8) !void {
    if (ident.len == 0) return error.InvalidIdentifier;
    if (ident.len > 63) return error.InvalidIdentifier;

    const first = ident[0];
    if (!(first == '_' or std.ascii.isAlphabetic(first))) return error.InvalidIdentifier;

    for (ident[1..]) |ch| {
        if (!(ch == '_' or std.ascii.isAlphanumeric(ch))) return error.InvalidIdentifier;
    }

    _ = kind;
}

fn quoteReplicationOptionLiteralAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidReplicationOption;

    if (std.mem.indexOfScalar(u8, value, '\\') != null) {
        return try quoteDollarLiteralAlloc(allocator, value, "qail_repl");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');

    return try out.toOwnedSlice(allocator);
}

fn quoteDollarLiteralAlloc(
    allocator: std.mem.Allocator,
    value: []const u8,
    base_tag: []const u8,
) ![]u8 {
    var idx: usize = 0;
    while (idx <= value.len) : (idx += 1) {
        const tag = if (idx == 0)
            try allocator.dupe(u8, base_tag)
        else
            try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base_tag, idx });
        defer allocator.free(tag);

        const delimiter = try std.fmt.allocPrint(allocator, "${s}$", .{tag});
        defer allocator.free(delimiter);

        if (std.mem.indexOf(u8, value, delimiter) != null) continue;
        return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ delimiter, value, delimiter });
    }

    return error.InvalidReplicationOption;
}

fn postgresEpochMicrosNow() i64 {
    const pg_unix_epoch_diff_secs: i64 = 946_684_800;
    const now_us = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMicroseconds();
    return now_us - (pg_unix_epoch_diff_secs * 1_000_000);
}

test "parse lsn text" {
    const lsn = try parseLsnText("16/B6C50");
    try std.testing.expectEqual(@as(u64, 0x00000016000B6C50), lsn);
}

test "build start logical replication sql" {
    const sql = try buildStartLogicalReplicationSql(
        std.testing.allocator,
        "slot_main",
        "0/16B6C50",
        &.{
            .{ .key = "proto_version", .value = "1" },
            .{ .key = "publication_names", .value = "pub1,pub2" },
        },
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "START_REPLICATION SLOT slot_main LOGICAL 0/16B6C50 (proto_version '1', publication_names 'pub1,pub2')",
        sql,
    );
}

test "build start logical replication sql dollar quotes backslash option values" {
    const sql = try buildStartLogicalReplicationSql(
        std.testing.allocator,
        "slot_main",
        "0/16B6C50",
        &.{
            .{ .key = "publication_names", .value = "pub\\one" },
        },
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "START_REPLICATION SLOT slot_main LOGICAL 0/16B6C50 (publication_names $qail_repl$pub\\one$qail_repl$)",
        sql,
    );
}

test "build start logical replication sql avoids dollar quote delimiter collisions" {
    const sql = try buildStartLogicalReplicationSql(
        std.testing.allocator,
        "slot_main",
        "0/16B6C50",
        &.{
            .{ .key = "publication_names", .value = "pub $qail_repl$ \\ one" },
        },
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "START_REPLICATION SLOT slot_main LOGICAL 0/16B6C50 (publication_names $qail_repl_1$pub $qail_repl$ \\ one$qail_repl_1$)",
        sql,
    );
}

test "parse replication copy data" {
    var payload: [25 + 3]u8 = undefined;
    payload[0] = 'w';
    std.mem.writeInt(u64, payload[1..9], 0x10, .big);
    std.mem.writeInt(u64, payload[9..17], 0x20, .big);
    std.mem.writeInt(i64, payload[17..25], 1234, .big);
    payload[25] = 'a';
    payload[26] = 'b';
    payload[27] = 'c';

    var msg = try parseReplicationCopyData(std.testing.allocator, &payload);
    defer msg.deinit();

    switch (msg) {
        .xlog_data => |x| {
            try std.testing.expectEqual(@as(u64, 0x10), x.wal_start);
            try std.testing.expectEqual(@as(u64, 0x20), x.wal_end);
            try std.testing.expectEqual(@as(i64, 1234), x.server_time_micros);
            try std.testing.expectEqualStrings("abc", x.data);
        },
        else => return error.TestExpectedEqual,
    }
}

test "sendCopyData rejects oversized payload" {
    const MockConn = struct {
        send_count: usize = 0,

        pub fn send(self: *@This(), bytes: []const u8) !void {
            _ = bytes;
            self.send_count += 1;
        }
    };

    var conn = MockConn{};
    const too_large_len = @as(usize, std.math.maxInt(i32)) - 3;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.CopyDataTooLarge, sendCopyData(&conn, payload));
    try std.testing.expectEqual(@as(usize, 0), conn.send_count);
}
