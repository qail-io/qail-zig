const std = @import("std");
const qail = @import("qail");
const pg = @import("pg");
const bench = @import("workloads.zig");

const time = qail.compat.time;
const Connection = qail.driver.Connection;
const PgPool = qail.driver.PgPool;
const PoolConfig = qail.driver.PoolConfig;
const Encoder = qail.protocol.Encoder;

pub const DbConfig = bench.DbConfig;
pub const BenchmarkResult = bench.BenchmarkResult;
pub const BatchStats = bench.BatchStats;
pub const WorkerSync = bench.WorkerSync;
pub const WorkerResult = bench.WorkerResult;
pub const WorkloadSpec = bench.WorkloadSpec;
pub const ParamBatch = bench.ParamBatch;
pub const DEFAULT_HOST = bench.DEFAULT_HOST;
pub const DEFAULT_USER = bench.DEFAULT_USER;
pub const DEFAULT_DATABASE = bench.DEFAULT_DATABASE;
pub const DEFAULT_PORT = bench.DEFAULT_PORT;
pub const DEFAULT_PASSWORD = bench.DEFAULT_PASSWORD;
pub const POOL_SIZE = bench.POOL_SIZE;
pub const BENCH_TABLE = bench.BENCH_TABLE;
pub const BENCH_ROW_COUNT = bench.BENCH_ROW_COUNT;
pub const QAIL_STMT_NAME = bench.QAIL_STMT_NAME;
pub const PG_CACHE_NAME = bench.PG_CACHE_NAME;
pub const MANY_PARAMS_COUNT = bench.MANY_PARAMS_COUNT;

pub fn runWorkload1(
    runner: bench.Runner,
    mode: bench.Mode,
    allocator: std.mem.Allocator,
    db: DbConfig,
    spec: WorkloadSpec,
    comptime builder: fn (std.mem.Allocator, usize) anyerror!ParamBatch(1),
) !BenchmarkResult {
    return runWorkloadN(1, runner, mode, allocator, db, spec, builder);
}

pub fn runWorkloadN(
    comptime N: usize,
    runner: bench.Runner,
    mode: bench.Mode,
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

fn assertConsumed(stats: BatchStats, expected_completed: usize) !void {
    if (stats.completed != expected_completed) return error.UnexpectedCompletionCount;
    if (expected_completed == 0) return;

    // Every workload in this harness is a SELECT shape that should return at least
    // one row per completed query when the result stream is actually consumed.
    if (stats.rows < stats.completed) return error.ResultRowsNotConsumed;
    if (stats.bytes == 0) return error.ResultBytesNotConsumed;
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
    try assertConsumed(warmup, params.len);

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..iterations) |_| {
        const start = try time.now();
        const stats = try runQailPreparedSingles(N, &conn, &encoder, params);
        const end = try time.now();
        try assertConsumed(stats, params.len);
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
                    if (runQailPreparedSingles(N, conn, &encoder, ctx.params)) |warmup| {
                        assertConsumed(warmup, ctx.params.len) catch |err| {
                            local_err = err;
                        };
                    } else |err| {
                        local_err = err;
                    }
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
                    assertConsumed(stats, ctx.params.len) catch |err| {
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
    try assertConsumed(warmup, params.len);

    var total_ns: u64 = 0;
    var aggregate = BatchStats{};
    for (0..iterations) |_| {
        const start = try time.now();
        const stats = try runPgPreparedSingles(N, conn, sql, params);
        const end = try time.now();
        try assertConsumed(stats, params.len);
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
                if (runPgPreparedSingles(N, conn, ctx.sql, ctx.params)) |warmup| {
                    assertConsumed(warmup, ctx.params.len) catch |err| {
                        local_err = err;
                    };
                } else |err| {
                    local_err = err;
                }
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
                    assertConsumed(stats, ctx.params.len) catch |err| {
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

pub fn loadDbConfig(allocator: std.mem.Allocator) !DbConfig {
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

pub fn ensureBenchmarkData(allocator: std.mem.Allocator, db: DbConfig) !void {
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
