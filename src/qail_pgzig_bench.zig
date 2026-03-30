//! Fair qail-zig vs pg.zig benchmark on the shared feature surface.
//!
//! qail-zig workloads are authored as native QailCmd ASTs, compiled once to SQL
//! for statement preparation, and then executed through the low-level prepared
//! protocol path. pg.zig executes the same prepared SQL templates through its
//! cached prepared-query path.
//!
//! Usage:
//!   zig build pgzig-bench -- qail single --workload point --plain
//!   zig build pgzig-bench -- pgzig pool10 --workload wide_rows

const std = @import("std");
const qail = @import("qail");
const pg = @import("pg");

const process_compat = qail.compat.process;
const time = qail.compat.time;

const Connection = qail.driver.Connection;
const PgPool = qail.driver.PgPool;
const PoolConfig = qail.driver.PoolConfig;
const Encoder = qail.protocol.Encoder;
const Expr = qail.Expr;
const QailCmd = qail.QailCmd;
const WhereClause = qail.ast.WhereClause;

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_USER = "orion";
const DEFAULT_DATABASE = "example_staging";
const DEFAULT_PORT: u16 = 5432;
const DEFAULT_PASSWORD: ?[]const u8 = null;
const POOL_SIZE: usize = 10;
const BENCH_TABLE = "zig_pg_driver_bench_payload";
const BENCH_ROW_COUNT: usize = 50_000;
const QAIL_STMT_NAME = "qail_pgzig_bench_stmt";
const PG_CACHE_NAME = "qail_pgzig_bench_stmt";
const INT4_OID: u32 = 23;

const POINT_TOTAL_QUERIES: usize = 20_000;
const POINT_ITERATIONS: usize = 5;
const WIDE_ROWS_TOTAL_QUERIES: usize = 120;
const WIDE_ROWS_ITERATIONS: usize = 3;
const LARGE_ROWS_TOTAL_QUERIES: usize = 40;
const LARGE_ROWS_ITERATIONS: usize = 3;
const MANY_PARAMS_TOTAL_QUERIES: usize = 4_000;
const MANY_PARAMS_ITERATIONS: usize = 4;
const AGGREGATE_TOTAL_QUERIES: usize = 2_000;
const AGGREGATE_ITERATIONS: usize = 4;
const MANY_PARAMS_COUNT: usize = 16;

const Mode = enum {
    single,
    pool10,

    fn parse(input: []const u8) ?Mode {
        if (std.mem.eql(u8, input, "single")) return .single;
        if (std.mem.eql(u8, input, "pool10") or std.mem.eql(u8, input, "pool")) return .pool10;
        return null;
    }
};

const Runner = enum {
    qail,
    pgzig,

    fn parse(input: []const u8) ?Runner {
        if (std.mem.eql(u8, input, "qail") or std.mem.eql(u8, input, "qail-zig")) return .qail;
        if (std.mem.eql(u8, input, "pgzig") or std.mem.eql(u8, input, "pg")) return .pgzig;
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
        if (std.mem.eql(u8, input, "point")) return .point;
        if (std.mem.eql(u8, input, "wide_rows") or std.mem.eql(u8, input, "wide")) return .wide_rows;
        if (std.mem.eql(u8, input, "large_rows") or std.mem.eql(u8, input, "large")) return .large_rows;
        if (std.mem.eql(u8, input, "many_params") or std.mem.eql(u8, input, "params")) return .many_params;
        if (std.mem.eql(u8, input, "aggregate") or std.mem.eql(u8, input, "agg")) return .aggregate;
        return null;
    }
};

const DbConfig = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    database: []const u8,
    password: ?[]const u8 = null,
};

const BenchmarkResult = struct {
    qps: f64,
    rows_per_sec: ?f64 = null,
    mib_per_sec: ?f64 = null,
    checksum: u64 = 0,
};

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

