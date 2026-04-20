const std = @import("std");
const qail = @import("qail");

const process_compat = qail.compat.process;
const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const WhereClause = qail.cmd.WhereClause;
const PgDriver = qail.PgDriver;
const PgBytesRow = qail.PgBytesRow;
const CancelToken = qail.CancelToken;
const Connection = qail.driver.Connection;
const Encoder = qail.protocol.Encoder;
const Decoder = qail.protocol.Decoder;
const AstEncoder = qail.protocol.AstEncoder;

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

fn executeSimpleSql(conn: *Connection, allocator: std.mem.Allocator, sql: []const u8) !void {
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    var saw_error = false;
    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'E' => saw_error = true,
            'Z' => {
                if (saw_error) return error.QueryError;
                return;
            },
            'C', 'I', 'T', 'D', 'n', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }
}

fn querySimpleFirstColumnSql(conn: *Connection, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(sql);
    try conn.send(encoder.getWritten());

    var first_value: ?[]u8 = null;
    errdefer if (first_value) |value| allocator.free(value);
    var saw_error = false;

    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'D' => {
                var decoder = Decoder.init(msg.payload);
                const columns = try decoder.parseDataRowOwned(allocator);
                defer {
                    for (columns) |maybe_col| {
                        if (maybe_col) |col| allocator.free(col);
                    }
                    allocator.free(columns);
                }

                if (first_value == null) {
                    if (columns.len == 0) return error.EmptyRow;
                    const raw = columns[0] orelse return error.NullValue;
                    first_value = try allocator.dupe(u8, raw);
                }
            },
            'E' => saw_error = true,
            'Z' => {
                if (saw_error) return error.QueryError;
                return first_value orelse error.NoRows;
            },
            'T', 'C', 'I', 'n', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }
}

fn executeSimpleAst(conn: *Connection, allocator: std.mem.Allocator, cmd: *const QailCmd) !void {
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(cmd);
    try conn.send(encoder.getWritten());

    var saw_error = false;
    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'E' => saw_error = true,
            'Z' => {
                if (saw_error) return error.QueryError;
                return;
            },
            '1', '2', 'C', 'D', 'T', 'n', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }
}

fn querySimpleFirstColumnAst(conn: *Connection, allocator: std.mem.Allocator, cmd: *const QailCmd) ![]u8 {
    var encoder = AstEncoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeQuery(cmd);
    try conn.send(encoder.getWritten());

    var first_value: ?[]u8 = null;
    errdefer if (first_value) |value| allocator.free(value);
    var saw_error = false;

    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'D' => {
                var decoder = Decoder.init(msg.payload);
                const columns = try decoder.parseDataRowOwned(allocator);
                defer {
                    for (columns) |maybe_col| {
                        if (maybe_col) |col| allocator.free(col);
                    }
                    allocator.free(columns);
                }

                if (first_value == null) {
                    if (columns.len == 0) return error.EmptyRow;
                    const raw = columns[0] orelse return error.NullValue;
                    first_value = try allocator.dupe(u8, raw);
                }
            },
            'E' => saw_error = true,
            'Z' => {
                if (saw_error) return error.QueryError;
                return first_value orelse error.NoRows;
            },
            '1', '2', 'T', 'C', 'n', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }
}

fn prepareStatement(conn: *Connection, allocator: std.mem.Allocator, stmt_name: []const u8, sql: []const u8) !void {
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    try encoder.encodeParse(stmt_name, sql, &.{});
    try encoder.appendSync();
    try conn.send(encoder.getWritten());

    var saw_error = false;
    while (true) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'E' => saw_error = true,
            'Z' => {
                if (saw_error) return error.QueryError;
                return;
            },
            '1', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }
}

