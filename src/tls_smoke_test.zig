const std = @import("std");
const qail = @import("qail");
const process_compat = qail.runtime.process;

const QailCmd = qail.ast.QailCmd;
const Expr = qail.ast.Expr;
const PgDriver = qail.driver.driver.PgDriver;
const ConnectOptions = qail.driver.connect_url.ConnectOptions;
const auth_options_mod = qail.driver.auth_options;
const tls_mod = qail.driver.tls;

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT: u16 = 5432;
const DEFAULT_USER = "qail_scram";
const DEFAULT_DATABASE = "postgres";
const DEFAULT_SERVER_NAME = "localhost";

const CliArgs = struct {
    password: ?[]const u8 = null,
    scram_channel_binding: ?auth_options_mod.ScramChannelBindingMode = null,
    server_name: ?[]const u8 = null,
    verify_mode: ?tls_mod.VerifyMode = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    user: ?[]const u8 = null,
    database: ?[]const u8 = null,
};

const SmokeConfig = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    database: []const u8,
    password: []const u8,
    server_name: []const u8,
    verify_mode: tls_mod.VerifyMode,
    scram_channel_binding: auth_options_mod.ScramChannelBindingMode,
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const cli_args = try parseArgs(args);
    const cfg = try loadConfig(arena, cli_args);

    var driver = try PgDriver.connectWithOptions(
        allocator,
        cfg.host,
        cfg.port,
        cfg.user,
        cfg.database,
        cfg.password,
        ConnectOptions{
            .timeout_ms = 15_000,
            .tls_mode = .require,
            .tls_config = .{
                .server_name = cfg.server_name,
                .verify = cfg.verify_mode,
            },
            .auth_options = .{
                .scram_channel_binding = cfg.scram_channel_binding,
            },
        },
    );
    defer driver.deinit();

    const now_ns = std.Io.Clock.now(.real, qail.runtime.io.runtimeIo()).toNanoseconds();
    const table_name = try std.fmt.allocPrint(allocator, "qail_tls_smoke_{d}", .{now_ns});
    defer allocator.free(table_name);

    const drop_cmd = QailCmd.drop(table_name);
    _ = driver.execute(&drop_cmd) catch {};
    defer _ = driver.execute(&drop_cmd) catch {};

    const ddl_cols = [_]Expr{
        Expr.defWithConstraints("id", "INTEGER", &.{.primary_key}),
        Expr.defWithConstraints("label", "TEXT", &.{.not_null}),
        Expr.defWithConstraints("active", "BOOLEAN", &.{.not_null}),
    };
    const create_cmd = QailCmd.make(table_name).select(&ddl_cols);
    _ = try driver.execute(&create_cmd);

    const insert_cmd = QailCmd.add(table_name).values(&.{
        .{ .column = "id", .value = .{ .int = 11 } },
        .{ .column = "label", .value = .{ .string = "tls-ok" } },
        .{ .column = "active", .value = .{ .bool = true } },
    });
    _ = try driver.execute(&insert_cmd);

    const select_cmd = QailCmd.get(table_name)
        .select(&.{Expr.col("label")})
        .where(&.{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = 11 } } },
    });

    const row = (try driver.fetchOne(&select_cmd)) orelse return error.TlsSmokeRowMissing;
    var mutable_row = row;
    defer mutable_row.deinit();

    const label = mutable_row.getByName("label") orelse return error.TlsSmokeMissingLabel;
    if (!std.mem.eql(u8, label, "tls-ok")) return error.TlsSmokeUnexpectedLabel;

    std.debug.print(
        "TLS smoke ok: host={s} port={d} user={s} database={s} backend={s} cb={s} pid={d}\n",
        .{
            cfg.host,
            cfg.port,
            cfg.user,
            cfg.database,
            @tagName(driver.ioBackend()),
            @tagName(cfg.scram_channel_binding),
            driver.backendProcessId(),
        },
    );
}