const WorkerSync = struct {
    ready_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

const WorkerResult = struct {
    err: ?anyerror = null,
    stats: BatchStats = .{},
};

const WorkloadSpec = struct {
    name: []const u8,
    total_queries: usize,
    iterations: usize,
    param_types: []const u32,
    cmd: *const QailCmd,
};

fn ParamBatch(comptime N: usize) type {
    return struct {
        pg: [][N]i32,
        qail: [][N]?[]const u8,
    };
}

const ONE_INT_PARAM_TYPES = [_]u32{INT4_OID};
const TWO_INT_PARAM_TYPES = [_]u32{ INT4_OID, INT4_OID };
const MANY_PARAMS_PARAM_TYPES = buildIntParamTypes(MANY_PARAMS_COUNT);

const POINT_COLS = [_]Expr{ Expr.col("id"), Expr.col("name") };
const WIDE_COLS = [_]Expr{
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
const WIDE_WHERE = [_]WhereClause{.{
    .condition = .{ .column = "id", .op = .lte, .value = .{ .param = 1 } },
}};
const WIDE_ORDER = [_]qail.ast.OrderBy{.{ .column = "id", .order = .asc }};
const AGGREGATE_COLS = [_]Expr{
    Expr.count(),
    Expr.sum("visits"),
    Expr.avg("ratio"),
    Expr.max("id"),
};
const AGGREGATE_WHERE = [_]WhereClause{
    .{ .condition = .{ .column = "visits", .op = .gte, .value = .{ .param = 1 } } },
    .{ .condition = .{ .column = "id", .op = .lte, .value = .{ .param = 2 } } },
};
const MANY_PARAM_CLAUSES = buildManyParamClauses();
const MANY_PARAM_SELECT = [_]Expr{Expr.count()};

const POINT_CMD = QailCmd.get(BENCH_TABLE)
    .select(&POINT_COLS)
    .where(&POINT_WHERE);

const RANGE_ROWS_CMD = QailCmd.get(BENCH_TABLE)
    .select(&WIDE_COLS)
    .where(&WIDE_WHERE)
    .orderBy(&WIDE_ORDER);

const AGGREGATE_CMD = QailCmd.get(BENCH_TABLE)
    .select(&AGGREGATE_COLS)
    .where(&AGGREGATE_WHERE);

const MANY_PARAMS_CMD = QailCmd.get(BENCH_TABLE)
    .select(&MANY_PARAM_SELECT)
    .where(MANY_PARAM_CLAUSES[0..]);

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const args = try process_compat.argsAlloc(allocator);

    var runner: ?Runner = null;
    var mode: ?Mode = null;
    var workload: Workload = .point;
    var plain = false;
    var expect_workload = false;

    for (args[1..]) |arg| {
        if (expect_workload) {
            workload = Workload.parse(arg) orelse usageAndExit("unknown workload");
            expect_workload = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--workload")) {
            expect_workload = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
            continue;
        }
        if (runner == null) {
            runner = Runner.parse(arg);
            if (runner == null) usageAndExit("unknown runner");
            continue;
        }
        if (mode == null) {
            mode = Mode.parse(arg);
            if (mode == null) usageAndExit("unknown mode");
            continue;
        }
        usageAndExit("unexpected argument");
    }
    if (expect_workload) usageAndExit("missing workload value");

    const selected_runner = runner orelse usageAndExit("missing runner");
    const selected_mode = mode orelse usageAndExit("missing mode");
    const db = try loadDbConfig(allocator);
    try ensureBenchmarkData(allocator, db);

    const result = switch (workload) {
        .point => try runWorkload1(selected_runner, selected_mode, allocator, db, pointSpec(), buildPointParams),
        .wide_rows => try runWorkload1(selected_runner, selected_mode, allocator, db, wideRowsSpec(), buildWideRowsParams),
        .large_rows => try runWorkload1(selected_runner, selected_mode, allocator, db, largeRowsSpec(), buildLargeRowsParams),
        .many_params => try runWorkloadN(MANY_PARAMS_COUNT, selected_runner, selected_mode, allocator, db, manyParamsSpec(), buildManyParamsBatch),
        .aggregate => try runWorkloadN(2, selected_runner, selected_mode, allocator, db, aggregateSpec(), buildAggregateParams),
    };

    if (plain) {
        try stdout.print("{d:.3}\n", .{result.qps});
        return;
    }

    try stdout.print("{s} {s}/{s}: {d:.0} q/s", .{
        @tagName(selected_runner),
        @tagName(selected_mode),
        @tagName(workload),
        result.qps,
    });
    if (result.rows_per_sec) |rows_per_sec| {
        try stdout.print(" | {d:.0} rows/s", .{rows_per_sec});
    }
    if (result.mib_per_sec) |mib_per_sec| {
        try stdout.print(" | {d:.2} MiB/s", .{mib_per_sec});
    }
    try stdout.print(" | checksum=0x{x}\n", .{result.checksum});
}

fn usageAndExit(reason: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{reason});
    std.debug.print(
        "Usage: qail_pgzig_bench <qail|pgzig> <single|pool10> [--workload point|wide_rows|large_rows|many_params|aggregate] [--plain]\n",
        .{},
    );
    std.process.exit(1);
}