fn runExtendedBatchCollectFirstColumnInts(
    conn: *Connection,
    allocator: std.mem.Allocator,
    wire_bytes: []const u8,
    expected_ready_count: usize,
) ![]i64 {
    try conn.send(wire_bytes);

    var values: std.ArrayList(i64) = .empty;
    errdefer values.deinit(allocator);

    var ready_count: usize = 0;
    var saw_error = false;
    while (ready_count < expected_ready_count) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'D' => {
                var decoder = Decoder.init(msg.payload);
                const columns = try decoder.parseDataRowOwned(allocator);
                defer {
                    for (columns) |maybe_col| {
                        if (maybe_col) |col| allocator.free(col);
                    }
                    allocator.free(columns);
                }
                if (columns.len == 0) return error.EmptyRow;
                const raw = columns[0] orelse return error.NullValue;
                const parsed = try std.fmt.parseInt(i64, raw, 10);
                try values.append(allocator, parsed);
            },
            'E' => saw_error = true,
            'Z' => ready_count += 1,
            '2', 'C', 'T', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }

    if (saw_error) return error.QueryError;
    return values.toOwnedSlice(allocator);
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
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    const drop_cmd = QailCmd.drop(TABLE_NAME);
    executeSimpleAst(&conn, allocator, &drop_cmd) catch {};
    defer executeSimpleAst(&conn, allocator, &drop_cmd) catch {};

    const ddl_cols = [_]Expr{
        Expr.defWithConstraints("id", "SERIAL", &.{.primary_key}),
        Expr.defWithConstraints("note", "TEXT", &.{.not_null}),
    };
    const create_cmd = QailCmd.make(TABLE_NAME).select(&ddl_cols);
    executeSimpleAst(&conn, allocator, &create_cmd) catch return error.Case1CreateFailed;

    const server_encoding = try querySimpleFirstColumnSql(&conn, allocator, "SHOW SERVER_ENCODING");
    defer allocator.free(server_encoding);
    const sample_note = if (std.ascii.eqlIgnoreCase(server_encoding, "UTF8"))
        "Odd 😺 雪 text\nline\tquote'"
    else
        "Odd ascii text\nline\tquote'";
    const insert_cmd = QailCmd.add(TABLE_NAME).values(&.{
        .{ .column = "note", .value = .{ .string = sample_note } },
    });
    executeSimpleAst(&conn, allocator, &insert_cmd) catch return error.Case1InsertFailed;

    const note_cmd = QailCmd.get(TABLE_NAME)
        .select(&.{Expr.col("note")})
        .orderBy(&.{.{ .column = "id", .order = .desc }})
        .limit(1);
    const fetched_note = querySimpleFirstColumnAst(&conn, allocator, &note_cmd) catch return error.Case1SelectNoteFailed;
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
    const payload_len_text = querySimpleFirstColumnAst(&conn, allocator, &len_cmd) catch return error.Case1SelectLenFailed;
    defer allocator.free(payload_len_text);
    const parsed_len = try std.fmt.parseInt(usize, payload_len_text, 10);
    if (parsed_len != sample_note.len) return error.UnicodeByteLengthMismatch;
}

fn caseSqlInjectionLiteralContainment(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    const drop_cmd = QailCmd.drop(INJECTION_TABLE);
    executeSimpleAst(&conn, allocator, &drop_cmd) catch {};
    defer executeSimpleAst(&conn, allocator, &drop_cmd) catch {};

    const ddl_cols = [_]Expr{
        Expr.defWithConstraints("id", "SERIAL", &.{.primary_key}),
        Expr.defWithConstraints("note", "TEXT", &.{.not_null}),
    };
    const create_cmd = QailCmd.make(INJECTION_TABLE).select(&ddl_cols);
    executeSimpleAst(&conn, allocator, &create_cmd) catch return error.Case2CreateFailed;

    const payload = "x'); DROP TABLE qail_pentest_injection; --";
    const insert_cmd = QailCmd.add(INJECTION_TABLE).values(&.{
        .{ .column = "note", .value = .{ .string = payload } },
    });
    executeSimpleAst(&conn, allocator, &insert_cmd) catch return error.Case2InsertFailed;

    const count_cmd = QailCmd.get(INJECTION_TABLE).select(&.{Expr.count()});
    const count_text = querySimpleFirstColumnAst(&conn, allocator, &count_cmd) catch return error.Case2CountFailed;
    defer allocator.free(count_text);
    const row_count = try std.fmt.parseInt(usize, count_text, 10);
    if (row_count != 1) return error.SqlInjectionRowCountMismatch;

    const fetched_payload_cmd = QailCmd.get(INJECTION_TABLE).select(&.{Expr.col("note")}).limit(1);
    const fetched_payload = querySimpleFirstColumnAst(&conn, allocator, &fetched_payload_cmd) catch return error.Case2ReadbackFailed;
    defer allocator.free(fetched_payload);
    if (!std.mem.eql(u8, fetched_payload, payload)) return error.SqlInjectionPayloadMismatch;

    const table_exists_count = try querySimpleFirstColumnSql(
        &conn,
        allocator,
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'qail_pentest_injection'",
    );
    defer allocator.free(table_exists_count);
    const exists_count = try std.fmt.parseInt(usize, table_exists_count, 10);
    if (exists_count != 1) return error.SqlInjectionEscapedLiteralExecuted;
}

