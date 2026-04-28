const std = @import("std");
const qail = @import("qail");

const process_compat = qail.runtime.process;
const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const WhereClause = qail.ast.cmd.WhereClause;
const PgDriver = qail.driver.driver.PgDriver;
const CancelToken = qail.driver.driver.CancelToken;
const Connection = qail.driver.connection.Connection;
const Pipeline = qail.driver.pipeline.Pipeline;

const TABLE_NAME = "qail_adversarial_cases";
const INJECTION_TABLE = "qail_pentest_injection";

const DbConfig = struct {
    host: []u8,
    port: u16,
    user: []u8,
    database: []u8,
    password: ?[]u8 = null,

    fn deinit(self: *DbConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.database);
        if (self.password) |p| allocator.free(p);
    }
};

fn readEnvOwnedOrDefault(allocator: std.mem.Allocator, key: []const u8, default_value: []const u8) ![]u8 {
    return process_compat.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, default_value),
        else => err,
    };
}

fn readEnvU16OrDefault(allocator: std.mem.Allocator, key: []const u8, default_value: u16) !u16 {
    const raw = process_compat.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return err,
    };
    defer allocator.free(raw);
    return std.fmt.parseInt(u16, raw, 10);
}

fn readEnvOptionalOwned(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    return process_compat.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn readOptionalCaseFilter(allocator: std.mem.Allocator, args: std.process.Args) !?[]u8 {
    if (try readEnvOptionalOwned(allocator, "QAIL_ADVERSARIAL_CASE")) |value| return value;

    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    const case_id = it.next() orelse return null;
    return try allocator.dupe(u8, case_id);
}

fn loadDbConfig(allocator: std.mem.Allocator) !DbConfig {
    return .{
        .host = try readEnvOwnedOrDefault(allocator, "PGHOST", "127.0.0.1"),
        .port = try readEnvU16OrDefault(allocator, "PGPORT", 5432),
        .user = try readEnvOwnedOrDefault(allocator, "PGUSER", "orion"),
        .database = try readEnvOwnedOrDefault(allocator, "PGDATABASE", "postgres"),
        .password = try readEnvOptionalOwned(allocator, "PGPASSWORD"),
    };
}

fn connectConnection(allocator: std.mem.Allocator, cfg: *const DbConfig) !Connection {
    var conn = try Connection.connect(allocator, cfg.host, cfg.port);
    errdefer conn.close();
    try conn.startup(cfg.user, cfg.database, cfg.password);
    return conn;
}

fn connectDriver(allocator: std.mem.Allocator, cfg: *const DbConfig) !PgDriver {
    if (cfg.password) |password| {
        return PgDriver.connectWithPassword(
            allocator,
            cfg.host,
            cfg.port,
            cfg.user,
            cfg.database,
            password,
        );
    }
    return PgDriver.connect(
        allocator,
        cfg.host,
        cfg.port,
        cfg.user,
        cfg.database,
    );
}

fn deinitRows(allocator: std.mem.Allocator, rows: []qail.driver.row.PgRow) void {
    for (rows) |*row| row.deinit();
    allocator.free(rows);
}

fn executeCmd(driver: *PgDriver, cmd: *const QailCmd) !void {
    _ = try driver.execute(cmd);
}

fn queryFirstColumnOwned(driver: *PgDriver, allocator: std.mem.Allocator, cmd: *const QailCmd) ![]u8 {
    var row = (try driver.fetchOne(cmd)) orelse return error.NoRows;
    defer row.deinit();
    const raw = row.getString(0) orelse return error.NullValue;
    return try allocator.dupe(u8, raw);
}

fn queryFirstColumnInt(driver: *PgDriver, cmd: *const QailCmd) !i64 {
    var row = (try driver.fetchOne(cmd)) orelse return error.NoRows;
    defer row.deinit();
    return row.getInt64(0) orelse return error.InvalidInteger;
}

fn fetchPreparedFirstColumnInt(driver: *PgDriver, allocator: std.mem.Allocator, stmt_name: []const u8, params: []const ?[]const u8) !i64 {
    const rows = try driver.fetchPrepared(stmt_name, params);
    defer deinitRows(allocator, rows);
    if (rows.len == 0) return error.NoRows;
    return rows[0].getInt64(0) orelse return error.InvalidInteger;
}

const CancelWorkerCtx = struct {
    token: CancelToken,
    allocator: std.mem.Allocator,
    delay_ms: i64,
    send_err: ?anyerror = null,
};

fn spinSleepMs(delay_ms: i64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const start_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
    while (std.Io.Clock.now(.awake, io).toMilliseconds() - start_ms < delay_ms) {
        std.Thread.yield() catch {};
    }
}

fn runCancelWorker(ctx: *CancelWorkerCtx) void {
    spinSleepMs(ctx.delay_ms);
    ctx.token.cancelQuery(ctx.allocator) catch |err| {
        ctx.send_err = err;
    };
}

fn caseUnicodeRoundtrip(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const drop_cmd = QailCmd.drop(TABLE_NAME);
    executeCmd(&driver, &drop_cmd) catch {};
    defer executeCmd(&driver, &drop_cmd) catch {};

    const ddl_cols = [_]Expr{
        Expr.defWithConstraints("id", "SERIAL", &.{.primary_key}),
        Expr.defWithConstraints("note", "TEXT", &.{.not_null}),
    };
    const create_cmd = QailCmd.make(TABLE_NAME).select(&ddl_cols);
    executeCmd(&driver, &create_cmd) catch return error.Case1CreateFailed;

    const server_encoding_where = [_]WhereClause{.{
        .condition = .{
            .column = "name",
            .op = .eq,
            .value = .{ .string = "server_encoding" },
        },
    }};
    const server_encoding_cmd = QailCmd.get("pg_settings")
        .select(&.{Expr.col("setting")})
        .where(&server_encoding_where)
        .limit(1);
    const server_encoding = try queryFirstColumnOwned(&driver, allocator, &server_encoding_cmd);
    defer allocator.free(server_encoding);
    const sample_note = if (std.ascii.eqlIgnoreCase(server_encoding, "UTF8"))
        "Odd 😺 雪 text\nline\tquote'"
    else
        "Odd ascii text\nline\tquote'";
    const insert_cmd = QailCmd.add(TABLE_NAME).values(&.{
        .{ .column = "note", .value = .{ .string = sample_note } },
    });
    executeCmd(&driver, &insert_cmd) catch return error.Case1InsertFailed;

    const note_cmd = QailCmd.get(TABLE_NAME)
        .select(&.{Expr.col("note")})
        .orderBy(&.{.{ .column = "id", .order = .desc }})
        .limit(1);
    const fetched_note = queryFirstColumnOwned(&driver, allocator, &note_cmd) catch return error.Case1SelectNoteFailed;
    defer allocator.free(fetched_note);
    if (!std.mem.eql(u8, fetched_note, sample_note)) return error.UnicodeRoundtripMismatch;

    const note_col = Expr.col("note");
    const note_len_expr: Expr = .{
        .func_call = .{
            .name = "octet_length",
            .args = &[_]Expr{note_col},
            .alias = null,
        },
    };
    const len_cmd = QailCmd.get(TABLE_NAME)
        .select(&.{note_len_expr})
        .orderBy(&.{.{ .column = "id", .order = .desc }})
        .limit(1);
    const payload_len_text = queryFirstColumnOwned(&driver, allocator, &len_cmd) catch return error.Case1SelectLenFailed;
    defer allocator.free(payload_len_text);
    const parsed_len = try std.fmt.parseInt(usize, payload_len_text, 10);
    if (parsed_len != sample_note.len) return error.UnicodeByteLengthMismatch;
}

fn caseSqlInjectionLiteralContainment(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const drop_cmd = QailCmd.drop(INJECTION_TABLE);
    executeCmd(&driver, &drop_cmd) catch {};
    defer executeCmd(&driver, &drop_cmd) catch {};

    const ddl_cols = [_]Expr{
        Expr.defWithConstraints("id", "SERIAL", &.{.primary_key}),
        Expr.defWithConstraints("note", "TEXT", &.{.not_null}),
    };
    const create_cmd = QailCmd.make(INJECTION_TABLE).select(&ddl_cols);
    executeCmd(&driver, &create_cmd) catch return error.Case2CreateFailed;

    const payload = "x'); DROP TABLE qail_pentest_injection; --";
    const insert_cmd = QailCmd.add(INJECTION_TABLE).values(&.{
        .{ .column = "note", .value = .{ .string = payload } },
    });
    executeCmd(&driver, &insert_cmd) catch return error.Case2InsertFailed;

    const count_cmd = QailCmd.get(INJECTION_TABLE).select(&.{Expr.count()});
    const count_text = queryFirstColumnOwned(&driver, allocator, &count_cmd) catch return error.Case2CountFailed;
    defer allocator.free(count_text);
    const row_count = try std.fmt.parseInt(usize, count_text, 10);
    if (row_count != 1) return error.SqlInjectionRowCountMismatch;

    const fetched_payload_cmd = QailCmd.get(INJECTION_TABLE).select(&.{Expr.col("note")}).limit(1);
    const fetched_payload = queryFirstColumnOwned(&driver, allocator, &fetched_payload_cmd) catch return error.Case2ReadbackFailed;
    defer allocator.free(fetched_payload);
    if (!std.mem.eql(u8, fetched_payload, payload)) return error.SqlInjectionPayloadMismatch;

    const table_exists_where = [_]WhereClause{
        .{
            .condition = .{
                .column = "table_schema",
                .op = .eq,
                .value = .{ .string = "public" },
            },
        },
        .{
            .condition = .{
                .column = "table_name",
                .op = .eq,
                .value = .{ .string = INJECTION_TABLE },
            },
        },
    };
    const table_exists_cmd = QailCmd.get("information_schema.tables")
        .select(&.{Expr.count()})
        .where(&table_exists_where);
    const table_exists_count = try queryFirstColumnOwned(&driver, allocator, &table_exists_cmd);
    defer allocator.free(table_exists_count);
    const exists_count = try std.fmt.parseInt(usize, table_exists_count, 10);
    if (exists_count != 1) return error.SqlInjectionEscapedLiteralExecuted;
}

fn casePortalReuseInterleavedSync(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const stmt_name = "qail_adv_stmt_portal";
    const param = Expr.param(1);
    const cast_param: Expr = .{
        .cast = .{
            .expr = &param,
            .target_type = "int4",
            .alias = null,
        },
    };
    const ten = Expr.int(10);
    const add_expr: Expr = .{
        .binary = .{
            .left = &cast_param,
            .op = .add,
            .right = &ten,
            .alias = null,
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{add_expr})
        .limit(1);
    try driver.prepare(stmt_name, &cmd);

    const p1 = [_]?[]const u8{"1"};
    const p2 = [_]?[]const u8{"2"};
    const p3 = [_]?[]const u8{"3"};
    const v1 = try fetchPreparedFirstColumnInt(&driver, allocator, stmt_name, &p1);
    const v2 = try fetchPreparedFirstColumnInt(&driver, allocator, stmt_name, &p2);
    const v3 = try fetchPreparedFirstColumnInt(&driver, allocator, stmt_name, &p3);

    if (v1 != 11 or v2 != 12 or v3 != 13) {
        return error.UnexpectedResultValue;
    }
}

fn caseErrorRecoveryAfterFailure(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const stmt_name = "qail_adv_stmt_div";
    const ten = Expr.int(10);
    const param = Expr.param(1);
    const cast_param: Expr = .{
        .cast = .{
            .expr = &param,
            .target_type = "int4",
            .alias = null,
        },
    };
    const div_expr: Expr = .{
        .binary = .{
            .left = &ten,
            .op = .div,
            .right = &cast_param,
            .alias = null,
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{div_expr})
        .limit(1);
    try driver.prepare(stmt_name, &cmd);

    const bad = [_]?[]const u8{"0"};
    if (driver.fetchPrepared(stmt_name, &bad)) |rows| {
        deinitRows(allocator, rows);
        return error.ExpectedQueryError;
    } else |err| switch (err) {
        error.QueryError => {},
        else => return err,
    }

    const good = [_]?[]const u8{"2"};
    const value = try fetchPreparedFirstColumnInt(&driver, allocator, stmt_name, &good);
    if (value != 5) return error.RecoveryFailed;
}

fn casePipelineErrorSkipsRemainingQueries(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var setup_driver = try connectDriver(allocator, cfg);
    defer setup_driver.deinit();

    const drop_cmd = QailCmd.drop("qail_adv_pipeline_fail");
    executeCmd(&setup_driver, &drop_cmd) catch {};
    defer executeCmd(&setup_driver, &drop_cmd) catch {};

    const ddl_cols = [_]Expr{
        Expr.defWithConstraints("value", "INTEGER", &.{.not_null}),
    };
    const create_cmd = QailCmd.make("qail_adv_pipeline_fail").select(&ddl_cols);
    try executeCmd(&setup_driver, &create_cmd);

    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    var pipeline = Pipeline.init(&conn, allocator);
    defer pipeline.deinit();

    const insert_value = QailCmd.add("qail_adv_pipeline_fail").values(&.{
        .{ .column = "value", .value = .{ .param = 1 } },
    });
    const stmt = try pipeline.getOrPrepare(&insert_value);

    const first = [_]?[]const u8{"1"};
    const failing = [_]?[]const u8{"broken"};
    const third = [_]?[]const u8{"3"};
    const batch = [_][]const ?[]const u8{
        first[0..],
        failing[0..],
        third[0..],
    };

    if (pipeline.pipelinePreparedFast(stmt, batch[0..])) |_| {
        return error.ExpectedQueryError;
    } else |err| switch (err) {
        error.QueryError => {},
        else => return err,
    }

    const failure = pipeline.lastFailure() orelse return error.MissingPipelineFailureMetadata;
    if (failure.expected_queries != 3) return error.UnexpectedPipelineExpectedCount;
    if (failure.completed_queries != 1) return error.UnexpectedPipelineCompletedCount;
    if (failure.failed_query_index != 1) return error.UnexpectedPipelineFailureIndex;
    if (failure.skipped_queries_after_failure != 1) return error.UnexpectedPipelineSkippedCount;
    if (!failure.drained_to_ready) return error.PipelineDidNotDrainAfterError;
    if (failure.cycle_rolled_back != true) return error.MissingPipelineRollbackSemantics;
    if (failure.sqlstate == null or !std.mem.eql(u8, failure.sqlstate.?, "22P02")) {
        return error.UnexpectedPipelineFailureSqlstate;
    }
    const failure_message = failure.message orelse return error.MissingPipelineFailureMessage;
    if (std.mem.indexOf(u8, failure_message, "invalid input syntax for type integer") == null) {
        return error.UnexpectedPipelineFailureMessage;
    }

    const count_cmd = QailCmd.get("qail_adv_pipeline_fail").select(&.{Expr.count()});
    const rolled_back_count: usize = @intCast(try queryFirstColumnInt(&setup_driver, &count_cmd));
    if (rolled_back_count != 0) return error.PipelineFailureUnexpectedCommittedRowCount;

    const recovery = [_]?[]const u8{"42"};
    const recovery_batch = [_][]const ?[]const u8{recovery[0..]};
    const completed = try pipeline.pipelinePreparedFast(stmt, recovery_batch[0..]);
    if (completed != 1) return error.PipelineRecoveryUnexpectedCompletionCount;
    if (pipeline.lastFailure() != null) return error.StalePipelineFailureMetadata;

    const committed_cmd = QailCmd.get("qail_adv_pipeline_fail")
        .select(&.{Expr.col("value")})
        .orderBy(&.{.{ .column = "value", .order = .asc }})
        .limit(1);
    const committed_value = try queryFirstColumnInt(&setup_driver, &committed_cmd);
    if (committed_value != 42) return error.PipelineFailureUnexpectedCommittedValues;

    const health_cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{Expr.int(99)})
        .limit(1);
    const health = try queryFirstColumnInt(&setup_driver, &health_cmd);
    if (health != 99) return error.ConnectionUnhealthyAfterPipelineFailure;
}

fn caseLargeParamPayload(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const stmt_name = "qail_adv_stmt_len";
    const param = Expr.param(1);
    const cast_param: Expr = .{
        .cast = .{
            .expr = &param,
            .target_type = "text",
            .alias = null,
        },
    };
    const len_expr: Expr = .{
        .func_call = .{
            .name = "octet_length",
            .args = &[_]Expr{cast_param},
            .alias = null,
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{len_expr})
        .limit(1);
    try driver.prepare(stmt_name, &cmd);

    const payload_len = 512 * 1024;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, idx| {
        const offset: u8 = @intCast(idx % 26);
        byte.* = 'a' + offset;
    }

    const params = [_]?[]const u8{payload};
    const value = try fetchPreparedFirstColumnInt(&driver, allocator, stmt_name, &params);
    if (value != payload_len) return error.PayloadLengthMismatch;
}

fn caseUnknownStatementRecovery(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const stmt_name = "qail_adv_stmt_known";
    const param = Expr.param(1);
    const cast_param: Expr = .{
        .cast = .{
            .expr = &param,
            .target_type = "int4",
            .alias = null,
        },
    };
    const one = Expr.int(1);
    const add_expr: Expr = .{
        .binary = .{
            .left = &cast_param,
            .op = .add,
            .right = &one,
            .alias = null,
        },
    };
    const cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{add_expr})
        .limit(1);
    try driver.prepare(stmt_name, &cmd);

    const bad = [_]?[]const u8{"9"};
    const good = [_]?[]const u8{"41"};

    if (driver.fetchPrepared("qail_adv_stmt_missing", &bad)) |rows| {
        deinitRows(allocator, rows);
        return error.ExpectedProtocolError;
    } else |err| switch (err) {
        error.QueryError, error.PreparedStatementRetryable => {},
        else => return err,
    }

    const value = try fetchPreparedFirstColumnInt(&driver, allocator, stmt_name, &good);
    if (value != 42) return error.RecoveryQueryWrongResult;
}

fn caseAstEmbeddedNulRejected(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const where = [_]WhereClause{
        .{
            .condition = .{
                .column = "datname",
                .op = .eq,
                .value = .{ .string = "po\x00stgres" },
            },
        },
    };
    const cmd = QailCmd.get("pg_database")
        .select(&.{Expr.col("datname")})
        .where(&where)
        .limit(1);

    if (driver.fetchAll(&cmd)) |rows| {
        deinitRows(allocator, rows);
        return error.ExpectedNullByte;
    } else |err| switch (err) {
        error.NullByte => {},
        else => return err,
    }

    const health_cmd = QailCmd.get("pg_catalog.pg_database")
        .select(&.{Expr.int(1)})
        .limit(1);
    const healthy = try queryFirstColumnInt(&driver, &health_cmd);
    if (healthy != 1) return error.ConnectionUnhealthyAfterNullByteReject;
}

fn caseMidQueryCancelRecovery(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var driver = try connectDriver(allocator, cfg);
    defer driver.deinit();

    const cancel_delay_ms = blk: {
        const raw = process_compat.getEnvVarOwned(allocator, "QAIL_CANCEL_DELAY_MS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk @as(i64, 300),
            else => return err,
        };
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(i64, raw, 10);
    };

    const token = try driver.cancelToken();
    var cancel_ctx = CancelWorkerCtx{
        .token = token,
        .allocator = allocator,
        .delay_ms = cancel_delay_ms,
    };
    var worker = try std.Thread.spawn(.{}, runCancelWorker, .{&cancel_ctx});
    var worker_joined = false;
    defer if (!worker_joined) worker.join();

    const sleep_arg = Expr.str("8 seconds");
    const sleep_interval: Expr = .{
        .cast = .{
            .expr = &sleep_arg,
            .target_type = "interval",
            .alias = null,
        },
    };
    const sleep_expr: Expr = .{
        .func_call = .{
            .name = "pg_sleep_for",
            .args = &[_]Expr{sleep_interval},
            .alias = null,
        },
    };
    const long_cmd = QailCmd.get("pg_database").select(&.{sleep_expr}).limit(1);

    const start_ms = std.Io.Clock.now(.real, qail.runtime.io.runtimeIo()).toMilliseconds();
    if (driver.fetchAll(&long_cmd)) |rows| {
        for (rows) |*row| row.deinit();
        allocator.free(rows);
        worker.join();
        worker_joined = true;
        return error.ExpectedQueryCancellation;
    } else |err| switch (err) {
        error.QueryError => {},
        else => return err,
    }

    worker.join();
    worker_joined = true;
    if (cancel_ctx.send_err) |send_err| return send_err;

    const elapsed_ms = std.Io.Clock.now(.real, qail.runtime.io.runtimeIo()).toMilliseconds() - start_ms;
    if (elapsed_ms >= 7_000) return error.CancellationTooLate;

    const health_cmd = QailCmd.get("pg_database").select(&.{Expr.count()});
    const health_row_opt = driver.fetchOne(&health_cmd) catch return error.CancelRecoveryQueryFailed;
    if (health_row_opt == null) return error.CancelRecoveryNoRows;
    var health_row = health_row_opt.?;
    defer health_row.deinit();
    const count = health_row.getInt64(0) orelse return error.CancelRecoveryInvalidCount;
    if (count < 1) return error.CancelRecoveryUnexpectedCount;
}

fn shouldRunAdversarialCase(case_filter: ?[]const u8, case_id: []const u8) bool {
    const filter = case_filter orelse return true;
    return std.mem.eql(u8, filter, case_id);
}

fn runAdversarialCase(
    case_filter: ?[]const u8,
    case_id: []const u8,
    label: []const u8,
    allocator: std.mem.Allocator,
    cfg: *const DbConfig,
    case_fn: anytype,
    passed: *usize,
    failed: *usize,
) void {
    std.debug.print("  [{s}] {s}...", .{ case_id, label });
    if (!shouldRunAdversarialCase(case_filter, case_id)) {
        std.debug.print(" skipped\n", .{});
        return;
    }

    if (case_fn(allocator, cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed.* += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed.* += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var cfg = try loadDbConfig(allocator);
    defer cfg.deinit(allocator);
    const case_filter = try readOptionalCaseFilter(allocator, init.minimal.args);
    defer if (case_filter) |value| allocator.free(value);

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  QAIL Zig Adversarial Integration Suite                   ║\n", .{});
    std.debug.print("╠════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Host: {s}:{d}\n", .{ cfg.host, cfg.port });
    std.debug.print("║  User: {s}\n", .{cfg.user});
    std.debug.print("║  DB:   {s}\n", .{cfg.database});
    std.debug.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;
    runAdversarialCase(case_filter, "1", "Unicode roundtrip with QAIL DSL", allocator, &cfg, caseUnicodeRoundtrip, &passed, &failed);
    runAdversarialCase(case_filter, "2", "SQL injection payload stays literal", allocator, &cfg, caseSqlInjectionLiteralContainment, &passed, &failed);
    runAdversarialCase(case_filter, "3", "Prepared statement reuse through public API", allocator, &cfg, casePortalReuseInterleavedSync, &passed, &failed);
    runAdversarialCase(case_filter, "4", "Error path recovery after division-by-zero", allocator, &cfg, caseErrorRecoveryAfterFailure, &passed, &failed);
    runAdversarialCase(case_filter, "5", "Unknown statement error + recovery", allocator, &cfg, caseUnknownStatementRecovery, &passed, &failed);
    runAdversarialCase(case_filter, "6", "AST embedded NUL rejected fail-closed", allocator, &cfg, caseAstEmbeddedNulRejected, &passed, &failed);
    runAdversarialCase(case_filter, "7", "Mid-query cancel (stop in the middle) + recover", allocator, &cfg, caseMidQueryCancelRecovery, &passed, &failed);
    runAdversarialCase(case_filter, "8", "Large parameter payload roundtrip (512 KiB)", allocator, &cfg, caseLargeParamPayload, &passed, &failed);
    runAdversarialCase(case_filter, "9", "Pipeline failure skips remaining queries + recovers", allocator, &cfg, casePipelineErrorSkipsRemainingQueries, &passed, &failed);

    std.debug.print("\n", .{});
    std.debug.print("────────────────────────────────────────────────────────────\n", .{});
    if (failed == 0) {
        std.debug.print("  ✓ ALL {d} ADVERSARIAL TESTS PASSED\n", .{passed});
    } else {
        std.debug.print("  ✗ {d} passed, {d} failed\n", .{ passed, failed });
    }
    std.debug.print("────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("\n", .{});

    if (failed > 0) return error.AdversarialTestsFailed;
}