fn pointSpec() WorkloadSpec {
    return .{
        .name = "point",
        .total_queries = POINT_TOTAL_QUERIES,
        .iterations = POINT_ITERATIONS,
        .param_types = ONE_INT_PARAM_TYPES[0..],
        .cmd = &POINT_CMD,
    };
}

fn wideRowsSpec() WorkloadSpec {
    return .{
        .name = "wide_rows",
        .total_queries = WIDE_ROWS_TOTAL_QUERIES,
        .iterations = WIDE_ROWS_ITERATIONS,
        .param_types = ONE_INT_PARAM_TYPES[0..],
        .cmd = &RANGE_ROWS_CMD,
    };
}

fn largeRowsSpec() WorkloadSpec {
    return .{
        .name = "large_rows",
        .total_queries = LARGE_ROWS_TOTAL_QUERIES,
        .iterations = LARGE_ROWS_ITERATIONS,
        .param_types = ONE_INT_PARAM_TYPES[0..],
        .cmd = &RANGE_ROWS_CMD,
    };
}

fn manyParamsSpec() WorkloadSpec {
    return .{
        .name = "many_params",
        .total_queries = MANY_PARAMS_TOTAL_QUERIES,
        .iterations = MANY_PARAMS_ITERATIONS,
        .param_types = MANY_PARAMS_PARAM_TYPES[0..],
        .cmd = &MANY_PARAMS_CMD,
    };
}

fn aggregateSpec() WorkloadSpec {
    return .{
        .name = "aggregate",
        .total_queries = AGGREGATE_TOTAL_QUERIES,
        .iterations = AGGREGATE_ITERATIONS,
        .param_types = TWO_INT_PARAM_TYPES[0..],
        .cmd = &AGGREGATE_CMD,
    };
}

fn runWorkload1(
    runner: Runner,
    mode: Mode,
    allocator: std.mem.Allocator,
    db: DbConfig,
    spec: WorkloadSpec,
    comptime builder: fn (std.mem.Allocator, usize) anyerror!ParamBatch(1),
) !BenchmarkResult {
    return runWorkloadN(1, runner, mode, allocator, db, spec, builder);
}

fn runWorkloadN(
    comptime N: usize,
    runner: Runner,
    mode: Mode,
    allocator: std.mem.Allocator,
    db: DbConfig,
    spec: WorkloadSpec,
    comptime builder: fn (std.mem.Allocator, usize) anyerror!ParamBatch(N),
) !BenchmarkResult {
    const sql = try qail.transpiler.toSql(allocator, spec.cmd);
    const params = try builder(allocator, spec.total_queries);

    return switch (runner) {
        .qail => switch (mode) {
            .single => try runQailSingleMode(N, db, sql, spec.param_types, params.qail, spec.iterations),
            .pool10 => try runQailPoolMode(N, db, sql, spec.param_types, params.qail, spec.iterations),
        },
        .pgzig => switch (mode) {
            .single => try runPgSingleMode(N, db, sql, params.pg, spec.iterations),
            .pool10 => try runPgPoolMode(N, db, sql, params.pg, spec.iterations),
        },
    };
}

