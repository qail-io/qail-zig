//! One-shot QAIL Zig benchmark runner for comparison against qail-rs and pgx.
//!
//! QAIL workloads are authored as native QailCmd ASTs here. The benchmark still
//! uses PostgreSQL prepared statements on the wire, but it does not start from
//! raw SQL literals on the QAIL side.
//!
//! Compile directly with:
//!   zig build-exe src/qail_pgx_modes_once.zig -O ReleaseFast -femit-bin=/tmp/qail_zig_modes_once
//!
//! On macOS 26 hosts, clamp the target to an older SDK floor to avoid the
//! current Zig build-runner/linker failure:
//!   zig build-exe src/qail_pgx_modes_once.zig -target aarch64-macos.15.0 -O ReleaseFast -femit-bin=/tmp/qail_zig_modes_once

const std = @import("std");
const io_compat = @import("runtime/io.zig");
const process_compat = @import("runtime/process.zig");
const time = @import("runtime/time.zig");
const ast = @import("ast/mod.zig");
const Connection = @import("driver/connection.zig").Connection;
const pool_mod = @import("driver/pool.zig");
const protocol = @import("protocol/mod.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const WhereClause = ast.WhereClause;
const OrderBy = ast.OrderBy;
const PgPool = pool_mod.PgPool;
const PoolConfig = pool_mod.PoolConfig;
const Encoder = protocol.Encoder;
const Decoder = protocol.Decoder;
const AstEncoder = protocol.AstEncoder;

const HOST = "127.0.0.1";
const USER = "orion";
const DATABASE = "example_staging";
const PORT: u16 = 5432;
const POOL_SIZE: usize = 10;
const STMT_NAME = "qail_zig_modes_stmt";
const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 1099511628211;
const BENCH_PAYLOAD_TARGET_ROWS: usize = 20_000;
const BENCH_SETUP_LOCK_SQL = "SELECT pg_advisory_lock(60119029)";
const BENCH_SETUP_UNLOCK_SQL = "SELECT pg_advisory_unlock(60119029)";
const CREATE_BENCH_PAYLOAD_SQL =
    "CREATE TABLE IF NOT EXISTS qail_bench_payload (" ++
    "id INTEGER PRIMARY KEY, " ++
    "name TEXT NOT NULL, " ++
    "bio TEXT NOT NULL, " ++
    "region TEXT NOT NULL, " ++
    "visits INTEGER NOT NULL, " ++
    "active BOOLEAN NOT NULL, " ++
    "ratio NUMERIC(12, 3) NOT NULL, " ++
    "optional_note TEXT NULL" ++
    ")";
const MANY_PARAMS_PARAM_COUNT: usize = 32;

const PipelineProfile = struct {
    enabled: bool = false,
    encode_ns: u128 = 0,
    send_ns: u128 = 0,
    consume_ns: u128 = 0,
    calls: usize = 0,
};

var g_pipeline_profile = PipelineProfile{};

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
    large_rows,
    many_params,
    aggregate,

    fn parse(input: []const u8) ?Workload {
        if (std.mem.eql(u8, input, "point") or std.mem.eql(u8, input, "lookup")) return .point;
        if (std.mem.eql(u8, input, "wide_rows") or std.mem.eql(u8, input, "wide")) return .wide_rows;
        if (std.mem.eql(u8, input, "large_rows") or std.mem.eql(u8, input, "large")) return .large_rows;
        if (std.mem.eql(u8, input, "many_params") or std.mem.eql(u8, input, "params")) return .many_params;
        // Legacy aliases (`monster_cte` / `cte`) now route to native AST aggregate workload.
        if (std.mem.eql(u8, input, "aggregate") or std.mem.eql(u8, input, "agg") or std.mem.eql(u8, input, "server_heavy") or std.mem.eql(u8, input, "monster_cte") or std.mem.eql(u8, input, "cte")) return .aggregate;
        return null;
    }
};