fn casePortalReuseInterleavedSync(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    const stmt_name = "qail_adv_stmt_portal";
    try prepareStatement(&conn, allocator, stmt_name, "SELECT $1::int4 + 10");

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    const p1 = [_]?[]const u8{"1"};
    const p2 = [_]?[]const u8{"2"};
    const p3 = [_]?[]const u8{"3"};

    try encoder.appendBind("adv_portal", stmt_name, &p1);
    try encoder.appendExecute("adv_portal", 0);
    try encoder.appendSync();

    try encoder.appendBind("adv_portal", stmt_name, &p2);
    try encoder.appendExecute("adv_portal", 0);
    try encoder.appendSync();

    try encoder.appendBind("adv_portal_alt", stmt_name, &p3);
    try encoder.appendExecute("adv_portal_alt", 0);
    try encoder.appendSync();

    const values = try runExtendedBatchCollectFirstColumnInts(&conn, allocator, encoder.getWritten(), 3);
    defer allocator.free(values);

    if (values.len != 3) return error.UnexpectedRowCount;
    if (values[0] != 11 or values[1] != 12 or values[2] != 13) {
        return error.UnexpectedResultValue;
    }
}

fn caseErrorRecoveryAfterFailure(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    const stmt_name = "qail_adv_stmt_div";
    try prepareStatement(&conn, allocator, stmt_name, "SELECT 10 / $1::int4");

    var failing = Encoder.init(allocator);
    defer failing.deinit();
    const bad = [_]?[]const u8{"0"};
    try failing.appendBind("", stmt_name, &bad);
    try failing.appendExecute("", 0);
    try failing.appendSync();

    if (runExtendedBatchCollectFirstColumnInts(&conn, allocator, failing.getWritten(), 1)) |_| {
        return error.ExpectedQueryError;
    } else |err| switch (err) {
        error.QueryError => {},
        else => return err,
    }

    var recovery = Encoder.init(allocator);
    defer recovery.deinit();
    const good = [_]?[]const u8{"2"};
    try recovery.appendBind("", stmt_name, &good);
    try recovery.appendExecute("", 0);
    try recovery.appendSync();

    const values = try runExtendedBatchCollectFirstColumnInts(&conn, allocator, recovery.getWritten(), 1);
    defer allocator.free(values);
    if (values.len != 1 or values[0] != 5) return error.RecoveryFailed;
}

fn caseLargeParamPayload(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    const stmt_name = "qail_adv_stmt_len";
    try prepareStatement(&conn, allocator, stmt_name, "SELECT octet_length($1::text)");

    const payload_len = 512 * 1024;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, idx| {
        const offset: u8 = @intCast(idx % 26);
        byte.* = 'a' + offset;
    }

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    const params = [_]?[]const u8{payload};
    try encoder.appendBind("", stmt_name, &params);
    try encoder.appendExecute("", 0);
    try encoder.appendSync();

    const values = try runExtendedBatchCollectFirstColumnInts(&conn, allocator, encoder.getWritten(), 1);
    defer allocator.free(values);
    if (values.len != 1) return error.UnexpectedRowCount;
    if (values[0] != payload_len) return error.PayloadLengthMismatch;
}

