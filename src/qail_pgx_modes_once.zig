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
const TOTAL_QUERIES: usize = 10_000;
const ITERATIONS: usize = 5;
const POOL_SIZE: usize = 10;
const INT4_OID: u32 = 23;
const STMT_NAME = "qail_zig_modes_stmt";

const Param = [1]?[]const u8;

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

const PoolSync = struct {
    ready_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

const WorkerResult = struct {
    err: ?anyerror = null,
};

const PoolWorkerCtx = struct {
    pool: *PgPool,
    sync: *PoolSync,
    params: []const Param,
    result: *WorkerResult,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const args = try process_compat.argsAlloc(allocator);

    var mode: ?Mode = null;
    var plain = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
            continue;
        }
        if (mode == null) {
            mode = Mode.parse(arg);
            if (mode == null) usageAndExit("unknown mode");
            continue;
        }
        usageAndExit("unexpected argument");
    }

    const selected_mode = mode orelse usageAndExit("missing mode argument");
    const params = try buildParamBatch(allocator, TOTAL_QUERIES);

    const qps = switch (selected_mode) {
        .single => try runSingleMode(params),
        .pipeline => try runPipelineMode(params),
        .pool10 => try runPool10Mode(params),
    };

    if (plain) {
        try stdout.print("{d:.3}\n", .{qps});
    } else {
        try stdout.print("qail-zig {s}: {d:.0} q/s\n", .{@tagName(selected_mode), qps});
    }
}

fn usageAndExit(reason: []const u8) noreturn {
    std.debug.print("Error: {s}\n", .{reason});
    std.debug.print("Usage: qail_pgx_modes_once <single|pipeline|pool10> [--plain]\n", .{});
    std.process.exit(1);
}

fn buildParamBatch(allocator: std.mem.Allocator, total: usize) ![]Param {
    const params = try allocator.alloc(Param, total);
    for (params, 0..) |*slot, i| {
        const id = (i % 10_000) + 1;
        slot.* = .{try std.fmt.allocPrint(allocator, "{d}", .{id})};
    }
    return params;
}

fn runSingleMode(params: []const Param) !f64 {
    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);
    try prepareNamedStatement(&conn, STMT_NAME, SQL_BY_ID);

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    try runPreparedSingles(&conn, &encoder, STMT_NAME, params);

    var total_ns: u64 = 0;
    for (0..ITERATIONS) |_| {
        const start = try time.now();
        try runPreparedSingles(&conn, &encoder, STMT_NAME, params);
        const end = try time.now();
        total_ns += time.since(end, start);
    }

    return qpsFrom(TOTAL_QUERIES * ITERATIONS, total_ns);
}

fn runPipelineMode(params: []const Param) !f64 {
    var conn = try Connection.connect(std.heap.page_allocator, HOST, PORT);
    defer conn.close();
    try conn.startup(USER, DATABASE, null);
    try prepareNamedStatement(&conn, STMT_NAME, SQL_BY_ID);

    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    const warmup = try runPreparedPipelineCount(&conn, &encoder, STMT_NAME, params);
    if (warmup != params.len) return error.UnexpectedCompletionCount;

    var total_ns: u64 = 0;
    for (0..ITERATIONS) |_| {
        const start = try time.now();
        const completed = try runPreparedPipelineCount(&conn, &encoder, STMT_NAME, params);
        const end = try time.now();
        if (completed != params.len) return error.UnexpectedCompletionCount;
        total_ns += time.since(end, start);
    }

    return qpsFrom(TOTAL_QUERIES * ITERATIONS, total_ns);
}

fn runPool10Mode(params: []const Param) !f64 {
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

    return qpsFrom(TOTAL_QUERIES * ITERATIONS, time.since(end, start));
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
        prepareNamedStatement(conn, STMT_NAME, SQL_BY_ID) catch |err| {
            local_err = err;
        };
        if (local_err == null) {
            runPreparedSingles(conn, &encoder, STMT_NAME, ctx.params) catch |err| {
                local_err = err;
            };
        }
    }

    signalReady(ctx, local_err);
    waitForStart(ctx.sync);

    if (local_err == null) {
        const conn = pooled.get();
        for (0..ITERATIONS) |_| {
            runPreparedSingles(conn, &encoder, STMT_NAME, ctx.params) catch |err| {
                local_err = err;
                break;
            };
        }
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

fn prepareNamedStatement(conn: *Connection, stmt_name: []const u8, sql: []const u8) !void {
    var encoder = Encoder.init(std.heap.page_allocator);
    defer encoder.deinit();

    try encoder.encodeParse(stmt_name, sql, &.{INT4_OID});
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
    params_batch: []const Param,
) !void {
    for (params_batch) |params| {
        encoder.reset();
        try encoder.appendBind("", stmt_name, params[0..]);
        try encoder.appendExecute("", 0);
        try encoder.appendSync();
        try conn.send(encoder.getWritten());
        try consumeSingleResult(conn);
    }
}

fn runPreparedPipelineCount(
    conn: *Connection,
    encoder: *Encoder,
    stmt_name: []const u8,
    params_batch: []const Param,
) !usize {
    encoder.reset();
    for (params_batch) |params| {
        try encoder.appendBind("", stmt_name, params[0..]);
        try encoder.appendExecute("", 0);
    }
    try encoder.appendSync();
    try conn.send(encoder.getWritten());
    return try consumePipelineCount(conn, params_batch.len);
}

fn consumeSingleResult(conn: *Connection) !void {
    var completed = false;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .bind_complete, .row_description, .data_row, .notice, .parameter_status, .notification => {},
            .command_complete, .no_data => completed = true,
            .ready_for_query => {
                if (!completed) return error.QueryDidNotComplete;
                return;
            },
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.QueryError;
            },
            else => {},
        }
    }
}

fn consumePipelineCount(conn: *Connection, expected: usize) !usize {
    var completed: usize = 0;
    while (true) {
        const msg = try conn.readMessage();
        switch (msg.msg_type) {
            .bind_complete, .row_description, .data_row, .notice, .parameter_status, .notification => {},
            .command_complete, .no_data => completed += 1,
            .ready_for_query => return completed,
            .error_response => {
                _ = drainUntilReady(conn) catch {};
                return error.QueryError;
            },
            else => {},
        }
        if (completed > expected) return error.UnexpectedCompletionCount;
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