const ResultMode = enum {
    complete_only,
    point_rows,
    wide_rows,
    scalar_int,
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
    total_queries: usize,
    iterations: usize,
    result_mode: ResultMode,
    requires_payload: bool,
    requires_many_params: bool,
    cmd: *const QailCmd,
};

const POINT_TOTAL_QUERIES: usize = 10_000;
const POINT_ITERATIONS: usize = 5;
const WIDE_ROWS_TOTAL_QUERIES: usize = 100;
const WIDE_ROWS_ITERATIONS: usize = 3;
const LARGE_ROWS_TOTAL_QUERIES: usize = 20;
const LARGE_ROWS_ITERATIONS: usize = 2;
const MANY_PARAMS_TOTAL_QUERIES: usize = 5_000;
const MANY_PARAMS_ITERATIONS: usize = 5;
const AGGREGATE_TOTAL_QUERIES: usize = 2_000;
const AGGREGATE_ITERATIONS: usize = 3;

const POINT_COLS = [_]Expr{ Expr.col("id"), Expr.col("name") };
const PAYLOAD_COLS = [_]Expr{
    Expr.col("id"),
    Expr.col("name"),
    Expr.col("bio"),
    Expr.col("region"),
    Expr.col("visits"),
    Expr.col("active"),
    Expr.col("ratio"),
    Expr.col("optional_note"),
};
const POINT_WHERE = [_]WhereClause{.{
    .condition = .{ .column = "id", .op = .eq, .value = .{ .param = 1 } },
}};
const PAYLOAD_WHERE = [_]WhereClause{.{
    .condition = .{ .column = "id", .op = .lte, .value = .{ .param = 1 } },
}};
const PAYLOAD_ORDER = [_]OrderBy{.{ .column = "id", .order = .asc }};
const AGGREGATE_COLS = [_]Expr{
    Expr.sum("visits").withAlias("sum_visits"),
    Expr.max("visits").withAlias("max_visits"),
    Expr.count().withAlias("row_count"),
};
const MANY_PARAM_CLAUSES = buildManyParamClauses();
const MANY_PARAM_SELECT = [_]Expr{Expr.count()};

const POINT_CMD = QailCmd.get("harbors")
    .select(&POINT_COLS)
    .where(&POINT_WHERE);

const PAYLOAD_ROWS_CMD = QailCmd.get("qail_bench_payload")
    .select(&PAYLOAD_COLS)
    .where(&PAYLOAD_WHERE)
    .orderBy(&PAYLOAD_ORDER);

const WIDE_ROWS_CMD = PAYLOAD_ROWS_CMD;
const AGGREGATE_CMD = QailCmd.get("qail_bench_payload")
    .select(&AGGREGATE_COLS)
    .where(&PAYLOAD_WHERE);

const MANY_PARAMS_CMD = QailCmd.get("qail_bench_payload")
    .select(&MANY_PARAM_SELECT)
    .where(&MANY_PARAM_CLAUSES);

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

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const args = try init.args.toSlice(allocator);

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
    try ensureWorkloadReady(spec);
    const params = try buildParamBatch(allocator, spec);

    const result = switch (selected_mode) {
        .single => try runSingleMode(spec, params),
        .pipeline => try runPipelineMode(spec, params),
        .pool10 => try runPool10Mode(spec, params),
    };

    if (plain) {
        try stdoutPrint("{d:.3}\n", .{result.qps});
    } else {
        try stdoutPrint("qail-zig(native) {s}/{s}: {d:.0} q/s", .{ @tagName(selected_mode), spec.name, result.qps });
        if (result.rows_per_sec) |rows_per_sec| {
            try stdoutPrint(" | {d:.0} rows/s", .{rows_per_sec});
        }
        if (result.mib_per_sec) |mib_per_sec| {
            try stdoutPrint(" | {d:.2} MiB/s", .{mib_per_sec});
        }
        try stdoutPrint(" | checksum=0x{x}\n", .{result.checksum});
    }
}