fn caseUnknownStatementRecovery(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

    const stmt_name = "qail_adv_stmt_known";
    try prepareStatement(&conn, allocator, stmt_name, "SELECT $1::int4 + 1");

    var encoder = Encoder.init(allocator);
    defer encoder.deinit();

    const bad = [_]?[]const u8{"9"};
    const good = [_]?[]const u8{"41"};

    try encoder.appendBind("", "qail_adv_stmt_missing", &bad);
    try encoder.appendExecute("", 0);
    try encoder.appendSync();

    try encoder.appendBind("", stmt_name, &good);
    try encoder.appendExecute("", 0);
    try encoder.appendSync();

    try conn.send(encoder.getWritten());

    var values: std.ArrayList(i64) = .empty;
    defer values.deinit(allocator);

    var ready_count: usize = 0;
    var error_count: usize = 0;
    while (ready_count < 2) {
        const msg = try conn.readMessageRawFast();
        switch (msg.msg_type) {
            'D' => {
                var decoder = Decoder.init(msg.payload);
                const columns = try decoder.parseDataRowOwned(allocator);
                defer {
                    for (columns) |maybe_col| {
                        if (maybe_col) |col| allocator.free(col);
                    }
                    allocator.free(columns);
                }
                if (columns.len == 0) return error.EmptyRow;
                const raw = columns[0] orelse return error.NullValue;
                const parsed = try std.fmt.parseInt(i64, raw, 10);
                try values.append(allocator, parsed);
            },
            'E' => error_count += 1,
            'Z' => ready_count += 1,
            '2', 'C', 'T', 'N', 'S', 'A' => {},
            else => return error.UnexpectedBackendMessageType,
        }
    }

    if (error_count == 0) return error.ExpectedProtocolError;
    if (values.items.len == 0) return error.RecoveryQueryMissingResult;
    if (values.items[values.items.len - 1] != 42) return error.RecoveryQueryWrongResult;
}

fn caseAstEmbeddedNulRejected(allocator: std.mem.Allocator, cfg: *const DbConfig) !void {
    var conn = try connectConnection(allocator, cfg);
    defer conn.close();

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

    if (executeSimpleAst(&conn, allocator, &cmd)) |_| {
        return error.ExpectedNullByte;
    } else |err| switch (err) {
        error.NullByte => {},
        else => return err,
    }

    const healthy = try querySimpleFirstColumnSql(&conn, allocator, "SELECT 1");
    defer allocator.free(healthy);
    if (!std.mem.eql(u8, healthy, "1")) return error.ConnectionUnhealthyAfterNullByteReject;
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

    const start_ms = std.Io.Clock.now(.real, qail.compat.io.runtimeIo()).toMilliseconds();
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

    const elapsed_ms = std.Io.Clock.now(.real, qail.compat.io.runtimeIo()).toMilliseconds() - start_ms;
    if (elapsed_ms >= 7_000) return error.CancellationTooLate;

    const health_cmd = QailCmd.get("pg_database").select(&.{Expr.count()});
    const health_row_opt = driver.fetchOne(&health_cmd) catch return error.CancelRecoveryQueryFailed;
    if (health_row_opt == null) return error.CancelRecoveryNoRows;
    var health_row = health_row_opt.?;
    defer health_row.deinit();
    const count = health_row.getInt64(0) orelse return error.CancelRecoveryInvalidCount;
    if (count < 1) return error.CancelRecoveryUnexpectedCount;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var cfg = try loadDbConfig(allocator);
    defer cfg.deinit(allocator);

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

    std.debug.print("  [1] Unicode roundtrip with QAIL DSL...", .{});
    if (caseUnicodeRoundtrip(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [2] SQL injection payload stays literal...", .{});
    if (caseSqlInjectionLiteralContainment(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [3] Portal reuse with interleaved Sync...", .{});
    if (casePortalReuseInterleavedSync(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [4] Error path recovery after division-by-zero...", .{});
    if (caseErrorRecoveryAfterFailure(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [5] Unknown statement desync + recovery...", .{});
    if (caseUnknownStatementRecovery(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [6] AST embedded NUL rejected fail-closed...", .{});
    if (caseAstEmbeddedNulRejected(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [7] Mid-query cancel (stop in the middle) + recover...", .{});
    if (caseMidQueryCancelRecovery(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

    std.debug.print("  [8] Large parameter payload roundtrip (512 KiB)...", .{});
    if (caseLargeParamPayload(allocator, &cfg)) |_| {
        std.debug.print(" ✓\n", .{});
        passed += 1;
    } else |err| {
        std.debug.print(" ✗ {s}\n", .{@errorName(err)});
        failed += 1;
    }

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
