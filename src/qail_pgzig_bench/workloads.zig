const std = @import("std");
const qail = @import("qail");

const Expr = qail.Expr;
const QailCmd = qail.QailCmd;
const WhereClause = qail.ast.WhereClause;

pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_USER = "orion";
pub const DEFAULT_DATABASE = "example_staging";
pub const DEFAULT_PORT: u16 = 5432;
pub const DEFAULT_PASSWORD: ?[]const u8 = null;
pub const POOL_SIZE: usize = 10;
pub const BENCH_TABLE = "zig_pg_driver_bench_payload";
pub const BENCH_ROW_COUNT: usize = 50_000;
pub const QAIL_STMT_NAME = "qail_pgzig_bench_stmt";
pub const PG_CACHE_NAME = "qail_pgzig_bench_stmt";
pub const INT4_OID: u32 = 23;

pub const POINT_TOTAL_QUERIES: usize = 20_000;
pub const POINT_ITERATIONS: usize = 5;
pub const WIDE_ROWS_TOTAL_QUERIES: usize = 120;
pub const WIDE_ROWS_ITERATIONS: usize = 3;
pub const LARGE_ROWS_TOTAL_QUERIES: usize = 40;
pub const LARGE_ROWS_ITERATIONS: usize = 3;
pub const MANY_PARAMS_TOTAL_QUERIES: usize = 4_000;
pub const MANY_PARAMS_ITERATIONS: usize = 4;
pub const AGGREGATE_TOTAL_QUERIES: usize = 2_000;
pub const AGGREGATE_ITERATIONS: usize = 4;
pub const MANY_PARAMS_COUNT: usize = 16;

pub const Mode = enum {
    single,
    pool10,

    pub fn parse(input: []const u8) ?Mode {
        if (std.mem.eql(u8, input, "single")) return .single;
        if (std.mem.eql(u8, input, "pool10") or std.mem.eql(u8, input, "pool")) return .pool10;
        return null;
    }
};

pub const Runner = enum {
    qail,
    pgzig,

    pub fn parse(input: []const u8) ?Runner {
        if (std.mem.eql(u8, input, "qail") or std.mem.eql(u8, input, "qail-zig")) return .qail;
        if (std.mem.eql(u8, input, "pgzig") or std.mem.eql(u8, input, "pg")) return .pgzig;
        return null;
    }
};

pub const Workload = enum {
    point,
    wide_rows,
    large_rows,
    many_params,
    aggregate,

    pub fn parse(input: []const u8) ?Workload {
        if (std.mem.eql(u8, input, "point")) return .point;
        if (std.mem.eql(u8, input, "wide_rows") or std.mem.eql(u8, input, "wide")) return .wide_rows;
        if (std.mem.eql(u8, input, "large_rows") or std.mem.eql(u8, input, "large")) return .large_rows;
        if (std.mem.eql(u8, input, "many_params") or std.mem.eql(u8, input, "params")) return .many_params;
        if (std.mem.eql(u8, input, "aggregate") or std.mem.eql(u8, input, "agg")) return .aggregate;
        return null;
    }
};

pub const DbConfig = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    database: []const u8,
    password: ?[]const u8 = null,
};

pub const BenchmarkResult = struct {
    qps: f64,
    rows_per_sec: ?f64 = null,
    mib_per_sec: ?f64 = null,
    checksum: u64 = 0,
};

pub const BatchStats = struct {
    completed: usize = 0,
    rows: usize = 0,
    bytes: usize = 0,
    checksum: u64 = 0,

    pub fn add(self: *BatchStats, other: BatchStats) void {
        self.completed += other.completed;
        self.rows += other.rows;
        self.bytes += other.bytes;
        self.checksum +%= other.checksum;
    }
};

pub const WorkerSync = struct {
    ready_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

pub const WorkerResult = struct {
    err: ?anyerror = null,
    stats: BatchStats = .{},
};

pub const WorkloadSpec = struct {
    name: []const u8,
    total_queries: usize,
    iterations: usize,
    param_types: []const u32,
    cmd: *const QailCmd,
};

pub fn ParamBatch(comptime N: usize) type {
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

pub fn pointSpec() WorkloadSpec {
    return .{
        .name = "point",
        .total_queries = POINT_TOTAL_QUERIES,
        .iterations = POINT_ITERATIONS,
        .param_types = ONE_INT_PARAM_TYPES[0..],
        .cmd = &POINT_CMD,
    };
}

pub fn wideRowsSpec() WorkloadSpec {
    return .{
        .name = "wide_rows",
        .total_queries = WIDE_ROWS_TOTAL_QUERIES,
        .iterations = WIDE_ROWS_ITERATIONS,
        .param_types = ONE_INT_PARAM_TYPES[0..],
        .cmd = &RANGE_ROWS_CMD,
    };
}

pub fn largeRowsSpec() WorkloadSpec {
    return .{
        .name = "large_rows",
        .total_queries = LARGE_ROWS_TOTAL_QUERIES,
        .iterations = LARGE_ROWS_ITERATIONS,
        .param_types = ONE_INT_PARAM_TYPES[0..],
        .cmd = &RANGE_ROWS_CMD,
    };
}

pub fn manyParamsSpec() WorkloadSpec {
    return .{
        .name = "many_params",
        .total_queries = MANY_PARAMS_TOTAL_QUERIES,
        .iterations = MANY_PARAMS_ITERATIONS,
        .param_types = MANY_PARAMS_PARAM_TYPES[0..],
        .cmd = &MANY_PARAMS_CMD,
    };
}

pub fn aggregateSpec() WorkloadSpec {
    return .{
        .name = "aggregate",
        .total_queries = AGGREGATE_TOTAL_QUERIES,
        .iterations = AGGREGATE_ITERATIONS,
        .param_types = TWO_INT_PARAM_TYPES[0..],
        .cmd = &AGGREGATE_CMD,
    };
}

pub fn buildPointParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(1) {
    return buildIntBatch(1, allocator, total, pointValueAt);
}

pub fn buildWideRowsParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(1) {
    return buildIntBatch(1, allocator, total, wideRowsValueAt);
}

pub fn buildLargeRowsParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(1) {
    return buildIntBatch(1, allocator, total, largeRowsValueAt);
}

pub fn buildManyParamsBatch(allocator: std.mem.Allocator, total: usize) !ParamBatch(MANY_PARAMS_COUNT) {
    return buildIntBatch(MANY_PARAMS_COUNT, allocator, total, manyParamsValueAt);
}

pub fn buildAggregateParams(allocator: std.mem.Allocator, total: usize) !ParamBatch(2) {
    return buildIntBatch(2, allocator, total, aggregateValueAt);
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

test "workload parse aliases" {
    try std.testing.expectEqual(Mode.single, Mode.parse("single").?);
    try std.testing.expectEqual(Runner.pgzig, Runner.parse("pg").?);
    try std.testing.expectEqual(Workload.aggregate, Workload.parse("agg").?);
}