fn loadConfig(allocator: std.mem.Allocator, cli_args: CliArgs) !SmokeConfig {
    return .{
        .host = if (cli_args.host) |value| try allocator.dupe(u8, value) else try readEnvOwnedOrDefault(allocator, "PGHOST", DEFAULT_HOST),
        .port = cli_args.port orelse try readEnvU16OrDefault(allocator, "PGPORT", DEFAULT_PORT),
        .user = if (cli_args.user) |value| try allocator.dupe(u8, value) else try readEnvOwnedOrDefault(allocator, "PGUSER", DEFAULT_USER),
        .database = if (cli_args.database) |value| try allocator.dupe(u8, value) else try readEnvOwnedOrDefault(allocator, "PGDATABASE", DEFAULT_DATABASE),
        .password = try readPassword(allocator, cli_args.password),
        .server_name = if (cli_args.server_name) |value| try allocator.dupe(u8, value) else try readEnvOwnedOrDefault(allocator, "QAIL_TLS_SERVER_NAME", DEFAULT_SERVER_NAME),
        .verify_mode = cli_args.verify_mode orelse try readVerifyModeOrDefault(allocator, "QAIL_TLS_VERIFY", .self_signed),
        .scram_channel_binding = cli_args.scram_channel_binding orelse try readChannelBindingModeOrDefault(allocator, "QAIL_SCRAM_CHANNEL_BINDING", .disable),
    };
}

fn parseArgs(args: []const [:0]const u8) !CliArgs {
    var parsed: CliArgs = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i >= args.len) return error.MissingPasswordArg;
            parsed.password = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--password=")) {
            parsed.password = arg["--password=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--channel-binding")) {
            i += 1;
            if (i >= args.len) return error.MissingChannelBindingArg;
            parsed.scram_channel_binding = auth_options_mod.ScramChannelBindingMode.parse(args[i]) orelse return error.InvalidScramChannelBindingMode;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--channel-binding=")) {
            parsed.scram_channel_binding = auth_options_mod.ScramChannelBindingMode.parse(arg["--channel-binding=".len..]) orelse return error.InvalidScramChannelBindingMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--server-name")) {
            i += 1;
            if (i >= args.len) return error.MissingServerNameArg;
            parsed.server_name = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--server-name=")) {
            parsed.server_name = arg["--server-name=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--verify")) {
            i += 1;
            if (i >= args.len) return error.MissingVerifyArg;
            parsed.verify_mode = try parseVerifyMode(args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--verify=")) {
            parsed.verify_mode = try parseVerifyMode(arg["--verify=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHostArg;
            parsed.host = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--host=")) {
            parsed.host = arg["--host=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPortArg;
            parsed.port = try std.fmt.parseInt(u16, args[i], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            parsed.port = try std.fmt.parseInt(u16, arg["--port=".len..], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i >= args.len) return error.MissingUserArg;
            parsed.user = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--user=")) {
            parsed.user = arg["--user=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--database")) {
            i += 1;
            if (i >= args.len) return error.MissingDatabaseArg;
            parsed.database = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--database=")) {
            parsed.database = arg["--database=".len..];
            continue;
        }

        return error.UnknownArgument;
    }

    return parsed;
}

fn readPassword(allocator: std.mem.Allocator, cli_password: ?[]const u8) ![]u8 {
    if (cli_password) |password| return allocator.dupe(u8, password);
    return process_compat.getEnvVarOwned(allocator, "PGPASSWORD") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.PasswordRequired,
        else => err,
    };
}

fn parseVerifyMode(value: []const u8) !tls_mod.VerifyMode {
    if (std.ascii.eqlIgnoreCase(value, "no_verification") or
        std.ascii.eqlIgnoreCase(value, "disable") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return .no_verification;
    }
    if (std.ascii.eqlIgnoreCase(value, "self_signed") or
        std.ascii.eqlIgnoreCase(value, "self-signed") or
        std.ascii.eqlIgnoreCase(value, "require"))
    {
        return .self_signed;
    }
    return error.InvalidTlsVerifyMode;
}

fn readVerifyModeOrDefault(
    allocator: std.mem.Allocator,
    name: []const u8,
    fallback: tls_mod.VerifyMode,
) !tls_mod.VerifyMode {
    const value = process_compat.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fallback,
        else => return err,
    };

    return parseVerifyMode(value);
}

fn readChannelBindingModeOrDefault(
    allocator: std.mem.Allocator,
    name: []const u8,
    fallback: auth_options_mod.ScramChannelBindingMode,
) !auth_options_mod.ScramChannelBindingMode {
    const value = process_compat.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fallback,
        else => return err,
    };
    return auth_options_mod.ScramChannelBindingMode.parse(value) orelse error.InvalidScramChannelBindingMode;
}

fn readEnvOwnedOrDefault(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]u8 {
    return process_compat.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, fallback),
        else => err,
    };
}

fn readEnvU16OrDefault(allocator: std.mem.Allocator, name: []const u8, fallback: u16) !u16 {
    const value = process_compat.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fallback,
        else => return err,
    };
    return std.fmt.parseInt(u16, value, 10);
}
