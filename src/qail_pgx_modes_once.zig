//! One-shot QAIL Zig benchmark runner for comparison against qail-rs and pgx.
//!
//! Compile directly with:
//!   zig build-exe src/qail_pgx_modes_once.zig -O ReleaseFast -femit-bin=/tmp/qail_zig_modes_once
//!
//! On macOS 26 hosts, clamp the target to an older SDK floor to avoid the
//! current Zig build-runner/linker failure:
//!   zig build-exe src/qail_pgx_modes_once.zig -target aarch64-macos.15.0 -O ReleaseFast -femit-bin=/tmp/qail_zig_modes_once

const std = @import("std");
const process_compat = @import("compat/process.zig");
const time = @import("compat/time.zig");
const Connection = @import("driver/connection.zig").Connection;
const pool_mod = @import("driver/pool.zig");
const protocol = @import("protocol/mod.zig");

const PgPool = pool_mod.PgPool;
const PoolConfig = pool_mod.PoolConfig;
const Encoder = protocol.Encoder;

const HOST = "127.0.0.1";
const USER = "orion";
const DATABASE = "example_staging";
const SQL_BY_ID = "SELECT id, name FROM harbors WHERE id = $1";
const PORT: u16 = 5432;
const POOL_SIZE: usize = 10;
const INT4_OID: u32 = 23;
const STMT_NAME = "qail_zig_modes_stmt";

const Mode = enum {
    single,
    pipeline,
    pool10,

    fn parse(input: []const u8) ?Mode {
        if (std.mem.eql(u8, input, "single")) return .single;
        if (std.mem.eql(u8, input, "pipeline")) return .pipeline;
        if (std.mem.eql(u8, input, "pool10") or std.mem.eql(u8, input, "pool")) return .pool10;
        return null;
    }
};

const Workload = enum {
    point,
    wide_rows,
    many_params,

    fn parse(input: []const u8) ?Workload {
        if (std.mem.eql(u8, input, "point") or std.mem.eql(u8, input, "lookup")) return .point;
        if (std.mem.eql(u8, input, "wide_rows") or std.mem.eql(u8, input, "wide")) return .wide_rows;
        if (std.mem.eql(u8, input, "many_params") or std.mem.eql(u8, input, "params")) return .many_params;
        return null;
    }
};

const ResultMode = enum {
    complete_only,
    scalar_int,
    wide_rows,
};

const ParamSet = []const ?[]const u8;

const BatchStats = struct {
    completed: usize = 0,
    rows: usize = 0,
    bytes: usize = 0,
    checksum: u64 = 0,

    fn add(self: *BatchStats, other: BatchStats) void {
        self.completed += other.completed;
        self.rows += other.rows;
        self.bytes += other.bytes;
        self.checksum +%= other.checksum;
    }
};

const BenchmarkResult = struct {
    qps: f64,
    rows_per_sec: ?f64 = null,
    mib_per_sec: ?f64 = null,
    checksum: u64 = 0,
};

const WorkloadSpec = struct {
    workload: Workload,
    name: []const u8,
    sql: []const u8,
    param_types: []const u32,
    total_queries: usize,
    iterations: usize,
    result_mode: ResultMode,
};

const POINT_TOTAL_QUERIES: usize = 10_000;
const POINT_ITERATIONS: usize = 5;
const WIDE_ROWS_TOTAL_QUERIES: usize = 100;
const WIDE_ROWS_ITERATIONS: usize = 3;
const MANY_PARAMS_TOTAL_QUERIES: usize = 5_000;
const MANY_PARAMS_ITERATIONS: usize = 5;
const WIDE_ROWS_SQL =
    "SELECT gs AS id, " ++
    "('harbor-' || gs)::text AS name, " ++
    "repeat(md5(gs::text), 4) AS bio, " ++
    "repeat(md5((gs * 17)::text), 3) AS region, " ++
    "(gs * 11) AS visits, " ++
    "(gs % 2 = 0) AS active, " ++
    "round((gs::numeric / 7.0), 3) AS ratio, " ++
    "CASE WHEN gs % 5 = 0 THEN NULL ELSE repeat(md5((gs * 3)::text), 2) END AS optional_note " ++
    "FROM generate_series(1, $1::int) AS gs";
const MANY_PARAMS_PARAM_COUNT: usize = 32;
const MANY_PARAMS_SQL = buildManyParamsSql();
const MANY_PARAMS_PARAM_TYPES = buildManyParamsOids();