fn runQailSingleMode(
    comptime N: usize,
    db: DbConfig,
    sql: []const u8,
    param_types: []const u32,
    params: [][N]?[]const u8,
    iterations: usize,
) !BenchmarkResult {
    var conn = try Connection.connect(std.heap.page_allocator, db.host, db.port);
    defer conn.close();
    try conn.startup(db.user, db.database, db.password);
    try prepareNamedStatement(&conn, QAIL_STMT_NAME, sql, param_types);

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    const warmup = try runQailPreparedSingles(N, &conn, &encoder, params);
    if (warmup.completed != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..iterations) |_| {
        const start = try time.now();
        const stats = try runQailPreparedSingles(N, &conn, &encoder, params);
        const end = try time.now();
        if (stats.completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
        aggregate.add(stats);
    }
    return makeBenchmarkResult(aggregate, total_ns);
}

fn runQailPoolMode(
    comptime N: usize,
    db: DbConfig,
    sql: []const u8,
    param_types: []const u32,
    params: [][N]?[]const u8,
    iterations: usize,
) !BenchmarkResult {
    if (params.len % POOL_SIZE != 0) return error.InvalidBenchmarkConfig;

    var pool = try PgPool.init(std.heap.page_allocator, PoolConfig{
        .host = db.host,
        .port = db.port,
        .user = db.user,
        .database = db.database,
        .password = db.password,
        .max_connections = POOL_SIZE,
        .min_connections = POOL_SIZE,
    });
    defer pool.deinit();

    const per_worker = params.len / POOL_SIZE;
    const Ctx = struct {
        pool: *PgPool,
        sync: *WorkerSync,
        sql: []const u8,
        param_types: []const u32,
        params: [][N]?[]const u8,
        iterations: usize,
        result: *WorkerResult,

        fn main(ctx: *@This()) void {
            var local_err: ?anyerror = null;

            var pooled = ctx.pool.acquire() catch |err| {
                local_err = err;
                signalReady(ctx.sync, ctx.result, local_err);
                waitForStart(ctx.sync);
                signalDone(ctx.sync, ctx.result, local_err);
                return;
            };
            defer pooled.release();

            var encoder = Encoder.init(std.heap.page_allocator);
            defer encoder.deinit();

            if (local_err == null) {
                const conn = pooled.get();
                prepareNamedStatement(conn, QAIL_STMT_NAME, ctx.sql, ctx.param_types) catch |err| {
                    local_err = err;
                };
                if (local_err == null) {
                    _ = runQailPreparedSingles(N, conn, &encoder, ctx.params) catch |err| {
                        local_err = err;
                    };
                }
            }

            signalReady(ctx.sync, ctx.result, local_err);
            waitForStart(ctx.sync);

            if (local_err == null) {
                const conn = pooled.get();
                var aggregate = BatchStats{};
                for (0..ctx.iterations) |_| {
                    const stats = runQailPreparedSingles(N, conn, &encoder, ctx.params) catch |err| {
                        local_err = err;
                        break;
                    };
                    aggregate.add(stats);
                }
                ctx.result.stats = aggregate;
            }

            signalDone(ctx.sync, ctx.result, local_err);
        }
    };

    var sync = WorkerSync{};
    var threads: [POOL_SIZE]std.Thread = undefined;
    var results: [POOL_SIZE]WorkerResult = undefined;
    for (&results) |*result| result.* = .{};

    var contexts: [POOL_SIZE]Ctx = undefined;
    for (0..POOL_SIZE) |worker_idx| {
        const start_idx = worker_idx * per_worker;
        contexts[worker_idx] = .{
            .pool = &pool,
            .sync = &sync,
            .sql = sql,
            .param_types = param_types,
            .params = params[start_idx .. start_idx + per_worker],
            .iterations = iterations,
            .result = &results[worker_idx],
        };
        threads[worker_idx] = try std.Thread.spawn(.{}, Ctx.main, .{&contexts[worker_idx]});
    }

    waitForCounter(&sync.ready_count, POOL_SIZE);
    const start = try time.now();
    sync.start_flag.store(true, .release);
    waitForCounter(&sync.done_count, POOL_SIZE);
    const end = try time.now();

    for (threads) |thread| thread.join();
    for (results) |result| if (result.err) |err| return err;

    var aggregate = BatchStats{};
    for (results) |result| aggregate.add(result.stats);
    return makeBenchmarkResult(aggregate, time.since(end, start));
}

fn runPgSingleMode(
    comptime N: usize,
    db: DbConfig,
    sql: []const u8,
    params: [][N]i32,
    iterations: usize,
) !BenchmarkResult {
    var pool = try openPgPool(db, 1);
    defer pool.deinit();

    var conn = try pool.acquire();
    defer conn.release();

    const warmup = try runPgPreparedSingles(N, conn, sql, params);
    if (warmup.completed != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..iterations) |_| {
        const start = try time.now();
        const stats = try runPgPreparedSingles(N, conn, sql, params);
        const end = try time.now();
        if (stats.completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
        aggregate.add(stats);
    }
    return makeBenchmarkResult(aggregate, total_ns);
}

fn runPgPoolMode(
    comptime N: usize,
    db: DbConfig,
    sql: []const u8,
    params: [][N]i32,
    iterations: usize,
) !BenchmarkResult {
    if (params.len % POOL_SIZE != 0) return error.InvalidBenchmarkConfig;

    var pool = try openPgPool(db, POOL_SIZE);
    defer pool.deinit();

    const per_worker = params.len / POOL_SIZE;
    const Ctx = struct {
        pool: *pg.Pool,
        sync: *WorkerSync,
        sql: []const u8,
        params: [][N]i32,
        iterations: usize,
        result: *WorkerResult,

        fn main(ctx: *@This()) void {
            var local_err: ?anyerror = null;
            var conn = ctx.pool.acquire() catch |err| {
                local_err = err;
                signalReady(ctx.sync, ctx.result, local_err);
                waitForStart(ctx.sync);
                signalDone(ctx.sync, ctx.result, local_err);
                return;
            };
            defer conn.release();

            if (local_err == null) {
                _ = runPgPreparedSingles(N, conn, ctx.sql, ctx.params) catch |err| {
                    local_err = err;
                };
            }

            signalReady(ctx.sync, ctx.result, local_err);
            waitForStart(ctx.sync);

            if (local_err == null) {
                var aggregate = BatchStats{};
                for (0..ctx.iterations) |_| {
                    const stats = runPgPreparedSingles(N, conn, ctx.sql, ctx.params) catch |err| {
                        local_err = err;
                        break;
                    };
                    aggregate.add(stats);
                }
                ctx.result.stats = aggregate;
            }

            signalDone(ctx.sync, ctx.result, local_err);
        }
    };

    var sync = WorkerSync{};
    var threads: [POOL_SIZE]std.Thread = undefined;
    var results: [POOL_SIZE]WorkerResult = undefined;
    for (&results) |*result| result.* = .{};

    var contexts: [POOL_SIZE]Ctx = undefined;
    for (0..POOL_SIZE) |worker_idx| {
        const start_idx = worker_idx * per_worker;
        contexts[worker_idx] = .{
            .pool = pool,
            .sync = &sync,
            .sql = sql,
            .params = params[start_idx .. start_idx + per_worker],
            .iterations = iterations,
            .result = &results[worker_idx],
        };
        threads[worker_idx] = try std.Thread.spawn(.{}, Ctx.main, .{&contexts[worker_idx]});
    }

    waitForCounter(&sync.ready_count, POOL_SIZE);
    const start = try time.now();
    sync.start_flag.store(true, .release);
    waitForCounter(&sync.done_count, POOL_SIZE);
    const end = try time.now();

    for (threads) |thread| thread.join();
    for (results) |result| if (result.err) |err| return err;

    var aggregate = BatchStats{};
    for (results) |result| aggregate.add(result.stats);
    return makeBenchmarkResult(aggregate, time.since(end, start));
}

fn runQailPreparedSingles(
    comptime N: usize,
    conn: *Connection,
    encoder: *Encoder,
    params_batch: [][N]?[]const u8,
) !BatchStats {
    var stats = BatchStats{};
    for (params_batch) |params| {
        encoder.reset();
        try encoder.appendBind("", QAIL_STMT_NAME, params[0..]);
        try encoder.appendExecute("", 0);
        try encoder.appendSync();
        try conn.send(encoder.getWritten());
        const result = try consumeQailSingleResult(conn);
        stats.add(result);
    }
    return stats;
}

fn runPgPreparedSingles(
    comptime N: usize,
    conn: *pg.Conn,
    sql: []const u8,
    params_batch: [][N]i32,
) !BatchStats {
    var stats = BatchStats{};
    for (params_batch) |params| {
        var result = try conn.queryOpts(sql, params, .{ .cache_name = PG_CACHE_NAME });
        errdefer result.deinit();
        try consumePgResult(result, &stats);
        result.deinit();
        stats.completed += 1;
    }
    return stats;
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

fn consumeQailSingleResult(conn: *Connection) !BatchStats {
    var completed = false;
    var stats = BatchStats{};
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .bind_complete, .row_description, .notice, .parameter_status, .notification => {},
            .data_row => try consumeQailDataRow(msg.payload, &stats),
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

fn consumeQailDataRow(payload: []const u8, stats: *BatchStats) !void {
    if (payload.len < 2) return error.InvalidDataRow;
    const column_count = std.mem.readInt(u16, payload[0..2], .big);
    var pos: usize = 2;
    var row_hash: u64 = 0xcbf29ce484222325;

    for (0..column_count) |_| {
        if (pos + 4 > payload.len) return error.InvalidDataRow;
        const raw_len = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;
        if (raw_len < 0) {
            row_hash = mixHash(row_hash, "NULL");
            continue;
        }

        const len: usize = @intCast(raw_len);
        if (pos + len > payload.len) return error.InvalidDataRow;

        const value = payload[pos .. pos + len];
        pos += len;
        stats.bytes += value.len;
        row_hash = mixHash(row_hash, value);
    }

    if (pos != payload.len) return error.InvalidDataRow;
    stats.rows += 1;
    stats.checksum +%= row_hash;
}

fn consumePgResult(result: *pg.Result, stats: *BatchStats) !void {
    while (try result.next()) |row| {
        var row_hash: u64 = 0xcbf29ce484222325;
        for (row.values[0..result.number_of_columns]) |value| {
            if (value.is_null) {
                row_hash = mixHash(row_hash, "NULL");
                continue;
            }
            stats.bytes += value.data.len;
            row_hash = mixHash(row_hash, value.data);
        }
        stats.rows += 1;
        stats.checksum +%= row_hash;
    }
}

fn drainUntilReady(conn: *Connection) !void {
    while (true) {
        const msg = try conn.readMessage();
        if (msg.msg_type == .ready_for_query) return;
    }
}

fn makeBenchmarkResult(stats: BatchStats, elapsed_ns: u64) BenchmarkResult {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    return .{
        .qps = @as(f64, @floatFromInt(stats.completed)) / seconds,
        .rows_per_sec = if (stats.rows > 0) @as(f64, @floatFromInt(stats.rows)) / seconds else null,
        .mib_per_sec = if (stats.bytes > 0) (@as(f64, @floatFromInt(stats.bytes)) / (1024.0 * 1024.0)) / seconds else null,
        .checksum = stats.checksum,
    };
}

fn signalReady(sync: *WorkerSync, result: *WorkerResult, err: ?anyerror) void {
    result.err = err;
    _ = sync.ready_count.fetchAdd(1, .acq_rel);
}

fn signalDone(sync: *WorkerSync, result: *WorkerResult, err: ?anyerror) void {
    result.err = err;
    _ = sync.done_count.fetchAdd(1, .acq_rel);
}

fn waitForStart(sync: *WorkerSync) void {
    while (!sync.start_flag.load(.acquire)) {
        std.Thread.yield() catch std.Thread.sleep(100_000);
    }
}

fn waitForCounter(counter: *std.atomic.Value(usize), expected: usize) void {
    while (counter.load(.acquire) < expected) {
        std.Thread.yield() catch std.Thread.sleep(100_000);
    }
}

fn mixHash(seed: u64, bytes: []const u8) u64 {
    var hash = seed;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn openPgPool(db: DbConfig, size: u16) !*pg.Pool {
    return pg.Pool.init(std.heap.page_allocator, .{
        .size = size,
        .connect = .{
            .host = db.host,
            .port = db.port,
        },
        .auth = .{
            .username = db.user,
            .database = db.database,
            .password = db.password,
            .timeout = 10_000,
        },
    });
}

fn loadDbConfig(allocator: std.mem.Allocator) !DbConfig {
    const bench_url = readEnvOwned(allocator, "QAIL_BENCH_DATABASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (bench_url) |url| return try parseDbUrl(allocator, url);

    const database_url = readEnvOwned(allocator, "DATABASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (database_url) |url| return try parseDbUrl(allocator, url);

    return .{
        .host = readEnvOwned(allocator, "PGHOST") catch DEFAULT_HOST,
        .port = readEnvU16(allocator, "PGPORT") catch DEFAULT_PORT,
        .user = readEnvOwned(allocator, "PGUSER") catch DEFAULT_USER,
        .database = readEnvOwned(allocator, "PGDATABASE") catch DEFAULT_DATABASE,
        .password = readEnvOwned(allocator, "PGPASSWORD") catch DEFAULT_PASSWORD,
    };
}

fn readEnvOwned(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, name);
}

fn readEnvU16(allocator: std.mem.Allocator, name: []const u8) !u16 {
    const value = try std.process.getEnvVarOwned(allocator, name);
    return std.fmt.parseInt(u16, value, 10);
}

fn parseDbUrl(allocator: std.mem.Allocator, raw_url: []const u8) !DbConfig {
    const normalized = if (std.mem.startsWith(u8, raw_url, "postgres://"))
        try std.fmt.allocPrint(allocator, "postgresql://{s}", .{raw_url["postgres://".len..]})
    else
        raw_url;

    const parsed = try qail.driver.pool.parseUri(normalized);
    return .{
        .host = parsed.host,
        .port = parsed.port,
        .user = parsed.user,
        .database = parsed.database,
        .password = parsed.password,
    };
}

fn ensureBenchmarkData(allocator: std.mem.Allocator, db: DbConfig) !void {
    var pool = try openPgPool(db, 1);
    defer pool.deinit();

    _ = try pool.exec(
        "CREATE TABLE IF NOT EXISTS " ++ BENCH_TABLE ++ " (" ++
            "id INTEGER PRIMARY KEY, " ++
            "name TEXT NOT NULL, " ++
            "bio TEXT NOT NULL, " ++
            "region TEXT NOT NULL, " ++
            "visits INTEGER NOT NULL, " ++
            "active BOOLEAN NOT NULL, " ++
            "ratio DOUBLE PRECISION NOT NULL, " ++
            "optional_note TEXT NULL" ++
            ")",
        .{},
    );

    var conn = try pool.acquire();
    defer conn.release();

    const current_count = blk: {
        var row = (try conn.row("SELECT COUNT(*) FROM " ++ BENCH_TABLE, .{})) orelse return error.BenchmarkTableMissing;
        defer row.deinit() catch {};
        break :blk try row.get(i64, 0);
    };

    if (current_count < BENCH_ROW_COUNT) {
        _ = try conn.exec("TRUNCATE TABLE " ++ BENCH_TABLE, .{});
        _ = try conn.exec(
            "INSERT INTO " ++ BENCH_TABLE ++ " (" ++
                "id, name, bio, region, visits, active, ratio, optional_note" ++
                ") " ++
                "SELECT gs, " ++
                "('harbor-' || gs)::text, " ++
                "repeat(md5(gs::text), 4), " ++
                "repeat(md5((gs * 17)::text), 3), " ++
                "(gs * 11), " ++
                "(gs % 2 = 0), " ++
                "(gs::double precision / 7.0), " ++
                "CASE WHEN gs % 5 = 0 THEN NULL ELSE repeat(md5((gs * 3)::text), 2) END " ++
                "FROM generate_series(1, $1) AS gs",
            .{@as(i32, BENCH_ROW_COUNT)},
        );
        _ = try conn.exec("ANALYZE " ++ BENCH_TABLE, .{});
    }

    _ = allocator;
}

fn buildIntParamTypes(comptime count: usize) [count]u32 {
    var types: [count]u32 = undefined;
    inline for (0..count) |idx| {
        types[idx] = INT4_OID;
    }
    return types;
}

fn buildManyParamClauses() [MANY_PARAMS_COUNT]WhereClause {
    var clauses: [MANY_PARAMS_COUNT]WhereClause = undefined;
    inline for (0..MANY_PARAMS_COUNT) |idx| {
        clauses[idx] = .{
            .condition = .{
                .column = "id",
                .op = .eq,
                .value = .{ .param = @intCast(idx + 1) },
            },
            .logical_op = if (idx == 0) .@"and" else .@"or",
        };
    }
    return clauses;
}

fn buildPointParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(1) {
    return buildIntBatch(1, allocator, total, pointValueAt);
}

fn buildWideRowsParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(1) {
    return buildIntBatch(1, allocator, total, wideRowsValueAt);
}

fn buildLargeRowsParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(1) {
    return buildIntBatch(1, allocator, total, largeRowsValueAt);
}

fn buildManyParamsBatch(allocator: std.mem.Allocator, total: usize) !ParamBatch(MANY_PARAMS_COUNT) {
    return buildIntBatch(MANY_PARAMS_COUNT, allocator, total, manyParamsValueAt);
}

fn buildAggregateParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(2) {
    return buildIntBatch(2, allocator, total, aggregateValueAt);
}

fn buildIntBatch(
    comptime N: usize,
    allocator: std.mem.Allocator,
    total: usize,
    comptime generator: fn (usize) [N]i32,
) !ParamBatch(N) {
    const pg_values = try allocator.alloc([N]i32, total);
    const qail_values = try allocator.alloc([N]?[]const u8, total);

    for (0..total) |idx| {
        const values = generator(idx);
        pg_values[idx] = values;
        inline for (0..N) |param_idx| {
            qail_values[idx][param_idx] = try std.fmt.allocPrint(allocator, "{d}", .{values[param_idx]});
        }
    }

    return .{
        .pg = pg_values,
        .qail = qail_values,
    };
}

fn pointValueAt(index: usize) [1]i32 {
    return .{@intCast((index % BENCH_ROW_COUNT) + 1)};
}

fn wideRowsValueAt(index: usize) [1]i32 {
    const row_counts = [_]i32{ 128, 256, 384, 512 };
    return .{row_counts[index % row_counts.len]};
}

fn largeRowsValueAt(index: usize) [1]i32 {
    const row_counts = [_]i32{ 10_000, 20_000, 30_000, 40_000 };
    return .{row_counts[index % row_counts.len]};
}

fn manyParamsValueAt(index: usize) [MANY_PARAMS_COUNT]i32 {
    var values: [MANY_PARAMS_COUNT]i32 = undefined;
    for (0..MANY_PARAMS_COUNT) |param_idx| {
        values[param_idx] = @intCast(((index * 131) + (param_idx * 977)) % BENCH_ROW_COUNT + 1);
    }
    return values;
}

fn aggregateValueAt(index: usize) [2]i32 {
    const combos = [_][2]i32{
        .{ 1_000, 15_000 },
        .{ 5_000, 25_000 },
        .{ 10_000, 35_000 },
        .{ 15_000, 45_000 },
    };
    return combos[index % combos.len];
}