fn stdoutPrint(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, fmt, args);
    try io_compat.writeAllStdout(line);
}

fn usageAndExit(reason: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{reason});
    std.debug.print(
        "Usage: qail_pgx_modes_once <single|pipeline|pool10> [--workload point|wide_rows|large_rows|many_params|aggregate] [--plain]\n",
        .{},
    );
    std.process.exit(1);
}

fn workloadSpec(workload: Workload) WorkloadSpec {
    return switch (workload) {
        .point => .{
            .workload = .point,
            .name = "point",
            .total_queries = POINT_TOTAL_QUERIES,
            .iterations = POINT_ITERATIONS,
            .result_mode = .complete_only,
            .requires_payload = false,
            .requires_many_params = false,
            .cmd = &POINT_CMD,
        },
        .wide_rows => .{
            .workload = .wide_rows,
            .name = "wide_rows",
            .total_queries = WIDE_ROWS_TOTAL_QUERIES,
            .iterations = WIDE_ROWS_ITERATIONS,
            .result_mode = .wide_rows,
            .requires_payload = true,
            .requires_many_params = false,
            .cmd = &WIDE_ROWS_CMD,
        },
        .large_rows => .{
            .workload = .large_rows,
            .name = "large_rows",
            .total_queries = LARGE_ROWS_TOTAL_QUERIES,
            .iterations = LARGE_ROWS_ITERATIONS,
            .result_mode = .wide_rows,
            .requires_payload = true,
            .requires_many_params = false,
            .cmd = &PAYLOAD_ROWS_CMD,
        },
        .many_params => .{
            .workload = .many_params,
            .name = "many_params",
            .total_queries = MANY_PARAMS_TOTAL_QUERIES,
            .iterations = MANY_PARAMS_ITERATIONS,
            .result_mode = .scalar_int,
            .requires_payload = true,
            .requires_many_params = false,
            .cmd = &MANY_PARAMS_CMD,
        },
        .aggregate => .{
            .workload = .aggregate,
            .name = "aggregate",
            .total_queries = AGGREGATE_TOTAL_QUERIES,
            .iterations = AGGREGATE_ITERATIONS,
            .result_mode = .scalar_int,
            .requires_payload = true,
            .requires_many_params = false,
            .cmd = &AGGREGATE_CMD,
        },
    };
}