fn workloadSpec(workload: Workload) WorkloadSpec {
    return switch (workload) {
        .point => .{
            .workload = .point,
            .name = "point",
            .sql = SQL_BY_ID,
            .param_types = &.{INT4_OID},
            .total_queries = POINT_TOTAL_QUERIES,
            .iterations = POINT_ITERATIONS,
            .result_mode = .complete_only,
        },
        .wide_rows => .{
            .workload = .wide_rows,
            .name = "wide_rows",
            .sql = WIDE_ROWS_SQL,
            .param_types = &.{INT4_OID},
            .total_queries = WIDE_ROWS_TOTAL_QUERIES,
            .iterations = WIDE_ROWS_ITERATIONS,
            .result_mode = .wide_rows,
        },
        .many_params => .{
            .workload = .many_params,
            .name = "many_params",
            .sql = MANY_PARAMS_SQL,
            .param_types = MANY_PARAMS_PARAM_TYPES[0..],
            .total_queries = MANY_PARAMS_TOTAL_QUERIES,
            .iterations = MANY_PARAMS_ITERATIONS,
            .result_mode = .scalar_int,
        },
    };
}

const PoolSync = struct {
    ready_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

const WorkerResult = struct {
    err: ?anyerror = null,
    stats: BatchStats = .{},
};

const PoolWorkerCtx = struct {
    pool: *PgPool,
    sync: *PoolSync,
    spec: WorkloadSpec,
    params: []const ParamSet,
    result: *WorkerResult,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const args = try process_compat.argsAlloc(allocator);

    var mode: ?Mode = null;
    var workload: Workload = .point;
    var plain = false;
    var expect_workload_value = false;

    for (args[1..]) |arg| {
        if (expect_workload_value) {
            workload = Workload.parse(arg) orelse usageAndExit("unknown workload");
            expect_workload_value = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--workload") or std.mem.eql(u8, arg, "--scenario")) {
            expect_workload_value = true;
            continue;
        }
        if (mode == null) {
            mode = Mode.parse(arg);
            if (mode == null) usageAndExit("unknown mode");
            continue;
        }
        usageAndExit("unexpected argument");
    }
    if (expect_workload_value) usageAndExit("missing workload value");

    const selected_mode = mode orelse usageAndExit("missing mode argument");
    const spec = workloadSpec(workload);
    const params = try buildParamBatch(allocator, spec);

    const result = switch (selected_mode) {
        .single => try runSingleMode(spec, params),
        .pipeline => try runPipelineMode(spec, params),
        .pool10 => try runPool10Mode(spec, params),
    };

    if (plain) {
        try stdout.print("{d:.3}\n", .{result.qps});
    } else {
        try stdout.print("qail-zig {s}/{s}: {d:.0} q/s", .{ @tagName(selected_mode), spec.name, result.qps });
        if (result.rows_per_sec) |rows_per_sec| {
            try stdout.print(" | {d:.0} rows/s", .{rows_per_sec});
        }
        if (result.mib_per_sec) |mib_per_sec| {
            try stdout.print(" | {d:.2} MiB/s", .{mib_per_sec});
        }
        if (spec.result_mode != .complete_only) {
            try stdout.print(" | checksum=0x{x}", .{result.checksum});
        }
        try stdout.writeByte('\n');
    }
}

fn usageAndExit(reason: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{reason});
    std.debug.print(
        "Usage: qail_pgx_modes_once <single|pipeline|pool10> [--workload point|wide_rows|many_params] [--plain]\n",
        .{},
    );
    std.process.exit(1);
}

fn buildParamBatch(allocator: std.mem.Allocator, spec: WorkloadSpec) ![]ParamSet {
    return switch (spec.workload) {
        .point => buildPointParams(allocator, spec.total_queries),
        .wide_rows => buildWideRowsParams(allocator, spec.total_queries),
        .many_params => buildManyParamsBatch(allocator, spec.total_queries),
    };
}

fn buildPointParams(allocator: std.mem.Allocator, total: usize) ![]ParamSet {
    const params = try allocator.alloc(ParamSet, total);
    for (params, 0..) |*slot, i| {
        const id = (i % 10_000) + 1;
        const inner = try allocator.alloc(?[]const u8, 1);
        inner[0] = try std.fmt.allocPrint(allocator, "{d}", .{id});
        slot.* = inner;
    }
    return params;
}

fn buildWideRowsParams(allocator: std.mem.Allocator, total: usize) ![]ParamSet {
    const params = try allocator.alloc(ParamSet, total);
    const row_counts = [_][]const u8{ "128", "256", "384", "512" };
    for (params, 0..) |*slot, i| {
        const inner = try allocator.alloc(?[]const u8, 1);
        inner[0] = row_counts[i % row_counts.len];
        slot.* = inner;
    }
    return params;
}

