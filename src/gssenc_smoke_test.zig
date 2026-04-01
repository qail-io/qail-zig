const std = @import("std");
const builtin = @import("builtin");
const qail = @import("qail");

const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const PgDriver = qail.PgDriver;
const ConnectOptions = qail.ConnectOptions;
const LinuxKrb5ProviderConfig = qail.LinuxKrb5ProviderConfig;

const DEFAULT_HOST = "pgkerb.local";
const DEFAULT_PORT: u16 = 5432;
const DEFAULT_USER = "ci";
const DEFAULT_DATABASE = "postgres";
const DEFAULT_SERVICE = "postgres";

const SmokeConfig = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    database: []const u8,
    password: ?[]const u8,
    service: []const u8,
    target_name: ?[]const u8,
};

pub fn main() !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("qail-gssenc-smoke is Linux-only; skipping on {s}\n", .{@tagName(builtin.os.tag)});
        return;
    }

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try loadConfig(arena);

    var provider = try qail.linuxKrb5TokenProvider(allocator, LinuxKrb5ProviderConfig{
        .host = cfg.host,
        .service = cfg.service,
        .target_name = cfg.target_name,
    });
    defer provider.deinit();

    const auth_options = provider.authOptions(.{});
    var driver = try PgDriver.connectWithOptions(
        allocator,
        cfg.host,
        cfg.port,
        cfg.user,
        cfg.database,
        cfg.password,
        ConnectOptions{
            .timeout_ms = 15_000,
            .gss_enc_mode = .require,
            .auth_options = auth_options,
        },
    );
    defer driver.deinit();

    const table_name = try std.fmt.allocPrint(allocator, "qail_gssenc_smoke_{d}", .{@abs(std.time.nanoTimestamp())});
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
        .{ .column = "id", .value = .{ .int = 7 } },
        .{ .column = "label", .value = .{ .string = "kerberos-ok" } },
        .{ .column = "active", .value = .{ .bool = true } },
    });
    _ = try driver.execute(&insert_cmd);

    const select_cmd = QailCmd.get(table_name)
        .select(&.{Expr.col("label")})
        .where(&.{
        .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = 7 } } },
    });

    const row = (try driver.fetchOne(&select_cmd)) orelse return error.GssEncSmokeRowMissing;
    var mutable_row = row;
    defer mutable_row.deinit();

    const label = mutable_row.getByName("label") orelse return error.GssEncSmokeMissingLabel;
    if (!std.mem.eql(u8, label, "kerberos-ok")) return error.GssEncSmokeUnexpectedLabel;

    std.debug.print(
        "GSSENC smoke ok: host={s} port={d} user={s} database={s} pid={d}\n",
        .{ cfg.host, cfg.port, cfg.user, cfg.database, driver.backendProcessId() },
    );
}

fn loadConfig(allocator: std.mem.Allocator) !SmokeConfig {
    return .{
        .host = try readEnvOwnedOrDefault(allocator, "PGHOST", DEFAULT_HOST),
        .port = try readEnvU16OrDefault(allocator, "PGPORT", DEFAULT_PORT),
        .user = try readEnvOwnedOrDefault(allocator, "PGUSER", DEFAULT_USER),
        .database = try readEnvOwnedOrDefault(allocator, "PGDATABASE", DEFAULT_DATABASE),
        .password = readEnvOwnedOptional(allocator, "PGPASSWORD") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        },
        .service = try readEnvOwnedOrDefault(allocator, "QAIL_KRB5_SERVICE", DEFAULT_SERVICE),
        .target_name = readEnvOwnedOptional(allocator, "QAIL_KRB5_TARGET_NAME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        },
    };
}

fn readEnvOwnedOptional(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name);
}

fn readEnvOwnedOrDefault(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, fallback),
        else => err,
    };
}

fn readEnvU16OrDefault(allocator: std.mem.Allocator, name: []const u8, fallback: u16) !u16 {
    const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fallback,
        else => return err,
    };
    return std.fmt.parseInt(u16, value, 10);
}