fn buildParamBatch(allocator: std.mem.Allocator, spec: WorkloadSpec) ![]ParamSet {
    return switch (spec.workload) {
        .point => buildPointParams(allocator, spec.total_queries),
        .wide_rows => buildWideRowsParams(allocator, spec.total_queries),
        .large_rows => buildLargeRowsParams(allocator, spec.total_queries),
        .many_params => buildManyParamsBatch(allocator, spec.total_queries),
        .aggregate => buildAggregateParams(allocator, spec.total_queries),
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

fn buildLargeRowsParams(allocator: std.mem.Allocator, total: usize) ![]ParamSet {
    const params = try allocator.alloc(ParamSet, total);
    const row_counts = [_][]const u8{ "10000", "12000", "14000", "16000" };
    for (params, 0..) |*slot, i| {
        const inner = try allocator.alloc(?[]const u8, 1);
        inner[0] = row_counts[i % row_counts.len];
        slot.* = inner;
    }
    return params;
}

fn buildAggregateParams(allocator: std.mem.Allocator, total: usize) ![]ParamSet {
    const params = try allocator.alloc(ParamSet, total);
    const row_counts = [_][]const u8{ "8000", "12000", "16000", "20000" };
    for (params, 0..) |*slot, i| {
        const inner = try allocator.alloc(?[]const u8, 1);
        inner[0] = row_counts[i % row_counts.len];
        slot.* = inner;
    }
    return params;
}

fn buildManyParamsBatch(allocator: std.mem.Allocator, total: usize) ![]ParamSet {
    const cache = try allocator.alloc([]const u8, 256);
    for (cache, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(allocator, "{d}", .{i + 1});
    }

    const params = try allocator.alloc(ParamSet, total);
    for (params, 0..) |*slot, query_idx| {
        const inner = try allocator.alloc(?[]const u8, MANY_PARAMS_PARAM_COUNT);
        for (0..MANY_PARAMS_PARAM_COUNT) |param_idx| {
            const value_idx = (query_idx + (param_idx * 7)) % cache.len;
            inner[param_idx] = cache[value_idx];
        }
        slot.* = inner;
    }
    return params;
}

fn ensureWorkloadReady(spec: WorkloadSpec) !void {
    if (!spec.requires_payload and !spec.requires_many_params) return;

    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);

    try executeSimpleQuery(&conn, BENCH_SETUP_LOCK_SQL);
    errdefer executeSimpleQuery(&conn, BENCH_SETUP_UNLOCK_SQL) catch {};

    if (spec.requires_payload) try ensureBenchPayload(&conn);

    try executeSimpleQuery(&conn, BENCH_SETUP_UNLOCK_SQL);
}

fn ensureBenchPayload(conn: *Connection) !void {
    try executeSimpleQuery(conn, CREATE_BENCH_PAYLOAD_SQL);

    const current_rows = try querySingleInt(conn, "SELECT COALESCE(MAX(id), 0) FROM qail_bench_payload");
    if (current_rows >= BENCH_PAYLOAD_TARGET_ROWS) return;

    const insert_sql = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "INSERT INTO qail_bench_payload " ++
            "(id, name, bio, region, visits, active, ratio, optional_note) " ++
            "SELECT gs, " ++
            "       ('harbor-' || gs)::text, " ++
            "       repeat(md5(gs::text), 4), " ++
            "       repeat(md5((gs * 17)::text), 3), " ++
            "       (gs * 11), " ++
            "       (gs % 2 = 0), " ++
            "       round((gs::numeric / 7.0), 3), " ++
            "       CASE WHEN gs % 5 = 0 THEN NULL ELSE repeat(md5((gs * 3)::text), 2) END " ++
            "FROM generate_series({d}, {d}) AS gs " ++
            "ON CONFLICT (id) DO NOTHING",
        .{ current_rows + 1, BENCH_PAYLOAD_TARGET_ROWS },
    );
    defer std.heap.page_allocator.free(insert_sql);

    try executeSimpleQuery(conn, insert_sql);
    _ = executeSimpleQuery(conn, "ANALYZE qail_bench_payload") catch {};
}

fn executeSimpleQuery(conn: *Connection, sql: []const u8) !void {
    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .command_complete, .row_description, .data_row, .empty_query, .notice, .parameter_status, .notification => {},
            .ready_for_query => {
                var decoder = Decoder.init(msg.payload);
                const tx_status = try decoder.parseReadyForQuery();
                conn.ready = true;
                conn.in_transaction = tx_status == .in_transaction;
                return;
            },
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.SimpleQueryFailed;
            },
            else => {},
        }
    }
}

fn querySingleInt(conn: *Connection, sql: []const u8) !usize {
    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    var value: ?usize = null;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .row_description, .command_complete, .empty_query, .notice, .parameter_status, .notification => {},
            .data_row => {
                if (value == null) value = try parseFirstDataRowUInt(msg.payload);
            },
            .ready_for_query => {
                var decoder = Decoder.init(msg.payload);
                const tx_status = try decoder.parseReadyForQuery();
                conn.ready = true;
                conn.in_transaction = tx_status == .in_transaction;
                return value orelse error.ExpectedScalarResult;
            },
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.SimpleQueryFailed;
            },
            else => {},
        }
    }
}