fn buildManyParamsBatch(allocator: std.mem.Allocator, total: usize) ![]ParamSet {
    const params = try allocator.alloc(ParamSet, total);
    const cache = try allocator.alloc([]const u8, 256);
    for (cache, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(allocator, "{d}", .{i + 1});
    }

    for (params, 0..) |*slot, query_idx| {
        const inner = try allocator.alloc(?[]const u8, MANY_PARAMS_PARAM_COUNT);
        for (0..MANY_PARAMS_PARAM_COUNT) |param_idx| {
            const value_idx = (query_idx + param_idx * 7) % cache.len;
            inner[param_idx] = cache[value_idx];
        }
        slot.* = inner;
    }
    return params;
}

fn runSingleMode(spec: WorkloadSpec, params: []const ParamSet) !BenchmarkResult {
    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);
    try prepareNamedStatement(&conn, STMT_NAME, spec.sql, spec.param_types);

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    const warmup = try runPreparedSingles(&conn, &encoder, STMT_NAME, params, spec.result_mode);
    if (warmup.completed != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..spec.iterations) |_| {
        const start = try time.now();
        const stats = try runPreparedSingles(&conn, &encoder, STMT_NAME, params, spec.result_mode);
        const end = try time.now();
        if (stats.completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
        aggregate.add(stats);
    }

    return makeBenchmarkResult(aggregate, total_ns);
}

fn runPipelineMode(spec: WorkloadSpec, params: []const ParamSet) !BenchmarkResult {
    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);
    try prepareNamedStatement(&conn, STMT_NAME, spec.sql, spec.param_types);

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    const warmup = try runPreparedPipeline(&conn, &encoder, STMT_NAME, params, spec.result_mode);
    if (warmup.completed != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..spec.iterations) |_| {
        const start = try time.now();
        const stats = try runPreparedPipeline(&conn, &encoder, STMT_NAME, params, spec.result_mode);
        const end = try time.now();
        if (stats.completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
        aggregate.add(stats);
    }

    return makeBenchmarkResult(aggregate, total_ns);
}

fn runPool10Mode(spec: WorkloadSpec, params: []const ParamSet) !BenchmarkResult {
    if (params.len % POOL_SIZE != 0) return error.InvalidBenchmarkConfig;

    var pool = try PgPool.init(std.heap.page_allocator, PoolConfig{
        .host = HOST,
        .port = PORT,
        .user = USER,
        .database = DATABASE,
        .max_connections = POOL_SIZE,
        .min_connections = POOL_SIZE,
    });
    defer pool.deinit();

    const per_worker = params.len / POOL_SIZE;

    var sync = PoolSync{};
    var threads: [POOL_SIZE]std.Thread = undefined;
    var contexts: [POOL_SIZE]PoolWorkerCtx = undefined;
    var results: [POOL_SIZE]WorkerResult = undefined;
    for (&results) |*result| result.* = .{};

    var spawned: usize = 0;
    errdefer {
        sync.start_flag.store(true, .release);
        for (threads[0..spawned]) |thread| {
            thread.join();
        }
    }

    for (0..POOL_SIZE) |worker_idx| {
        const start_idx = worker_idx * per_worker;
        contexts[worker_idx] = .{
            .pool = &pool,
            .sync = &sync,
            .spec = spec,
            .params = params[start_idx .. start_idx + per_worker],
            .result = &results[worker_idx],
        };
        threads[worker_idx] = try std.Thread.spawn(.{}, poolWorkerMain, .{&contexts[worker_idx]});
        spawned += 1;
    }

    waitForCounter(&sync.ready_count, POOL_SIZE);
    const start = try time.now();
    sync.start_flag.store(true, .release);
    waitForCounter(&sync.done_count, POOL_SIZE);
    const end = try time.now();

    for (threads) |thread| {
        thread.join();
    }

    for (results) |result| {
        if (result.err) |err| return err;
    }

    var aggregate = BatchStats{};
    for (results) |result| aggregate.add(result.stats);
    return makeBenchmarkResult(aggregate, time.since(end, start));
}

fn poolWorkerMain(ctx: *PoolWorkerCtx) void {
    var local_err: ?anyerror = null;

    var pooled = ctx.pool.acquire() catch |err| {
        local_err = err;
        signalReady(ctx, local_err);
        waitForStart(ctx.sync);
        signalDone(ctx, local_err);
        return;
    };
    defer pooled.release();

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    if (local_err == null) {
        const conn = pooled.get();
        prepareNamedStatement(conn, STMT_NAME, ctx.spec.sql, ctx.spec.param_types) catch |err| {
            local_err = err;
        };
        if (local_err == null) {
            _ = runPreparedSingles(conn, &encoder, STMT_NAME, ctx.params, ctx.spec.result_mode) catch |err| {
                local_err = err;
            };
        }
    }

    signalReady(ctx, local_err);
    waitForStart(ctx.sync);

    if (local_err == null) {
        const conn = pooled.get();
        var measured = BatchStats{};
        for (0..ctx.spec.iterations) |_| {
            const stats = runPreparedSingles(conn, &encoder, STMT_NAME, ctx.params, ctx.spec.result_mode) catch |err| {
                local_err = err;
                break;
            };
            measured.add(stats);
        }
        ctx.result.stats = measured;
    }

    signalDone(ctx, local_err);
}

fn signalReady(ctx: *PoolWorkerCtx, local_err: ?anyerror) void {
    ctx.result.err = local_err;
    _ = ctx.sync.ready_count.fetchAdd(1, .acq_rel);
}

fn signalDone(ctx: *PoolWorkerCtx, local_err: ?anyerror) void {
    ctx.result.err = local_err;
    _ = ctx.sync.done_count.fetchAdd(1, .acq_rel);
}

fn waitForStart(sync: *PoolSync) void {
    while (!sync.start_flag.load(.acquire)) {
        std.Thread.yield() catch std.Thread.sleep(100_000);
    }
}

fn waitForCounter(counter: *std.atomic.Value(usize), expected: usize) void {
    while (counter.load(.acquire) < expected) {
        std.Thread.yield() catch std.Thread.sleep(100_000);
    }
}

fn prepareNamedStatement(conn: *Connection, stmt_name: []const u8, sql: []const u8, param_types: []const u32) !void {
    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    try encoder.encodeParse(stmt_name, sql, param_types);
    try encoder.appendSync();
    try conn.send(encoder.getWritten());

    var saw_parse_complete = false;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .parse_complete => saw_parse_complete = true,
            .ready_for_query => {
                if (!saw_parse_complete) return error.PrepareDidNotComplete;
                return;
            },
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.PrepareError;
            },
            .notice, .parameter_status, .notification => {},
            else => {},
        }
    }
}

fn runPreparedSingles(
    conn: *Connection,
    encoder: *Encoder,
    stmt_name: []const u8,
    params_batch: []const ParamSet,
    result_mode: ResultMode,
) !BatchStats {
    var stats = BatchStats{};
    for (params_batch) |params| {
        encoder.reset();
        try encoder.appendBind("", stmt_name, params);
        try encoder.appendExecute("", 0);
        try encoder.appendSync();
        try conn.send(encoder.getWritten());
        const result = try consumeSingleResult(conn, result_mode);
        stats.add(result);
    }
    return stats;
}

fn runPreparedPipeline(
    conn: *Connection,
    encoder: *Encoder,
    stmt_name: []const u8,
    params_batch: []const ParamSet,
    result_mode: ResultMode,
) !BatchStats {
    encoder.reset();
    for (params_batch) |params| {
        try encoder.appendBind("", stmt_name, params);
        try encoder.appendExecute("", 0);
    }
    try encoder.appendSync();
    try conn.send(encoder.getWritten());
    return try consumePipelineResults(conn, params_batch.len, result_mode);
}

fn consumeSingleResult(conn: *Connection, result_mode: ResultMode) !BatchStats {
    var completed = false;
    var stats = BatchStats{};
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .bind_complete, .row_description, .notice, .parameter_status, .notification => {},
            .data_row => try consumeDataRow(result_mode, msg.payload, &stats),
            .command_complete, .no_data => {
                completed = true;
                stats.completed += 1;
            },
            .ready_for_query => {
                if (!completed) return error.QueryDidNotComplete;
                return stats;
            },
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.QueryError;
            },
            else => {},
        }
    }
}

fn consumePipelineResults(conn: *Connection, expected: usize, result_mode: ResultMode) !BatchStats {
    var stats = BatchStats{};
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .bind_complete, .row_description, .notice, .parameter_status, .notification => {},
            .data_row => try consumeDataRow(result_mode, msg.payload, &stats),
            .command_complete, .no_data => stats.completed += 1,
            .ready_for_query => return stats,
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.QueryError;
            },
            else => {},
        }
        if (stats.completed > expected) return error.UnexpectedCompletionCount;
    }
}