fn parseFirstDataRowUInt(payload: []const u8) !usize {
    if (payload.len < 2) return error.InvalidDataRow;
    const column_count = std.mem.readInt(u16, payload[0..2], .big);
    if (column_count == 0) return error.InvalidDataRow;

    var pos: usize = 2;
    if (pos + 4 > payload.len) return error.InvalidDataRow;
    const raw_len = std.mem.readInt(i32, payload[pos..][0..4], .big);
    pos += 4;
    if (raw_len < 0) return error.InvalidDataRow;

    const len: usize = @intCast(raw_len);
    if (pos + len > payload.len) return error.InvalidDataRow;
    return std.fmt.parseInt(usize, payload[pos .. pos + len], 10);
}

fn buildManyParamClauses() [MANY_PARAMS_PARAM_COUNT]WhereClause {
    var clauses: [MANY_PARAMS_PARAM_COUNT]WhereClause = undefined;
    inline for (0..MANY_PARAMS_PARAM_COUNT) |idx| {
        clauses[idx] = .{
            .condition = .{
                .column = "id",
                .op = .eq,
                .value = .{ .param = idx + 1 },
            },
            .logical_op = if (idx == 0) .@"and" else .@"or",
        };
    }
    return clauses;
}

fn runSingleMode(spec: WorkloadSpec, params: []const ParamSet) !BenchmarkResult {
    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);
    try prepareNamedAstStatement(&conn, STMT_NAME, spec.cmd, std.heap.page_allocator);

    const wire_batch = try buildPreparedSinglesWireBatch(std.heap.page_allocator, STMT_NAME, params);
    defer freePreparedSinglesWireBatch(std.heap.page_allocator, wire_batch);

    const warmup = try runPreparedSinglesEncoded(&conn, wire_batch, spec.result_mode);
    if (warmup.completed != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..spec.iterations) |_| {
        const start = try time.now();
        const stats = try runPreparedSinglesEncoded(&conn, wire_batch, spec.result_mode);
        const end = try time.now();
        if (stats.completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
        aggregate.add(stats);
    }

    return makeBenchmarkResult(aggregate, total_ns);
}

fn runPipelineMode(spec: WorkloadSpec, params: []const ParamSet) !BenchmarkResult {
    g_pipeline_profile = .{ .enabled = wantPipelineProfile() };
    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);
    try prepareNamedAstStatement(&conn, STMT_NAME, spec.cmd, std.heap.page_allocator);

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    encoder.reset();
    for (params) |param_set| {
        try encoder.appendBind("", STMT_NAME, param_set);
        try encoder.appendExecute("", 0);
    }
    try encoder.appendSync();
    const pipeline_wire = try std.heap.page_allocator.dupe(u8, encoder.getWritten());
    defer std.heap.page_allocator.free(pipeline_wire);

    const warmup = try runPreparedPipelineEncoded(&conn, pipeline_wire, params.len, spec.result_mode);
    if (warmup.completed != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..spec.iterations) |_| {
        const start = try time.now();
        const stats = try runPreparedPipelineEncoded(&conn, pipeline_wire, params.len, spec.result_mode);
        const end = try time.now();
        if (stats.completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
        aggregate.add(stats);
    }

    if (g_pipeline_profile.enabled and g_pipeline_profile.calls > 0) {
        const calls_f = @as(f64, @floatFromInt(g_pipeline_profile.calls));
        const enc = @as(f64, @floatFromInt(g_pipeline_profile.encode_ns)) / calls_f / 1_000_000.0;
        const snd = @as(f64, @floatFromInt(g_pipeline_profile.send_ns)) / calls_f / 1_000_000.0;
        const cns = @as(f64, @floatFromInt(g_pipeline_profile.consume_ns)) / calls_f / 1_000_000.0;
        std.debug.print(
            "pipeline split avg/call: encode={d:.3}ms send={d:.3}ms consume={d:.3}ms calls={d}\n",
            .{ enc, snd, cns, g_pipeline_profile.calls },
        );
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

    for (threads) |thread| thread.join();
    for (results) |result| {
        if (result.err) |err| return err;
    }

    var aggregate = BatchStats{};
    for (results) |result| aggregate.add(result.stats);
    return makeBenchmarkResult(aggregate, time.since(end, start));
}

fn poolWorkerMain(ctx: *PoolWorkerCtx) void {
    var local_err: ?anyerror = null;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const worker_allocator = arena_state.allocator();

    var pooled = ctx.pool.acquire() catch |err| {
        local_err = err;
        signalReady(ctx, local_err);
        waitForStart(ctx.sync);
        signalDone(ctx, local_err);
        return;
    };
    defer pooled.release();

    if (local_err == null) {
        const conn = pooled.get();
        prepareNamedAstStatement(conn, STMT_NAME, ctx.spec.cmd, worker_allocator) catch |err| {
            local_err = err;
        };
        if (local_err == null) {
            const wire_batch = buildPreparedSinglesWireBatch(worker_allocator, STMT_NAME, ctx.params) catch |err| {
                local_err = err;
                signalReady(ctx, local_err);
                waitForStart(ctx.sync);
                signalDone(ctx, local_err);
                return;
            };

            _ = runPreparedSinglesEncoded(conn, wire_batch, ctx.spec.result_mode) catch |err| {
                local_err = err;
            };

            signalReady(ctx, local_err);
            waitForStart(ctx.sync);

            if (local_err == null) {
                var measured = BatchStats{};
                for (0..ctx.spec.iterations) |_| {
                    const stats = runPreparedSinglesEncoded(conn, wire_batch, ctx.spec.result_mode) catch |err| {
                        local_err = err;
                        break;
                    };
                    measured.add(stats);
                }
                ctx.result.stats = measured;
            }

            signalDone(ctx, local_err);
            return;
        }
    }

    signalReady(ctx, local_err);
    waitForStart(ctx.sync);
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
        std.Io.sleep(io_compat.runtimeIo(), std.Io.Duration.fromMicroseconds(100), .awake) catch {
            std.Thread.yield() catch {};
        };
    }
}

fn waitForCounter(counter: *std.atomic.Value(usize), expected: usize) void {
    while (counter.load(.acquire) < expected) {
        std.Io.sleep(io_compat.runtimeIo(), std.Io.Duration.fromMicroseconds(100), .awake) catch {
            std.Thread.yield() catch {};
        };
    }
}

fn prepareNamedAstStatement(
    conn: *Connection,
    stmt_name: []const u8,
    cmd: *const QailCmd,
    allocator: std.mem.Allocator,
) !void {
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();

    try encoder.encodePrepare(stmt_name, cmd);
    try conn.send(encoder.getWritten());

    var saw_parse_complete = false;
    while (true) {
        const msg_type = try conn.readMessageTypeFast();
        switch (msg_type) {
            '1' => saw_parse_complete = true,
            'Z' => {
                if (!saw_parse_complete) return error.PrepareDidNotComplete;
                return;
            },
            'E' => {
                _ = drainUntilReadyFast(conn) catch {};
                return error.PrepareError;
            },
            'N', 'S', 'A' => {},
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

fn runPreparedSinglesEncoded(
    conn: *Connection,
    wire_batch: []const []const u8,
    result_mode: ResultMode,
) !BatchStats {
    var stats = BatchStats{};
    for (wire_batch) |wire_bytes| {
        try conn.send(wire_bytes);
        const result = try consumeSingleResult(conn, result_mode);
        stats.add(result);
    }
    return stats;
}

fn buildPreparedSinglesWireBatch(
    allocator: std.mem.Allocator,
    stmt_name: []const u8,
    params_batch: []const ParamSet,
) ![][]u8 {
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    const wires = try allocator.alloc([]u8, params_batch.len);
    var written: usize = 0;
    errdefer {
        for (wires[0..written]) |wire| allocator.free(wire);
        allocator.free(wires);
    }

    for (params_batch, 0..) |params, idx| {
        encoder.reset();
        try encoder.appendBind("", stmt_name, params);
        try encoder.appendExecute("", 0);
        try encoder.appendSync();
        wires[idx] = try allocator.dupe(u8, encoder.getWritten());
        written = idx + 1;
    }

    return wires;
}

fn freePreparedSinglesWireBatch(allocator: std.mem.Allocator, wire_batch: [][]u8) void {
    for (wire_batch) |wire| allocator.free(wire);
    allocator.free(wire_batch);
}

fn runPreparedPipeline(
    conn: *Connection,
    encoder: *Encoder,
    stmt_name: []const u8,
    params_batch: []const ParamSet,
    result_mode: ResultMode,
) !BatchStats {
    var t0: time.Instant = undefined;
    if (g_pipeline_profile.enabled) t0 = try time.now();

    encoder.reset();
    for (params_batch) |params| {
        try encoder.appendBind("", stmt_name, params);
        try encoder.appendExecute("", 0);
    }
    try encoder.appendSync();

    var t1: time.Instant = t0;
    if (g_pipeline_profile.enabled) {
        t1 = try time.now();
        g_pipeline_profile.encode_ns += @as(u128, @intCast(time.since(t1, t0)));
    }

    try conn.send(encoder.getWritten());

    var t2: time.Instant = t1;
    if (g_pipeline_profile.enabled) {
        t2 = try time.now();
        g_pipeline_profile.send_ns += @as(u128, @intCast(time.since(t2, t1)));
    }

    const stats = try consumePipelineResults(conn, params_batch.len, result_mode);
    if (g_pipeline_profile.enabled) {
        const t3 = try time.now();
        g_pipeline_profile.consume_ns += @as(u128, @intCast(time.since(t3, t2)));
        g_pipeline_profile.calls += 1;
    }
    return stats;
}

fn runPreparedPipelineEncoded(
    conn: *Connection,
    wire_bytes: []const u8,
    expected: usize,
    result_mode: ResultMode,
) !BatchStats {
    var t2: time.Instant = undefined;
    if (g_pipeline_profile.enabled) t2 = try time.now();

    try conn.send(wire_bytes);

    var t3: time.Instant = t2;
    if (g_pipeline_profile.enabled) {
        t3 = try time.now();
        g_pipeline_profile.send_ns += @as(u128, @intCast(time.since(t3, t2)));
    }

    const stats = try consumePipelineResults(conn, expected, result_mode);
    if (g_pipeline_profile.enabled) {
        const t4 = try time.now();
        g_pipeline_profile.consume_ns += @as(u128, @intCast(time.since(t4, t3)));
        g_pipeline_profile.calls += 1;
    }
    return stats;
}

fn consumeSingleResult(conn: *Connection, result_mode: ResultMode) !BatchStats {
    if (result_mode == .complete_only) {
        return consumeSingleResultCompleteOnly(conn);
    }

    var completed = false;
    var stats = BatchStats{};
    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            '2', 'T', 'N', 'S', 'A' => {},
            'D' => try consumeDataRow(result_mode, msg.payload, &stats),
            'C', 'n' => {
                completed = true;
                stats.completed += 1;
            },
            'Z' => {
                if (!completed) return error.QueryDidNotComplete;
                conn.ready = true;
                conn.in_transaction = msg.payload.len > 0 and msg.payload[0] == 'T';
                return stats;
            },
            'E' => {
                _ = drainUntilReadyFast(conn) catch {};
                return error.QueryError;
            },
            else => {},
        }
    }
}

fn consumePipelineResults(conn: *Connection, expected: usize, result_mode: ResultMode) !BatchStats {
    if (result_mode == .complete_only) {
        return consumePipelineResultsCompleteOnly(conn, expected);
    }

    var stats = BatchStats{};
    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            '2', 'T', 'N', 'S', 'A' => {},
            'D' => try consumeDataRow(result_mode, msg.payload, &stats),
            'C', 'n' => stats.completed += 1,
            'Z' => {
                conn.ready = true;
                conn.in_transaction = msg.payload.len > 0 and msg.payload[0] == 'T';
                return stats;
            },
            'E' => {
                _ = drainUntilReadyFast(conn) catch {};
                return error.QueryError;
            },
            else => {},
        }
        if (stats.completed > expected) return error.UnexpectedCompletionCount;
    }
}