fn drainUntilReady(conn: *Connection) !void {
    while (true) {
        const msg = try conn.readMessage();
        if (msg.msg_type == .ready_for_query) return;
    }
}

fn qpsFrom(total_queries: usize, elapsed_ns: u64) f64 {
    const total = @as(f64, @floatFromInt(total_queries));
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return total / seconds;
}

fn makeBenchmarkResult(stats: BatchStats, elapsed_ns: u64) BenchmarkResult {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return .{
        .qps = qpsFrom(stats.completed, elapsed_ns),
        .rows_per_sec = if (stats.rows > 0) @as(f64, @floatFromInt(stats.rows)) / seconds else null,
        .mib_per_sec = if (stats.bytes > 0) (@as(f64, @floatFromInt(stats.bytes)) / (1024.0 * 1024.0)) / seconds else null,
        .checksum = stats.checksum,
    };
}

fn consumeDataRow(result_mode: ResultMode, payload: []const u8, stats: *BatchStats) !void {
    switch (result_mode) {
        .complete_only => {},
        .scalar_int => try consumeScalarDataRow(payload, stats),
        .wide_rows => try consumeWideDataRow(payload, stats),
    }
}

fn consumeScalarDataRow(payload: []const u8, stats: *BatchStats) !void {
    if (payload.len < 2) return error.InvalidDataRow;

    const column_count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    var first_value: ?[]const u8 = null;

    for (0..column_count) |idx| {
        if (pos + 4 > payload.len) return error.InvalidDataRow;
        const raw_len = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;

        if (raw_len < 0) {
            if (idx == 0) first_value = null;
            continue;
        }

        const len: usize = @intCast(raw_len);
        if (pos + len > payload.len) return error.InvalidDataRow;

        if (idx == 0) {
            first_value = payload[pos .. pos + len];
        }
        pos += len;
    }

    if (pos != payload.len) return error.InvalidDataRow;

    stats.rows += 1;
    if (column_count == 0) return;

    if (first_value) |value| {
        stats.bytes += value.len;
        const parsed = std.fmt.parseInt(i64, value, 10) catch @as(i64, @intCast(value.len));
        stats.checksum +%= @as(u64, @intCast(parsed));
    } else {
        stats.checksum +%= 1;
    }
}

fn consumeWideDataRow(payload: []const u8, stats: *BatchStats) !void {
    if (payload.len < 2) return error.InvalidDataRow;

    const column_count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    var row_hash: u64 = 0xcbf29ce484222325;

    for (0..column_count) |idx| {
        if (pos + 4 > payload.len) return error.InvalidDataRow;
        const raw_len = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;

        if (raw_len < 0) {
            row_hash = mixHash(row_hash, "NULL");
            row_hash +%= idx;
            continue;
        }

        const len: usize = @intCast(raw_len);
        if (pos + len > payload.len) return error.InvalidDataRow;

        const value = payload[pos .. pos + len];
        pos += len;
        stats.bytes += value.len;

        switch (idx) {
            0, 4 => {
                const parsed = std.fmt.parseInt(i64, value, 10) catch @as(i64, @intCast(value.len));
                row_hash +%= @as(u64, @intCast(parsed));
            },
            5 => {
                row_hash +%= if (value.len > 0 and (value[0] == 't' or value[0] == 'T')) 1 else 0;
            },
            6 => {
                const parsed = std.fmt.parseFloat(f64, value) catch 0.0;
                row_hash +%= @as(u64, @intFromFloat(parsed * 1000.0));
            },
            else => {
                row_hash = mixHash(row_hash, value);
            },
        }
    }

    stats.rows += 1;
    stats.checksum +%= row_hash;
}

fn mixHash(seed: u64, bytes: []const u8) u64 {
    var hash = seed;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn buildManyParamsSql() []const u8 {
    comptime var sql: []const u8 = "SELECT ";
    inline for (1..MANY_PARAMS_PARAM_COUNT + 1) |idx| {
        sql = sql ++ std.fmt.comptimePrint("${d}::int", .{idx});
        if (idx != MANY_PARAMS_PARAM_COUNT) {
            sql = sql ++ " + ";
        } else {
            sql = sql ++ " AS total";
        }
    }
    return sql;
}

fn buildManyParamsOids() [MANY_PARAMS_PARAM_COUNT]u32 {
    var types: [MANY_PARAMS_PARAM_COUNT]u32 = undefined;
    for (&types) |*slot| slot.* = INT4_OID;
    return types;
}