fn consumeSingleResultCompleteOnly(conn: *Connection) !BatchStats {
    const result = try conn.countCompletionsUntilReadyFast(1);
    if (result.saw_error) return error.QueryError;
    if (result.completed != 1) return error.QueryDidNotComplete;
    return .{ .completed = 1 };
}

fn consumePipelineResultsCompleteOnly(conn: *Connection, expected: usize) !BatchStats {
    const result = try conn.countCompletionsUntilReadyFast(expected);
    if (result.saw_error) return error.QueryError;
    return .{ .completed = result.completed };
}

fn drainUntilReady(conn: *Connection) !void {
    while (true) {
        const msg = try conn.readMessage();
        if (msg.msg_type == .ready_for_query) return;
    }
}

fn drainUntilReadyFast(conn: *Connection) !void {
    while (true) {
        if (try conn.readMessageTypeFast() == 'Z') return;
    }
}

fn qpsFrom(total_queries: usize, elapsed_ns: u64) f64 {
    const total = @as(f64, @floatFromInt(total_queries));
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return total / seconds;
}

fn wantPipelineProfile() bool {
    const value = process_compat.getEnvVarOwned(std.heap.page_allocator, "QAIL_PROFILE_PIPELINE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return true;
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
        .point_rows => try consumePointDataRow(payload, stats),
        .wide_rows => try consumeWideDataRow(payload, stats),
        .scalar_int => try consumeScalarDataRow(payload, stats),
    }
}

fn consumePointDataRow(payload: []const u8, stats: *BatchStats) !void {
    if (payload.len < 2) return error.InvalidDataRow;

    const column_count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    var row_hash: u64 = FNV_OFFSET;

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
            0 => {
                const parsed = parseAsciiI64OrLen(value);
                row_hash +%= @as(u64, @intCast(parsed));
            },
            else => row_hash = mixHash(row_hash, value),
        }
    }

    if (pos != payload.len) return error.InvalidDataRow;
    stats.rows += 1;
    stats.checksum +%= row_hash;
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
        const parsed = parseAsciiI64OrLen(value);
        stats.checksum +%= @as(u64, @intCast(parsed));
    } else {
        stats.checksum +%= 1;
    }
}

fn consumeWideDataRow(payload: []const u8, stats: *BatchStats) !void {
    if (payload.len < 2) return error.InvalidDataRow;

    const column_count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    var row_hash: u64 = FNV_OFFSET;

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
                const parsed = parseAsciiI64OrLen(value);
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

    if (pos != payload.len) return error.InvalidDataRow;
    stats.rows += 1;
    stats.checksum +%= row_hash;
}

fn parseAsciiI64OrLen(value: []const u8) i64 {
    if (value.len == 0) return 0;

    var idx: usize = 0;
    var negative = false;
    if (value[0] == '-') {
        negative = true;
        idx = 1;
        if (idx == value.len) return @as(i64, @intCast(value.len));
    }

    var acc: i64 = 0;
    while (idx < value.len) : (idx += 1) {
        const c = value[idx];
        if (c < '0' or c > '9') return @as(i64, @intCast(value.len));

        const digit: i64 = @as(i64, @intCast(c - '0'));
        acc = std.math.mul(i64, acc, 10) catch return @as(i64, @intCast(value.len));
        acc = std.math.add(i64, acc, digit) catch return @as(i64, @intCast(value.len));
    }

    return if (negative) -acc else acc;
}

fn mixHash(seed: u64, bytes: []const u8) u64 {
    var hash = seed;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= FNV_PRIME;
    }
    return hash;
}
