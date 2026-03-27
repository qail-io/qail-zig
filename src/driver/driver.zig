// PostgreSQL Driver
//
// Main driver struct for executing QAIL AST queries.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const process = @import("../compat/process.zig");
const protocol = @import("../protocol/mod.zig");
const conn_mod = @import("connection.zig");
const auth_options_mod = @import("auth_options.zig");
const tls_driver_mod = @import("tls.zig");
const cancel_mod = @import("cancel.zig");
const row_mod = @import("row.zig");
const query_mod = @import("query.zig");
const copy_mod = @import("copy.zig");
const io_backend_mod = @import("io_backend.zig");
const rls_mod = @import("rls.zig");
const transpiler = @import("../transpiler/postgres.zig");

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const AstEncoder = protocol.AstEncoder;
const PgEncoder = protocol.Encoder;
const StartupParam = PgEncoder.StartupParam;
const Decoder = protocol.Decoder;
const BackendMessage = protocol.BackendMessage;
const FieldDescription = protocol.wire.FieldDescription;
const Connection = conn_mod.Connection;
const AuthOptions = conn_mod.AuthOptions;
const TlsConnection = tls_driver_mod.TlsConnection;
const TlsConfig = tls_driver_mod.TlsConfig;
const CancelKey = cancel_mod.CancelKey;
const PgRow = row_mod.PgRow;
const StatementCache = query_mod.StatementCache;
const MessageResult = struct {
    msg_type: BackendMessage,
    payload: []const u8,
};

/// LISTEN/NOTIFY message from PostgreSQL.
pub const Notification = struct {
    /// PID of the backend that sent NOTIFY.
    process_id: i32,
    /// Notification channel.
    channel: []u8,
    /// Notification payload (may be empty).
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Notification) void {
        self.allocator.free(self.channel);
        self.allocator.free(self.payload);
    }
};

/// Startup metadata from `IDENTIFY_SYSTEM`.
pub const IdentifySystem = struct {
    system_id: []u8,
    timeline: u32,
    xlog_pos: []u8,
    dbname: ?[]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IdentifySystem) void {
        self.allocator.free(self.system_id);
        self.allocator.free(self.xlog_pos);
        if (self.dbname) |dbname| self.allocator.free(dbname);
    }
};

/// Output from `CREATE_REPLICATION_SLOT ... LOGICAL ...`.
pub const ReplicationSlotInfo = struct {
    slot_name: []u8,
    consistent_point: []u8,
    snapshot_name: ?[]u8,
    output_plugin: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplicationSlotInfo) void {
        self.allocator.free(self.slot_name);
        self.allocator.free(self.consistent_point);
        if (self.snapshot_name) |snapshot_name| self.allocator.free(snapshot_name);
        self.allocator.free(self.output_plugin);
    }
};

/// Logical replication option (`k 'v'`) used by START_REPLICATION.
pub const ReplicationOption = struct {
    key: []const u8,
    value: []const u8,
};

/// Metadata returned by START_REPLICATION CopyBoth response.
pub const ReplicationStreamStart = struct {
    format: u8,
    column_formats: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplicationStreamStart) void {
        self.allocator.free(self.column_formats);
    }
};

/// Replication XLogData message (`CopyData('w'...)`).
pub const ReplicationXLogData = struct {
    wal_start: u64,
    wal_end: u64,
    server_time_micros: i64,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReplicationXLogData) void {
        self.allocator.free(self.data);
    }
};

/// Primary keepalive message (`CopyData('k'...)`).
pub const ReplicationKeepalive = struct {
    wal_end: u64,
    server_time_micros: i64,
    reply_requested: bool,
};

/// Replication stream message parsed from CopyData payload.
pub const ReplicationStreamMessage = union(enum) {
    xlog_data: ReplicationXLogData,
    keepalive: ReplicationKeepalive,
    raw: struct {
        tag: u8,
        payload: []u8,
        allocator: std.mem.Allocator,
    },

    pub fn deinit(self: *ReplicationStreamMessage) void {
        switch (self.*) {
            .xlog_data => |*x| x.deinit(),
            .keepalive => {},
            .raw => |r| r.allocator.free(r.payload),
        }
    }
};

/// Query options for per-query configuration
pub const QueryOpts = struct {
    /// Timeout in milliseconds (null = no timeout)
    timeout_ms: ?u32 = null,
    /// Whether to populate column names in results
    column_names: bool = true,
    /// Custom allocator for this query (null = use driver allocator)
    allocator: ?std.mem.Allocator = null,
};

/// Parsed estimate from `EXPLAIN (FORMAT JSON)`.
pub const ExplainEstimate = struct {
    total_cost: f64,
    plan_rows: u64,
};

/// Callback for streaming COPY TO STDOUT chunks.
/// Chunk memory is only valid until callback returns.
pub const CopyChunkHandler = *const fn (
    ctx: ?*anyopaque,
    chunk: []const u8,
) anyerror!void;

/// TLS policy parsed from libpq-style URL options.
///
/// `verify_ca`/`verify_full` require explicit certificate verification config
/// (for example via `sslrootcert`) and fail closed otherwise.
pub const TlsMode = enum {
    disable,
    prefer,
    require,
    verify_ca,
    verify_full,

    pub fn parseSslMode(value: []const u8) ?TlsMode {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "disable")) return .disable;
        if (std.ascii.eqlIgnoreCase(trimmed, "allow") or std.ascii.eqlIgnoreCase(trimmed, "prefer")) return .prefer;
        if (std.ascii.eqlIgnoreCase(trimmed, "require")) return .require;
        if (std.ascii.eqlIgnoreCase(trimmed, "verify-ca")) return .verify_ca;
        if (std.ascii.eqlIgnoreCase(trimmed, "verify-full")) return .verify_full;
        return null;
    }
};

/// GSS session-encryption policy parsed from URL options.
///
/// `PgDriver` currently supports plain TCP only; `.prefer`/`.require` are
/// accepted by URL/builder parsing but rejected at connect time.
pub const GssEncMode = enum {
    disable,
    prefer,
    require,

    pub fn parse(value: []const u8) ?GssEncMode {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "disable")) return .disable;
        if (std.ascii.eqlIgnoreCase(trimmed, "prefer")) return .prefer;
        if (std.ascii.eqlIgnoreCase(trimmed, "require")) return .require;
        return null;
    }
};

/// Cancellation token for issuing PostgreSQL CancelRequest.
pub const CancelToken = struct {
    host: []const u8,
    port: u16,
    process_id: i32,
    secret_key: i32,

    pub fn cancelQuery(self: *const CancelToken, allocator: std.mem.Allocator) !void {
        try cancel_mod.cancelQuery(
            allocator,
            self.host,
            self.port,
            self.process_id,
            self.secret_key,
        );
    }
};

/// Advanced connection options used by `connectWithOptions` and builder API.
pub const ConnectOptions = struct {
    /// Optional TCP connect timeout in milliseconds.
    timeout_ms: ?i32 = null,
    /// Password/SCRAM/GSS auth policy.
    auth_options: AuthOptions = .{},
    /// Additional startup parameters sent in StartupMessage.
    startup_params: []const StartupParam = &.{},
    /// Parsed libpq-style TLS mode.
    tls_mode: TlsMode = .disable,
    /// Optional TLS configuration used when `tls_mode` is not `.disable`.
    tls_config: ?TlsConfig = null,
    /// Parsed libpq-style GSS encryption mode; only `.disable` is currently supported by `PgDriver`.
    gss_enc_mode: GssEncMode = .disable,
};

/// Parsed PostgreSQL URL pieces used by `connectUrl`.
const ParsedConnectionUrl = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    database: []const u8,
    password: ?[]const u8,
    options: ConnectOptions,
    logical_replication: bool = false,
};

/// Builder for ergonomic `PgDriver` connection setup.
pub const PgDriverBuilder = struct {
    allocator: std.mem.Allocator,
    host_name: []const u8 = "127.0.0.1",
    port_number: u16 = 5432,
    username: ?[]const u8 = null,
    database_name: ?[]const u8 = null,
    user_password: ?[]const u8 = null,
    options: ConnectOptions = .{},
    force_logical_replication: bool = false,

    pub fn init(allocator: std.mem.Allocator) PgDriverBuilder {
        return .{ .allocator = allocator };
    }

    pub fn host(self: PgDriverBuilder, host_value: []const u8) PgDriverBuilder {
        var next = self;
        next.host_name = host_value;
        return next;
    }

    pub fn port(self: PgDriverBuilder, port_value: u16) PgDriverBuilder {
        var next = self;
        next.port_number = port_value;
        return next;
    }

    pub fn user(self: PgDriverBuilder, user_value: []const u8) PgDriverBuilder {
        var next = self;
        next.username = user_value;
        return next;
    }

    pub fn database(self: PgDriverBuilder, database_value: []const u8) PgDriverBuilder {
        var next = self;
        next.database_name = database_value;
        return next;
    }

    pub fn password(self: PgDriverBuilder, password_value: []const u8) PgDriverBuilder {
        var next = self;
        next.user_password = password_value;
        return next;
    }

    pub fn timeoutMs(self: PgDriverBuilder, timeout_ms: i32) PgDriverBuilder {
        var next = self;
        next.options.timeout_ms = timeout_ms;
        return next;
    }

    pub fn authOptions(self: PgDriverBuilder, auth_options: AuthOptions) PgDriverBuilder {
        var next = self;
        next.options.auth_options = auth_options;
        return next;
    }

    pub fn startupParams(self: PgDriverBuilder, startup_params: []const StartupParam) PgDriverBuilder {
        var next = self;
        next.options.startup_params = startup_params;
        return next;
    }

    pub fn tlsMode(self: PgDriverBuilder, mode: TlsMode) PgDriverBuilder {
        var next = self;
        next.options.tls_mode = mode;
        return next;
    }

    pub fn tlsConfig(self: PgDriverBuilder, config: TlsConfig) PgDriverBuilder {
        var next = self;
        next.options.tls_config = config;
        return next;
    }

    pub fn gssEncMode(self: PgDriverBuilder, mode: GssEncMode) PgDriverBuilder {
        var next = self;
        next.options.gss_enc_mode = mode;
        return next;
    }

    pub fn channelBindingMode(self: PgDriverBuilder, mode: auth_options_mod.ScramChannelBindingMode) PgDriverBuilder {
        var next = self;
        next.options.auth_options.scram_channel_binding = mode;
        return next;
    }

    /// Force `replication=database` startup mode.
    ///
    /// If `startupParams` already contains a replication key, that value wins.
    pub fn logicalReplication(self: PgDriverBuilder) PgDriverBuilder {
        var next = self;
        next.force_logical_replication = true;
        return next;
    }

    pub fn connect(self: PgDriverBuilder) !PgDriver {
        const user_name = self.username orelse return error.UserRequired;
        const database_name = self.database_name orelse return error.DatabaseRequired;

        var options = self.options;
        const logical_replication_param = [_]StartupParam{.{ .name = "replication", .value = "database" }};
        if (self.force_logical_replication and !hasLogicalReplicationStartupMode(options.startup_params) and options.startup_params.len == 0) {
            options.startup_params = &logical_replication_param;
        }

        return PgDriver.connectWithOptions(
            self.allocator,
            self.host_name,
            self.port_number,
            user_name,
            database_name,
            self.user_password,
            options,
        );
    }
};

/// Transport used by `PgDriver` (plain TCP or TLS).
pub const DriverConnection = union(enum) {
    plain: Connection,
    tls: TlsConnection,

    pub fn close(self: *DriverConnection) void {
        switch (self.*) {
            .plain => |*conn| conn.close(),
            .tls => |*conn| conn.close(),
        }
    }

    pub fn ioBackend(self: *const DriverConnection) io_backend_mod.Backend {
        return switch (self.*) {
            .plain => |conn| conn.ioBackend(),
            .tls => .sync,
        };
    }

    pub fn send(self: *DriverConnection, bytes: []const u8) !void {
        switch (self.*) {
            .plain => |*conn| try conn.send(bytes),
            .tls => |*conn| try conn.send(bytes),
        }
    }

    pub fn readMessage(self: *DriverConnection) !MessageResult {
        return switch (self.*) {
            .plain => |*conn| blk: {
                const msg = try conn.readMessage();
                break :blk .{ .msg_type = msg.msg_type, .payload = msg.payload };
            },
            .tls => |*conn| blk: {
                const msg = try conn.readMessage();
                break :blk .{ .msg_type = msg.msg_type, .payload = msg.payload };
            },
        };
    }

    pub fn startupWithParamsAndAuth(
        self: *DriverConnection,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        startup_params: []const StartupParam,
        auth_options: AuthOptions,
    ) !void {
        switch (self.*) {
            .plain => |*conn| try conn.startupWithParamsAndAuth(user, database, password, startup_params, auth_options),
            .tls => |*conn| try conn.startupWithParamsAndAuth(user, database, password, startup_params, auth_options),
        }
    }

    pub fn sslAccepted(self: *const DriverConnection) bool {
        return switch (self.*) {
            .plain => false,
            .tls => |conn| conn.sslAccepted(),
        };
    }

    pub fn processId(self: *const DriverConnection) u32 {
        return switch (self.*) {
            .plain => |conn| conn.process_id,
            .tls => |conn| conn.process_id,
        };
    }

    pub fn secretKey(self: *const DriverConnection) u32 {
        return switch (self.*) {
            .plain => |conn| conn.secret_key,
            .tls => |conn| conn.secret_key,
        };
    }
};

/// PostgreSQL driver - executes QAIL AST queries
pub const PgDriver = struct {
    conn: DriverConnection,
    allocator: std.mem.Allocator,
    encoder: AstEncoder,
    cache: StatementCache,
    connect_host: ?[]u8 = null,
    connect_port: ?u16 = null,
    notifications: std.ArrayListUnmanaged(Notification) = .{},
    replication_mode_enabled: bool = false,
    replication_stream_active: bool = false,
    last_replication_wal_end: ?u64 = null,

    /// Default max cached statements (matches Rust's default)
    const DEFAULT_CACHE_SIZE: usize = 256;
    const MAX_REPLICATION_OPTIONS: usize = 64;
    const MAX_REPLICATION_OPTION_VALUE_BYTES: usize = 16 * 1024;
    const MAX_REPLICATION_XLOGDATA_BYTES: usize = 16 * 1024 * 1024;

    pub fn init(conn: Connection, allocator: std.mem.Allocator) PgDriver {
        return initTransport(.{ .plain = conn }, allocator);
    }

    fn initTransport(conn: DriverConnection, allocator: std.mem.Allocator) PgDriver {
        return .{
            .conn = conn,
            .allocator = allocator,
            .encoder = AstEncoder.init(allocator),
            .cache = StatementCache.init(allocator, DEFAULT_CACHE_SIZE),
            .connect_host = null,
            .connect_port = null,
            .notifications = .{},
            .replication_mode_enabled = false,
            .replication_stream_active = false,
            .last_replication_wal_end = null,
        };
    }

    pub fn deinit(self: *PgDriver) void {
        if (self.connect_host) |host| {
            self.allocator.free(host);
            self.connect_host = null;
        }
        for (self.notifications.items) |*notification| {
            notification.deinit();
        }
        self.notifications.deinit(self.allocator);
        self.cache.deinit();
        self.encoder.deinit();
        self.conn.close();
    }

    /// Active plain TCP backend selected for this connection.
    pub fn ioBackend(self: *const PgDriver) io_backend_mod.Backend {
        return self.conn.ioBackend();
    }

    /// Backend process id returned by `BackendKeyData`.
    pub fn backendProcessId(self: *const PgDriver) u32 {
        return self.conn.processId();
    }

    /// Backend secret key returned by `BackendKeyData`.
    pub fn backendSecretKey(self: *const PgDriver) u32 {
        return self.conn.secretKey();
    }

    /// Get cancel key pair for this connection.
    pub fn getCancelKey(self: *const PgDriver) CancelKey {
        return makeCancelKey(self.backendProcessId(), self.backendSecretKey());
    }

    /// Build a cancellation token bound to this connection endpoint.
    ///
    /// Returns error if endpoint metadata is unavailable (e.g. pool wrappers
    /// created from externally-owned `Connection` via `PgDriver.init`).
    pub fn cancelToken(self: *const PgDriver) !CancelToken {
        const host = self.connect_host orelse return error.ConnectionEndpointUnknown;
        const port = self.connect_port orelse return error.ConnectionEndpointUnknown;
        const key = self.getCancelKey();
        return .{
            .host = host,
            .port = port,
            .process_id = key.process_id,
            .secret_key = key.secret_key,
        };
    }

    /// Cancel currently running query using this driver's backend key.
    pub fn cancelQuery(self: *const PgDriver, allocator: std.mem.Allocator) !void {
        const token = try self.cancelToken();
        try token.cancelQuery(allocator);
    }

    /// Connect to PostgreSQL
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, database: []const u8) !PgDriver {
        return connectWithOptions(allocator, host, port, user, database, null, .{});
    }

    /// Connect to PostgreSQL with connect timeout (milliseconds).
    pub fn connectWithTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        timeout_ms: i32,
    ) !PgDriver {
        return connectWithOptions(allocator, host, port, user, database, null, .{
            .timeout_ms = timeout_ms,
        });
    }

    /// Connect with password
    pub fn connectWithPassword(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, database: []const u8, password: []const u8) !PgDriver {
        return connectWithOptions(allocator, host, port, user, database, password, .{});
    }

    /// Connect with password and connect timeout (milliseconds).
    pub fn connectWithPasswordTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: []const u8,
        timeout_ms: i32,
    ) !PgDriver {
        return connectWithOptions(allocator, host, port, user, database, password, .{
            .timeout_ms = timeout_ms,
        });
    }

    /// Builder-style constructor for ergonomic connection setup.
    pub fn builder(allocator: std.mem.Allocator) PgDriverBuilder {
        return PgDriverBuilder.init(allocator);
    }

    /// Connect using `DATABASE_URL` environment variable.
    pub fn connectEnv(allocator: std.mem.Allocator) !PgDriver {
        const url = process.getEnvVarOwned(allocator, "DATABASE_URL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.DatabaseUrlNotSet,
            else => return err,
        };
        defer allocator.free(url);

        return connectUrl(allocator, url);
    }

    /// Connect using PostgreSQL URL (`postgres://` / `postgresql://`).
    pub fn connectUrl(allocator: std.mem.Allocator, url: []const u8) !PgDriver {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const parsed = try parseConnectionUrl(arena, url);
        const startup_params: []const StartupParam = if (parsed.logical_replication)
            &.{.{ .name = "replication", .value = "database" }}
        else
            parsed.options.startup_params;

        var options = parsed.options;
        options.startup_params = startup_params;

        return connectWithOptions(
            allocator,
            parsed.host,
            parsed.port,
            parsed.user,
            parsed.database,
            parsed.password,
            options,
        );
    }

    /// Connect with explicit options.
    pub fn connectWithOptions(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        options: ConnectOptions,
    ) !PgDriver {
        if (options.gss_enc_mode != .disable) return error.UnsupportedGssEncMode;

        return connectWithStartupParamsAndAuth(
            allocator,
            host,
            port,
            user,
            database,
            password,
            options.startup_params,
            options.auth_options,
            options.timeout_ms,
            options.tls_mode,
            options.tls_config,
        );
    }

    /// Connect with explicit auth options (GSS/SSPI/Kerberos token provider).
    pub fn connectWithAuth(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        auth_options: AuthOptions,
    ) !PgDriver {
        return connectWithOptions(allocator, host, port, user, database, password, .{
            .auth_options = auth_options,
        });
    }

    /// Connect with explicit auth options and connect timeout (milliseconds).
    pub fn connectWithAuthTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        auth_options: AuthOptions,
        timeout_ms: i32,
    ) !PgDriver {
        return connectWithOptions(allocator, host, port, user, database, password, .{
            .timeout_ms = timeout_ms,
            .auth_options = auth_options,
        });
    }

    /// Connect with logical replication startup mode (`replication=database`).
    pub fn connectLogicalReplication(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
    ) !PgDriver {
        return connectLogicalReplicationWithAuth(allocator, host, port, user, database, null, .{});
    }

    /// Connect with logical replication startup mode and connect timeout (milliseconds).
    pub fn connectLogicalReplicationWithTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        timeout_ms: i32,
    ) !PgDriver {
        return connectLogicalReplicationWithAuthTimeout(allocator, host, port, user, database, null, .{}, timeout_ms);
    }

    /// Connect with password in logical replication startup mode (`replication=database`).
    pub fn connectLogicalReplicationWithPassword(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: []const u8,
    ) !PgDriver {
        return connectLogicalReplicationWithAuth(allocator, host, port, user, database, password, .{});
    }

    /// Connect with password in logical replication mode and connect timeout (milliseconds).
    pub fn connectLogicalReplicationWithPasswordTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: []const u8,
        timeout_ms: i32,
    ) !PgDriver {
        return connectLogicalReplicationWithAuthTimeout(allocator, host, port, user, database, password, .{}, timeout_ms);
    }

    /// Connect with logical replication mode and explicit auth options.
    pub fn connectLogicalReplicationWithAuth(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        auth_options: AuthOptions,
    ) !PgDriver {
        return connectWithStartupParamsAndAuth(
            allocator,
            host,
            port,
            user,
            database,
            password,
            &.{.{ .name = "replication", .value = "database" }},
            auth_options,
            null,
            .disable,
            null,
        );
    }

    /// Connect with logical replication mode, explicit auth options, and connect timeout (milliseconds).
    pub fn connectLogicalReplicationWithAuthTimeout(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        auth_options: AuthOptions,
        timeout_ms: i32,
    ) !PgDriver {
        return connectWithStartupParamsAndAuth(
            allocator,
            host,
            port,
            user,
            database,
            password,
            &.{.{ .name = "replication", .value = "database" }},
            auth_options,
            timeout_ms,
            .disable,
            null,
        );
    }

    fn connectWithStartupParamsAndAuth(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        startup_params: []const StartupParam,
        auth_options: AuthOptions,
        timeout_ms: ?i32,
        tls_mode: TlsMode,
        tls_config: ?TlsConfig,
    ) !PgDriver {
        var transport: DriverConnection = switch (tls_mode) {
            .disable => blk: {
                const conn = if (timeout_ms) |ms|
                    try Connection.connectWithTimeout(allocator, host, port, ms)
                else
                    try Connection.connect(allocator, host, port);
                break :blk .{ .plain = conn };
            },
            .prefer, .require, .verify_ca, .verify_full => blk: {
                var config = tls_config orelse TlsConfig{};
                if (config.server_name == null) config.server_name = host;
                switch (tls_mode) {
                    .verify_ca, .verify_full => {
                        if (config.verify == .no_verification) {
                            return error.TlsVerificationRequired;
                        }
                    },
                    else => {},
                }

                var tls_conn = if (timeout_ms) |ms|
                    try TlsConnection.connectWithTimeout(allocator, host, port, config, ms)
                else
                    try TlsConnection.connect(allocator, host, port, config);
                if ((tls_mode == .require or tls_mode == .verify_ca or tls_mode == .verify_full) and !tls_conn.sslAccepted()) {
                    tls_conn.close();
                    return error.TlsRequired;
                }
                break :blk .{ .tls = tls_conn };
            },
        };
        errdefer transport.close();

        try transport.startupWithParamsAndAuth(user, database, password, startup_params, auth_options);

        var driver = PgDriver.initTransport(transport, allocator);
        driver.connect_host = try allocator.dupe(u8, host);
        driver.connect_port = port;
        driver.replication_mode_enabled = hasLogicalReplicationStartupMode(startup_params);
        return driver;
    }

    // ==================== AST-Native Query Execution ====================

    /// Execute a QAIL AST command and fetch all rows
    pub fn fetchAll(self: *PgDriver, cmd: *const QailCmd) ![]PgRow {
        // Encode AST to wire protocol
        try self.encoder.encodeQuery(cmd);
        try self.conn.send(self.encoder.getWritten());

        // Collect results
        var rows: std.ArrayList(PgRow) = .{};
        errdefer {
            for (rows.items) |*row| {
                row.deinit();
            }
            rows.deinit(self.allocator);
        }

        var field_names_template: []const []const u8 = &.{};
        errdefer if (field_names_template.len > 0) PgRow.freeOwnedFieldNames(self.allocator, field_names_template);

        // Read responses
        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .parse_complete, .bind_complete => {},
                .row_description => {
                    var decoder = Decoder.init(msg.payload);
                    const field_descriptions = try decoder.parseRowDescription(self.allocator);
                    defer self.allocator.free(field_descriptions);

                    if (field_names_template.len > 0) {
                        PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
                        field_names_template = &.{};
                    }

                    var names = try self.allocator.alloc([]const u8, field_descriptions.len);
                    var copied: usize = 0;
                    errdefer {
                        for (names[0..copied]) |name| {
                            self.allocator.free(name);
                        }
                        self.allocator.free(names);
                    }
                    for (field_descriptions, 0..) |fd, i| {
                        names[i] = try self.allocator.dupe(u8, fd.name);
                        copied += 1;
                    }
                    field_names_template = names;
                },
                .data_row => {
                    var decoder = Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRowOwned(self.allocator);
                    const row = try PgRow.initOwned(self.allocator, columns, field_names_template);
                    try rows.append(self.allocator, row);
                },
                .command_complete => {},
                .ready_for_query => {
                    if (field_names_template.len > 0) {
                        PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
                        field_names_template = &.{};
                    }
                    break;
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Query error: {s}\n", .{err.message orelse "unknown"});
                    _ = self.drainUntilReadyForQuery() catch {};
                    return error.QueryError;
                },
                .notification => try self.bufferNotification(msg.payload),
                .no_data => {},
                else => {},
            }
        }

        return try rows.toOwnedSlice(self.allocator);
    }

    /// Execute a QAIL AST command and fetch one row
    pub fn fetchOne(self: *PgDriver, cmd: *const QailCmd) !?PgRow {
        const rows = try self.fetchAll(cmd);
        defer {
            for (rows[1..]) |*row| {
                row.deinit();
            }
            self.allocator.free(rows);
        }

        if (rows.len == 0) return null;
        return rows[0];
    }

    /// Execute a QAIL AST command (for mutations) - returns affected row count
    pub fn execute(self: *PgDriver, cmd: *const QailCmd) !u64 {
        try self.encoder.encodeQuery(cmd);
        try self.conn.send(self.encoder.getWritten());

        var affected_rows: u64 = 0;

        while (true) {
            const msg = try self.conn.readMessage();

            switch (msg.msg_type) {
                .parse_complete, .bind_complete => {},
                .command_complete => {
                    var decoder = Decoder.init(msg.payload);
                    const tag = try decoder.parseCommandComplete();

                    // Parse affected rows from tag like "UPDATE 5"
                    var parts = std.mem.splitBackwardsScalar(u8, tag, ' ');
                    if (parts.next()) |last| {
                        affected_rows = std.fmt.parseInt(u64, last, 10) catch 0;
                    }
                },
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Execute error: {s}\n", .{err.message orelse "unknown"});
                    _ = self.drainUntilReadyForQuery() catch {};
                    return error.ExecuteError;
                },
                .notification => try self.bufferNotification(msg.payload),
                else => {},
            }
        }

        return affected_rows;
    }

    // ==================== Transaction Control ====================

    /// Begin a transaction
    pub fn begin(self: *PgDriver) !void {
        const cmd = QailCmd.raw("BEGIN");
        _ = try self.execute(&cmd);
    }

    /// Commit the transaction
    pub fn commit(self: *PgDriver) !void {
        const cmd = QailCmd.raw("COMMIT");
        _ = try self.execute(&cmd);
    }

    /// Rollback the transaction
    pub fn rollback(self: *PgDriver) !void {
        const cmd = QailCmd.raw("ROLLBACK");
        _ = try self.execute(&cmd);
    }

    /// Execute raw SQL string (for migrations, DDL, etc.)
    pub fn executeRaw(self: *PgDriver, sql: []const u8) !u64 {
        const cmd = QailCmd.raw(sql);
        return try self.execute(&cmd);
    }

    // ==================== COPY Helpers ====================

    /// Bulk insert rows using PostgreSQL COPY FROM STDIN from AST-native `add` command.
    pub fn copyBulk(self: *PgDriver, cmd: *const QailCmd, rows: []const []const ?[]const u8) !u64 {
        if (cmd.kind != .add) return error.InvalidCopyCommand;
        const columns = try extractCopyColumns(self.allocator, cmd);
        defer self.allocator.free(columns);
        return copy_mod.copyIn(&self.conn, self.allocator, cmd.table, columns, rows);
    }

    /// Bulk insert pre-encoded COPY text bytes using AST-native `add` command.
    pub fn copyBulkRaw(self: *PgDriver, cmd: *const QailCmd, data: []const u8) !u64 {
        if (cmd.kind != .add) return error.InvalidCopyCommand;
        const columns = try extractCopyColumns(self.allocator, cmd);
        defer self.allocator.free(columns);
        return copy_mod.copyInRaw(&self.conn, self.allocator, cmd.table, columns, data);
    }

    /// Export an AST-native `copy_out` command into a single raw byte buffer.
    pub fn copyExportRaw(self: *PgDriver, cmd: *const QailCmd) ![]u8 {
        if (cmd.kind != .copy_out) return error.InvalidCopyCommand;

        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(self.allocator);

        var sink = CopyByteSink{
            .out = &out,
            .allocator = self.allocator,
        };
        try self.copyExportStreamRaw(cmd, &sink, appendCopyChunk);
        return try out.toOwnedSlice(self.allocator);
    }

    /// Stream raw COPY TO STDOUT chunks from an AST-native `copy_out` command.
    ///
    /// `chunk` memory is borrowed from the driver's read buffer and valid only
    /// for the callback duration.
    pub fn copyExportStreamRaw(
        self: *PgDriver,
        cmd: *const QailCmd,
        ctx: ?*anyopaque,
        on_chunk: CopyChunkHandler,
    ) !void {
        if (cmd.kind != .copy_out) return error.InvalidCopyCommand;

        try self.encoder.encodeQuery(cmd);
        try self.conn.send(self.encoder.getWritten());

        var saw_copy_out = false;
        var saw_copy_done = false;
        var saw_command_complete = false;

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .copy_out_response => {
                    if (saw_copy_out) return error.InvalidCopyState;
                    saw_copy_out = true;
                },
                .copy_data => {
                    if (!saw_copy_out or saw_copy_done) return error.InvalidCopyState;
                    try on_chunk(ctx, msg.payload);
                },
                .copy_done => {
                    if (!saw_copy_out or saw_copy_done) return error.InvalidCopyState;
                    saw_copy_done = true;
                },
                .command_complete => {
                    if (!saw_copy_out) return error.InvalidCopyState;
                    saw_command_complete = true;
                },
                .ready_for_query => {
                    if (!saw_copy_out or !saw_copy_done or !saw_command_complete) return error.InvalidCopyState;
                    return;
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("COPY OUT error: {s}\n", .{err.message orelse "unknown"});
                    return error.CopyFailed;
                },
                .notification => try self.bufferNotification(msg.payload),
                .notice, .parameter_status => {},
                else => return error.InvalidCopyState,
            }
        }
    }

    // ==================== RLS Helpers ====================

    /// Configure transaction-local RLS session context (`BEGIN; SET LOCAL ...`).
    pub fn setRlsContext(self: *PgDriver, ctx: *const rls_mod.RlsContext) !void {
        const sql = try rls_mod.contextToSql(self.allocator, ctx);
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    /// Configure RLS context and statement timeout in one roundtrip.
    pub fn setRlsContextWithTimeout(self: *PgDriver, ctx: *const rls_mod.RlsContext, timeout_ms: u32) !void {
        const sql = try rls_mod.contextToSqlWithTimeout(self.allocator, ctx, timeout_ms);
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    /// Configure RLS context plus statement/lock timeout in one roundtrip.
    pub fn setRlsContextWithTimeouts(
        self: *PgDriver,
        ctx: *const rls_mod.RlsContext,
        statement_timeout_ms: u32,
        lock_timeout_ms: u32,
    ) !void {
        const sql = try rls_mod.contextToSqlWithTimeouts(self.allocator, ctx, statement_timeout_ms, lock_timeout_ms);
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    /// Reset transaction-local RLS/session context.
    pub fn clearRlsContext(self: *PgDriver) !void {
        _ = try self.executeRaw(rls_mod.resetSql());
    }

    /// ALTER TABLE ... ENABLE ROW LEVEL SECURITY.
    pub fn enableRls(self: *PgDriver, table: []const u8) !void {
        const sql = try buildAlterTableRlsSql(self.allocator, table, "ENABLE ROW LEVEL SECURITY");
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    /// ALTER TABLE ... DISABLE ROW LEVEL SECURITY.
    pub fn disableRls(self: *PgDriver, table: []const u8) !void {
        const sql = try buildAlterTableRlsSql(self.allocator, table, "DISABLE ROW LEVEL SECURITY");
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    /// ALTER TABLE ... FORCE ROW LEVEL SECURITY.
    pub fn forceRls(self: *PgDriver, table: []const u8) !void {
        const sql = try buildAlterTableRlsSql(self.allocator, table, "FORCE ROW LEVEL SECURITY");
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    /// ALTER TABLE ... NO FORCE ROW LEVEL SECURITY.
    pub fn noForceRls(self: *PgDriver, table: []const u8) !void {
        const sql = try buildAlterTableRlsSql(self.allocator, table, "NO FORCE ROW LEVEL SECURITY");
        defer self.allocator.free(sql);
        _ = try self.executeRaw(sql);
    }

    // ==================== EXPLAIN Helpers ====================

    /// Run EXPLAIN (FORMAT JSON) for a QAIL command and parse estimate.
    pub fn explainEstimate(self: *PgDriver, cmd: *const QailCmd) !?ExplainEstimate {
        const sql = try transpiler.toSql(self.allocator, cmd);
        defer self.allocator.free(sql);
        return try self.explainEstimateSql(sql);
    }

    /// Run EXPLAIN (FORMAT JSON) for raw SQL and parse estimate.
    pub fn explainEstimateSql(self: *PgDriver, sql: []const u8) !?ExplainEstimate {
        const explain_sql = try std.fmt.allocPrint(self.allocator, "EXPLAIN (FORMAT JSON) {s}", .{sql});
        defer self.allocator.free(explain_sql);

        const explain_cmd = QailCmd.raw(explain_sql);
        const rows = try self.fetchAll(&explain_cmd);
        defer freeRows(self.allocator, rows);

        if (rows.len == 0) return null;
        const json_output = rows[0].getString(0) orelse return null;
        return parseExplainJson(json_output);
    }

    // ==================== LISTEN / NOTIFY ====================

    /// Subscribe to a notification channel.
    pub fn listen(self: *PgDriver, channel: []const u8) !void {
        const quoted = try quoteIdentifierAlloc(self.allocator, channel);
        defer self.allocator.free(quoted);

        const sql = try std.fmt.allocPrint(self.allocator, "LISTEN {s}", .{quoted});
        defer self.allocator.free(sql);

        _ = try self.executeRaw(sql);
    }

    /// Unsubscribe from a notification channel.
    pub fn unlisten(self: *PgDriver, channel: []const u8) !void {
        const quoted = try quoteIdentifierAlloc(self.allocator, channel);
        defer self.allocator.free(quoted);

        const sql = try std.fmt.allocPrint(self.allocator, "UNLISTEN {s}", .{quoted});
        defer self.allocator.free(sql);

        _ = try self.executeRaw(sql);
    }

    /// Unsubscribe from all notification channels.
    pub fn unlistenAll(self: *PgDriver) !void {
        _ = try self.executeRaw("UNLISTEN *");
    }

    /// Drain buffered notifications without blocking.
    ///
    /// Caller owns returned slice and each notification payload.
    pub fn pollNotifications(self: *PgDriver) ![]Notification {
        const out = try self.allocator.alloc(Notification, self.notifications.items.len);
        std.mem.copyForwards(Notification, out, self.notifications.items);
        self.notifications.clearRetainingCapacity();
        return out;
    }

    /// Wait for the next notification (blocking).
    ///
    /// Caller owns the returned notification and must call `deinit()`.
    pub fn recvNotification(self: *PgDriver) !Notification {
        if (self.popBufferedNotification()) |notification| return notification;

        // Flush pending async messages first.
        var encoder = PgEncoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.encodeQuery("");
        try self.conn.send(encoder.getWritten());

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .notification => return try self.decodeNotification(msg.payload),
                .empty_query, .command_complete, .notice, .parameter_status => {},
                .ready_for_query => {
                    if (self.popBufferedNotification()) |notification| return notification;
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Notification wait error: {s}\n", .{err.message orelse "unknown"});
                    return error.QueryError;
                },
                else => {},
            }
        }
    }

    // ==================== Logical Replication ====================

    /// Run `IDENTIFY_SYSTEM` on a replication connection.
    pub fn identifySystem(self: *PgDriver) !IdentifySystem {
        try self.ensureReplicationMode("IDENTIFY_SYSTEM");
        try self.ensureReplicationControlIdle("IDENTIFY_SYSTEM");

        const cmd = QailCmd.raw("IDENTIFY_SYSTEM");
        const rows = try self.fetchAll(&cmd);
        defer freeRows(self.allocator, rows);

        if (rows.len == 0) return error.InvalidReplicationResponse;
        return try parseIdentifySystemRow(self.allocator, &rows[0]);
    }

    /// Create a logical replication slot.
    pub fn createLogicalReplicationSlot(
        self: *PgDriver,
        slot_name: []const u8,
        output_plugin: []const u8,
        temporary: bool,
        two_phase: bool,
    ) !ReplicationSlotInfo {
        try self.ensureReplicationMode("CREATE_REPLICATION_SLOT");
        try self.ensureReplicationControlIdle("CREATE_REPLICATION_SLOT");

        const sql = try buildCreateLogicalReplicationSlotSql(self.allocator, slot_name, output_plugin, temporary, two_phase);
        defer self.allocator.free(sql);

        const cmd = QailCmd.raw(sql);
        const rows = try self.fetchAll(&cmd);
        defer freeRows(self.allocator, rows);

        if (rows.len == 0) return error.InvalidReplicationResponse;
        return try parseCreateSlotRow(self.allocator, &rows[0]);
    }

    /// Drop a replication slot.
    pub fn dropReplicationSlot(self: *PgDriver, slot_name: []const u8, wait: bool) !void {
        try self.ensureReplicationMode("DROP_REPLICATION_SLOT");
        try self.ensureReplicationControlIdle("DROP_REPLICATION_SLOT");

        const sql = try buildDropReplicationSlotSql(self.allocator, slot_name, wait);
        defer self.allocator.free(sql);

        _ = try self.executeRaw(sql);
    }

    /// Start logical replication in CopyBoth mode.
    pub fn startLogicalReplication(
        self: *PgDriver,
        slot_name: []const u8,
        start_lsn: []const u8,
        options: []const ReplicationOption,
    ) !ReplicationStreamStart {
        try self.ensureReplicationMode("START_REPLICATION");
        if (self.replication_stream_active) return error.ReplicationStreamAlreadyActive;

        const sql = try buildStartLogicalReplicationSql(self.allocator, slot_name, start_lsn, options);
        defer self.allocator.free(sql);

        var pg_encoder = PgEncoder.init(self.allocator);
        defer pg_encoder.deinit();
        try pg_encoder.encodeQuery(sql);
        try self.conn.send(pg_encoder.getWritten());

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .copy_both_response => {
                    var decoder = Decoder.init(msg.payload);
                    const parsed = try decoder.parseCopyResponse(self.allocator);
                    errdefer self.allocator.free(parsed.column_formats);

                    if (parsed.format != 0) return error.UnsupportedReplicationFormat;
                    if (parsed.column_formats.len != 0) return error.UnsupportedReplicationFormat;

                    self.replication_stream_active = true;
                    self.last_replication_wal_end = null;

                    return .{
                        .format = parsed.format,
                        .column_formats = parsed.column_formats,
                        .allocator = self.allocator,
                    };
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err_info = try decoder.parseErrorResponse();
                    std.debug.print("START_REPLICATION error: {s}\n", .{err_info.message orelse "unknown"});
                    return error.QueryError;
                },
                .ready_for_query => return error.InvalidReplicationResponse,
                .notification => try self.bufferNotification(msg.payload),
                .notice, .parameter_status => {},
                else => return error.UnexpectedReplicationMessage,
            }
        }
    }

    /// Receive the next logical replication stream message.
    pub fn recvReplicationMessage(self: *PgDriver) !ReplicationStreamMessage {
        try self.ensureReplicationMode("recvReplicationMessage");
        if (!self.replication_stream_active) return error.ReplicationStreamNotActive;

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .copy_data => {
                    var parsed = parseReplicationCopyData(self.allocator, msg.payload) catch |err| {
                        self.replication_stream_active = false;
                        self.last_replication_wal_end = null;
                        return err;
                    };
                    errdefer parsed.deinit();
                    switch (parsed) {
                        .xlog_data => |x| self.advanceReplicationWalEnd("XLogData", x.wal_end) catch |err| {
                            return err;
                        },
                        .keepalive => |k| self.advanceReplicationWalEnd("keepalive", k.wal_end) catch |err| {
                            return err;
                        },
                        .raw => {},
                    }
                    return parsed;
                },
                .error_response => {
                    self.replication_stream_active = false;
                    self.last_replication_wal_end = null;
                    var decoder = Decoder.init(msg.payload);
                    const err_info = try decoder.parseErrorResponse();
                    std.debug.print("Replication stream error: {s}\n", .{err_info.message orelse "unknown"});
                    return error.QueryError;
                },
                .copy_done, .ready_for_query => {
                    self.replication_stream_active = false;
                    self.last_replication_wal_end = null;
                    return error.ReplicationStreamEnded;
                },
                .notification => try self.bufferNotification(msg.payload),
                .notice, .parameter_status => {},
                else => {
                    self.replication_stream_active = false;
                    self.last_replication_wal_end = null;
                    return error.UnexpectedReplicationMessage;
                },
            }
        }
    }

    /// Send a standby status update (`CopyData('r' ...)`) to the server.
    pub fn sendStandbyStatusUpdate(
        self: *PgDriver,
        write_lsn: u64,
        flush_lsn: u64,
        apply_lsn: u64,
        reply_requested: bool,
    ) !void {
        try self.ensureReplicationMode("sendStandbyStatusUpdate");
        if (!self.replication_stream_active) return error.ReplicationStreamNotActive;
        if (flush_lsn > write_lsn) return error.InvalidStandbyStatusUpdate;
        if (apply_lsn > flush_lsn) return error.InvalidStandbyStatusUpdate;
        if (self.last_replication_wal_end) |last_wal_end| {
            if (write_lsn > last_wal_end) return error.InvalidStandbyStatusUpdate;
        }

        const payload = buildStandbyStatusUpdatePayload(write_lsn, flush_lsn, apply_lsn, reply_requested);
        try sendCopyData(&self.conn, &payload);
    }

    // ==================== Cached (Prepared Statement) Execution ====================

    /// Execute a QAIL AST command with PREPARED STATEMENT CACHING.
    ///
    /// On first call: transpiles AST → SQL, sends Parse (prepare), then Bind/Execute
    /// On subsequent calls with same query shape: skips Parse, just Bind/Execute
    ///
    /// This gives zero-transpilation-cost on hot paths.
    pub fn fetchAllCached(self: *PgDriver, cmd: *const QailCmd) ![]PgRow {
        const stmt_name = try self.getOrPrepare(cmd);
        return try self.fetchPrepared(stmt_name, &.{});
    }

    /// Execute a QAIL AST mutation with PREPARED STATEMENT CACHING.
    ///
    /// Same as fetchAllCached but for INSERT/UPDATE/DELETE — returns affected row count.
    pub fn executeCached(self: *PgDriver, cmd: *const QailCmd) !u64 {
        const stmt_name = try self.getOrPrepare(cmd);
        return try self.executePrepared(stmt_name, &.{});
    }

    /// Execute with parameters using prepared statement cache.
    pub fn fetchAllCachedParams(self: *PgDriver, cmd: *const QailCmd, params: []const ?[]const u8) ![]PgRow {
        const stmt_name = try self.getOrPrepare(cmd);
        return try self.fetchPrepared(stmt_name, params);
    }

    /// Execute mutation with parameters using prepared statement cache.
    pub fn executeCachedParams(self: *PgDriver, cmd: *const QailCmd, params: []const ?[]const u8) !u64 {
        const stmt_name = try self.getOrPrepare(cmd);
        return try self.executePrepared(stmt_name, params);
    }

    /// Internal: transpile, hash, and prepare (on cache miss)
    fn getOrPrepare(self: *PgDriver, cmd: *const QailCmd) ![]const u8 {
        // Transpile AST → SQL
        const sql = try transpiler.toSql(self.allocator, cmd);
        defer self.allocator.free(sql);

        // Cache lookup (hash-based): returns name + hit/miss status
        const result = try self.cache.getOrCreateWithStatus(sql);

        if (!result.was_hit) {
            // Cache miss → prepare the statement on the server
            try self.prepareNamed(result.name, sql);
        }
        // Cache hit → statement already prepared on server, skip Parse

        return result.name;
    }

    /// Internal: send Parse + Sync for a named statement
    fn prepareNamed(self: *PgDriver, stmt_name: []const u8, sql: []const u8) !void {
        try self.encoder.encodePrepareNamed(stmt_name, sql);
        try self.conn.send(self.encoder.getWritten());

        // Wait for ParseComplete + ReadyForQuery
        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .parse_complete => {},
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Prepare error: {s}\n", .{err.message orelse "unknown"});
                    _ = self.drainUntilReadyForQuery() catch {};
                    return error.PrepareError;
                },
                .notification => try self.bufferNotification(msg.payload),
                else => {},
            }
        }
    }

    /// Cache statistics
    pub fn cacheStats(self: *const PgDriver) struct { hits: usize, misses: usize, size: usize, hit_rate: f64 } {
        return .{
            .hits = self.cache.hits,
            .misses = self.cache.misses,
            .size = self.cache.entries.count(),
            .hit_rate = self.cache.hitRate(),
        };
    }

    // ==================== Prepared Statements (Manual) ====================

    /// Prepare a statement for later execution with parameters
    /// Returns immediately after Parse completes
    pub fn prepare(self: *PgDriver, stmt_name: []const u8, cmd: *const QailCmd) !void {
        // Encode Parse message only (no Bind/Execute)
        try self.encoder.encodePrepare(stmt_name, cmd);
        try self.conn.send(self.encoder.getWritten());

        // Wait for ParseComplete
        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .parse_complete => {},
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Prepare error: {s}\n", .{err.message orelse "unknown"});
                    _ = self.drainUntilReadyForQuery() catch {};
                    return error.PrepareError;
                },
                .notification => try self.bufferNotification(msg.payload),
                else => {},
            }
        }
    }

    /// Execute a prepared statement with text parameters
    pub fn executePrepared(self: *PgDriver, stmt_name: []const u8, params: []const ?[]const u8) !u64 {
        // Encode Bind + Execute + Sync
        try self.encoder.executeNamedStatement(stmt_name, params);
        try self.conn.send(self.encoder.getWritten());

        var affected_rows: u64 = 0;

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .bind_complete => {},
                .command_complete => {
                    var decoder = Decoder.init(msg.payload);
                    const tag = try decoder.parseCommandComplete();
                    var parts = std.mem.splitBackwardsScalar(u8, tag, ' ');
                    if (parts.next()) |last| {
                        affected_rows = std.fmt.parseInt(u64, last, 10) catch 0;
                    }
                },
                .ready_for_query => break,
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Execute error: {s}\n", .{err.message orelse "unknown"});
                    _ = self.drainUntilReadyForQuery() catch {};
                    return error.ExecuteError;
                },
                .notification => try self.bufferNotification(msg.payload),
                else => {},
            }
        }

        return affected_rows;
    }

    /// Fetch all rows from a prepared statement with parameters
    pub fn fetchPrepared(self: *PgDriver, stmt_name: []const u8, params: []const ?[]const u8) ![]PgRow {
        try self.encoder.executeNamedStatement(stmt_name, params);
        try self.conn.send(self.encoder.getWritten());

        var rows: std.ArrayList(PgRow) = .{};
        errdefer {
            for (rows.items) |*row| row.deinit();
            rows.deinit(self.allocator);
        }

        var field_names_template: []const []const u8 = &.{};
        errdefer if (field_names_template.len > 0) PgRow.freeOwnedFieldNames(self.allocator, field_names_template);

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .bind_complete => {},
                .row_description => {
                    var decoder = Decoder.init(msg.payload);
                    const field_descriptions = try decoder.parseRowDescription(self.allocator);
                    defer self.allocator.free(field_descriptions);

                    if (field_names_template.len > 0) {
                        PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
                        field_names_template = &.{};
                    }

                    var names = try self.allocator.alloc([]const u8, field_descriptions.len);
                    var copied: usize = 0;
                    errdefer {
                        for (names[0..copied]) |name| {
                            self.allocator.free(name);
                        }
                        self.allocator.free(names);
                    }
                    for (field_descriptions, 0..) |fd, i| {
                        names[i] = try self.allocator.dupe(u8, fd.name);
                        copied += 1;
                    }
                    field_names_template = names;
                },
                .data_row => {
                    var decoder = Decoder.init(msg.payload);
                    const columns = try decoder.parseDataRowOwned(self.allocator);
                    const row = try PgRow.initOwned(self.allocator, columns, field_names_template);
                    try rows.append(self.allocator, row);
                },
                .command_complete => {},
                .ready_for_query => {
                    if (field_names_template.len > 0) {
                        PgRow.freeOwnedFieldNames(self.allocator, field_names_template);
                        field_names_template = &.{};
                    }
                    break;
                },
                .error_response => {
                    var decoder = Decoder.init(msg.payload);
                    const err = try decoder.parseErrorResponse();
                    std.debug.print("Query error: {s}\n", .{err.message orelse "unknown"});
                    _ = self.drainUntilReadyForQuery() catch {};
                    return error.QueryError;
                },
                .notification => try self.bufferNotification(msg.payload),
                else => {},
            }
        }

        return try rows.toOwnedSlice(self.allocator);
    }

    fn decodeNotification(self: *PgDriver, payload: []const u8) !Notification {
        var decoder = Decoder.init(payload);
        const parsed = try decoder.parseNotificationResponse();

        const channel = try self.allocator.dupe(u8, parsed.channel);
        errdefer self.allocator.free(channel);

        const notification_payload = try self.allocator.dupe(u8, parsed.payload);

        return .{
            .process_id = parsed.process_id,
            .channel = channel,
            .payload = notification_payload,
            .allocator = self.allocator,
        };
    }

    fn bufferNotification(self: *PgDriver, payload: []const u8) !void {
        var notification = try self.decodeNotification(payload);
        errdefer notification.deinit();
        try self.notifications.append(self.allocator, notification);
    }

    fn drainUntilReadyForQuery(self: *PgDriver) !void {
        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .ready_for_query => return,
                .notification => try self.bufferNotification(msg.payload),
                else => {},
            }
        }
    }

    fn popBufferedNotification(self: *PgDriver) ?Notification {
        if (self.notifications.items.len == 0) return null;
        return self.notifications.orderedRemove(0);
    }

    fn ensureReplicationMode(self: *const PgDriver, operation: []const u8) !void {
        if (self.replication_mode_enabled) return;
        std.debug.print("{s} requires startup param replication=database\n", .{operation});
        return error.ReplicationModeRequired;
    }

    fn ensureReplicationControlIdle(self: *const PgDriver, operation: []const u8) !void {
        if (!self.replication_stream_active) return;
        std.debug.print("{s} cannot run while replication stream is active\n", .{operation});
        return error.ReplicationStreamAlreadyActive;
    }

    fn advanceReplicationWalEnd(self: *PgDriver, source: []const u8, wal_end: u64) !void {
        if (self.last_replication_wal_end) |prev_wal_end| {
            if (wal_end < prev_wal_end) {
                self.replication_stream_active = false;
                self.last_replication_wal_end = null;
                std.debug.print(
                    "Replication {s} wal_end regressed: previous {}, current {}\n",
                    .{ source, prev_wal_end, wal_end },
                );
                return error.InvalidReplicationWalEnd;
            }
        }
        self.last_replication_wal_end = wal_end;
    }
};

fn parseConnectionUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedConnectionUrl {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    var rest = trimmed;
    if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest["postgres://".len..];
    } else if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest["postgresql://".len..];
    } else {
        return error.InvalidDatabaseUrlScheme;
    }

    const query_index = std.mem.indexOfScalar(u8, rest, '?');
    const authority_and_path = if (query_index) |idx| rest[0..idx] else rest;
    const query = if (query_index) |idx| rest[idx + 1 ..] else "";

    const at_index = std.mem.lastIndexOfScalar(u8, authority_and_path, '@') orelse return error.InvalidDatabaseUrlMissingUser;
    const auth_part = authority_and_path[0..at_index];
    const host_db_part = authority_and_path[at_index + 1 ..];
    if (auth_part.len == 0) return error.InvalidDatabaseUrlMissingUser;

    const slash_index = std.mem.indexOfScalar(u8, host_db_part, '/') orelse return error.InvalidDatabaseUrlMissingDatabase;
    const host_port_part = host_db_part[0..slash_index];
    const database_enc = host_db_part[slash_index + 1 ..];
    if (database_enc.len == 0) return error.InvalidDatabaseUrlMissingDatabase;

    var user_enc = auth_part;
    var password_enc: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, auth_part, ':')) |colon_index| {
        user_enc = auth_part[0..colon_index];
        password_enc = auth_part[colon_index + 1 ..];
    }
    if (user_enc.len == 0) return error.InvalidDatabaseUrlMissingUser;

    var host_part = host_port_part;
    var port: u16 = 5432;
    if (std.mem.lastIndexOfScalar(u8, host_port_part, ':')) |colon_index| {
        host_part = host_port_part[0..colon_index];
        const port_text = host_port_part[colon_index + 1 ..];
        if (port_text.len == 0) return error.InvalidDatabaseUrlPort;
        port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidDatabaseUrlPort;
    }
    if (host_part.len == 0) return error.InvalidDatabaseUrlHost;

    var parsed = ParsedConnectionUrl{
        .host = try allocator.dupe(u8, host_part),
        .port = port,
        .user = try percentDecodeAlloc(allocator, user_enc),
        .database = try percentDecodeAlloc(allocator, database_enc),
        .password = if (password_enc) |pw| try percentDecodeAlloc(allocator, pw) else null,
        .options = .{},
        .logical_replication = false,
    };

    if (query.len != 0) {
        try applyUrlQueryOptions(allocator, &parsed, query);
    }

    return parsed;
}

fn applyUrlQueryOptions(
    allocator: std.mem.Allocator,
    parsed: *ParsedConnectionUrl,
    query: []const u8,
) !void {
    var query_iter = std.mem.splitScalar(u8, query, '&');
    while (query_iter.next()) |pair| {
        if (pair.len == 0) continue;

        var key_value = std.mem.splitScalar(u8, pair, '=');
        const key = std.mem.trim(u8, key_value.next() orelse "", " \t\r\n");
        const value = std.mem.trim(u8, key_value.next() orelse "", " \t\r\n");
        if (key.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(key, "replication")) {
            if (!isReplicationDatabaseValue(value)) return error.InvalidReplicationStartupMode;
            parsed.logical_replication = true;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "sslmode")) {
            parsed.options.tls_mode = TlsMode.parseSslMode(value) orelse return error.InvalidTlsMode;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "sslrootcert")) {
            var tls_config = ensureTlsConfig(parsed);
            tls_config.verify = .{
                .bundle = try loadCaBundleFromPath(allocator, value),
            };
            if (parsed.options.tls_mode == .disable) parsed.options.tls_mode = .require;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "gssencmode")) {
            parsed.options.gss_enc_mode = GssEncMode.parse(value) orelse return error.InvalidGssEncMode;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "tls_server_end_point_cert_der")) {
            var tls_config = ensureTlsConfig(parsed);
            tls_config.tls_server_end_point_cert_der = try readFileAllocAnyPath(
                allocator,
                value,
                8 * 1024 * 1024,
            );
            if (parsed.options.tls_mode == .disable) parsed.options.tls_mode = .require;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "channel_binding")) {
            parsed.options.auth_options.scram_channel_binding = auth_options_mod.ScramChannelBindingMode.parse(value) orelse return error.InvalidChannelBindingMode;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_scram")) {
            parsed.options.auth_options.allow_scram_sha_256 = parseBoolParam(value) orelse return error.InvalidAuthOption;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_md5")) {
            parsed.options.auth_options.allow_md5_password = parseBoolParam(value) orelse return error.InvalidAuthOption;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_cleartext")) {
            parsed.options.auth_options.allow_cleartext_password = parseBoolParam(value) orelse return error.InvalidAuthOption;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_kerberos")) {
            parsed.options.auth_options.allow_kerberos_v5 = parseBoolParam(value) orelse return error.InvalidAuthOption;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_gssapi")) {
            parsed.options.auth_options.allow_gssapi = parseBoolParam(value) orelse return error.InvalidAuthOption;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_sspi")) {
            parsed.options.auth_options.allow_sspi = parseBoolParam(value) orelse return error.InvalidAuthOption;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "auth_mode")) {
            if (std.ascii.eqlIgnoreCase(value, "scram_only")) {
                parsed.options.auth_options = .{
                    .allow_cleartext_password = false,
                    .allow_md5_password = false,
                    .allow_scram_sha_256 = true,
                    .allow_kerberos_v5 = false,
                    .allow_gssapi = false,
                    .allow_sspi = false,
                    .scram_channel_binding = .prefer,
                };
            } else if (std.ascii.eqlIgnoreCase(value, "gssapi_only")) {
                parsed.options.auth_options = .{
                    .allow_cleartext_password = false,
                    .allow_md5_password = false,
                    .allow_scram_sha_256 = false,
                    .allow_kerberos_v5 = true,
                    .allow_gssapi = true,
                    .allow_sspi = true,
                    .scram_channel_binding = .prefer,
                };
            } else if (std.ascii.eqlIgnoreCase(value, "compat") or std.ascii.eqlIgnoreCase(value, "default")) {
                parsed.options.auth_options = .{};
            } else {
                return error.InvalidAuthMode;
            }
            continue;
        }

        if (std.ascii.eqlIgnoreCase(key, "connect_timeout")) {
            const seconds = std.fmt.parseInt(i32, value, 10) catch return error.InvalidConnectTimeout;
            if (seconds < 0) return error.InvalidConnectTimeout;
            if (seconds == 0) {
                parsed.options.timeout_ms = null;
            } else {
                parsed.options.timeout_ms = std.math.mul(i32, seconds, 1000) catch return error.InvalidConnectTimeout;
            }
            continue;
        }
    }
}

fn ensureTlsConfig(parsed: *ParsedConnectionUrl) *TlsConfig {
    if (parsed.options.tls_config == null) {
        parsed.options.tls_config = TlsConfig{};
    }
    return &parsed.options.tls_config.?;
}

fn loadCaBundleFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.crypto.Certificate.Bundle {
    var bundle: std.crypto.Certificate.Bundle = .{};
    if (std.fs.path.isAbsolute(path)) {
        try bundle.addCertsFromFilePathAbsolute(allocator, path);
    } else {
        try bundle.addCertsFromFilePath(allocator, std.fs.cwd(), path);
    }
    return bundle;
}

fn readFileAllocAnyPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn makeCancelKey(process_id: u32, secret_key: u32) CancelKey {
    return .{
        .process_id = @bitCast(process_id),
        .secret_key = @bitCast(secret_key),
    };
}

fn parseBoolParam(value: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "on") or std.ascii.eqlIgnoreCase(trimmed, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "false") or std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
    return null;
}

fn isReplicationDatabaseValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "database") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "on") or
        std.mem.eql(u8, trimmed, "1");
}

fn hasLogicalReplicationStartupMode(startup_params: []const StartupParam) bool {
    for (startup_params) |param| {
        if (std.ascii.eqlIgnoreCase(param.name, "replication")) {
            return isReplicationDatabaseValue(param.value);
        }
    }
    return false;
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) {
        return allocator.dupe(u8, text);
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            const hex = text[i + 1 .. i + 3];
            const decoded = std.fmt.parseInt(u8, hex, 16) catch {
                try out.append(allocator, text[i]);
                continue;
            };
            try out.append(allocator, decoded);
            i += 2;
            continue;
        }
        try out.append(allocator, text[i]);
    }

    return try out.toOwnedSlice(allocator);
}

fn quoteIdentifierAlloc(allocator: std.mem.Allocator, ident: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    for (ident) |ch| {
        if (ch == '"') {
            try out.appendSlice(allocator, "\"\"");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '"');

    return try out.toOwnedSlice(allocator);
}

const CopyByteSink = struct {
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
};

fn appendCopyChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const sink: *CopyByteSink = @ptrCast(@alignCast(ctx orelse return error.InvalidCopyState));
    try sink.out.appendSlice(sink.allocator, chunk);
}

fn extractCopyColumns(allocator: std.mem.Allocator, cmd: *const QailCmd) ![][]const u8 {
    var columns: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer columns.deinit(allocator);

    if (cmd.columns.len != 0) {
        for (cmd.columns) |column_expr| {
            switch (column_expr) {
                .named => |name| try columns.append(allocator, name),
                .aliased => |a| try columns.append(allocator, a.name),
                .star => {},
                else => return error.InvalidCopyColumnExpression,
            }
        }
    } else if (cmd.assignments.len != 0) {
        for (cmd.assignments) |assignment| {
            try columns.append(allocator, assignment.column);
        }
    }

    if (columns.items.len == 0) return error.CopyColumnsRequired;
    return try columns.toOwnedSlice(allocator);
}

fn buildAlterTableRlsSql(
    allocator: std.mem.Allocator,
    table: []const u8,
    clause: []const u8,
) ![]u8 {
    const quoted_table = try quoteIdentifierAlloc(allocator, table);
    defer allocator.free(quoted_table);

    return std.fmt.allocPrint(allocator, "ALTER TABLE {s} {s}", .{ quoted_table, clause });
}

fn quoteSingleLiteralAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidReplicationOption;

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn validateIdent(kind: []const u8, ident: []const u8) !void {
    if (ident.len == 0) return error.InvalidIdentifier;
    if (ident.len > 63) return error.InvalidIdentifier;

    const first = ident[0];
    if (!(first == '_' or std.ascii.isAlphabetic(first))) return error.InvalidIdentifier;

    for (ident[1..]) |ch| {
        if (!(ch == '_' or std.ascii.isAlphanumeric(ch))) return error.InvalidIdentifier;
    }

    _ = kind;
}

fn parseLsnText(lsn: []const u8) !u64 {
    const slash = std.mem.indexOfScalar(u8, lsn, '/') orelse return error.InvalidLsn;
    if (slash == 0 or slash == lsn.len - 1) return error.InvalidLsn;
    if (std.mem.indexOfScalarPos(u8, lsn, slash + 1, '/') != null) return error.InvalidLsn;

    const high = std.fmt.parseInt(u32, lsn[0..slash], 16) catch return error.InvalidLsn;
    const low = std.fmt.parseInt(u32, lsn[slash + 1 ..], 16) catch return error.InvalidLsn;
    return (@as(u64, high) << 32) | low;
}

fn parseExplainJson(json: []const u8) ?ExplainEstimate {
    const total_cost = extractJsonNumber(json, "Total Cost") orelse return null;
    const plan_rows_f = extractJsonNumber(json, "Plan Rows") orelse return null;

    if (!std.math.isFinite(total_cost) or !std.math.isFinite(plan_rows_f)) return null;
    if (plan_rows_f < 0) return null;

    const max_u64_f = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    if (plan_rows_f > max_u64_f) return null;

    return .{
        .total_cost = total_cost,
        .plan_rows = @intFromFloat(plan_rows_f),
    };
}

fn extractJsonNumber(json: []const u8, key: []const u8) ?f64 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after_key = json[start + pattern.len ..];
    const trimmed = std.mem.trimLeft(u8, after_key, " \t\r\n");

    var end: usize = 0;
    while (end < trimmed.len and isJsonNumberByte(trimmed[end])) : (end += 1) {}
    if (end == 0) return null;

    return std.fmt.parseFloat(f64, trimmed[0..end]) catch null;
}

fn isJsonNumberByte(ch: u8) bool {
    return std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E';
}

fn buildCreateLogicalReplicationSlotSql(
    allocator: std.mem.Allocator,
    slot_name: []const u8,
    output_plugin: []const u8,
    temporary: bool,
    two_phase: bool,
) ![]u8 {
    try validateIdent("slot_name", slot_name);
    try validateIdent("output_plugin", output_plugin);

    var sql: std.ArrayListUnmanaged(u8) = .{};
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator, "CREATE_REPLICATION_SLOT ");
    try sql.appendSlice(allocator, slot_name);
    if (temporary) try sql.appendSlice(allocator, " TEMPORARY");
    try sql.appendSlice(allocator, " LOGICAL ");
    try sql.appendSlice(allocator, output_plugin);
    if (two_phase) try sql.appendSlice(allocator, " TWO_PHASE");

    return try sql.toOwnedSlice(allocator);
}

fn buildDropReplicationSlotSql(
    allocator: std.mem.Allocator,
    slot_name: []const u8,
    wait: bool,
) ![]u8 {
    try validateIdent("slot_name", slot_name);

    var sql: std.ArrayListUnmanaged(u8) = .{};
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator, "DROP_REPLICATION_SLOT ");
    try sql.appendSlice(allocator, slot_name);
    if (wait) try sql.appendSlice(allocator, " WAIT");
    return try sql.toOwnedSlice(allocator);
}

fn buildStartLogicalReplicationSql(
    allocator: std.mem.Allocator,
    slot_name: []const u8,
    start_lsn: []const u8,
    options: []const ReplicationOption,
) ![]u8 {
    try validateIdent("slot_name", slot_name);
    _ = try parseLsnText(start_lsn);

    if (options.len > PgDriver.MAX_REPLICATION_OPTIONS) return error.InvalidReplicationOption;

    var sql: std.ArrayListUnmanaged(u8) = .{};
    errdefer sql.deinit(allocator);

    try sql.appendSlice(allocator, "START_REPLICATION SLOT ");
    try sql.appendSlice(allocator, slot_name);
    try sql.appendSlice(allocator, " LOGICAL ");
    try sql.appendSlice(allocator, start_lsn);

    if (options.len != 0) {
        try sql.appendSlice(allocator, " (");
        for (options, 0..) |opt, i| {
            try validateIdent("replication option key", opt.key);
            if (opt.value.len > PgDriver.MAX_REPLICATION_OPTION_VALUE_BYTES) return error.InvalidReplicationOption;

            if (i > 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, opt.key);
            try sql.appendSlice(allocator, " '");

            const escaped = try quoteSingleLiteralAlloc(allocator, opt.value);
            defer allocator.free(escaped);
            try sql.appendSlice(allocator, escaped);
            try sql.append(allocator, '\'');
        }
        try sql.append(allocator, ')');
    }

    return try sql.toOwnedSlice(allocator);
}

fn parseIdentifySystemRow(allocator: std.mem.Allocator, row: *const PgRow) !IdentifySystem {
    const system_id_raw = row.getString(0) orelse return error.InvalidReplicationResponse;
    const timeline_raw = row.getString(1) orelse return error.InvalidReplicationResponse;
    const xlog_pos_raw = row.getString(2) orelse return error.InvalidReplicationResponse;

    const timeline = std.fmt.parseInt(u32, timeline_raw, 10) catch return error.InvalidReplicationResponse;
    const system_id = try allocator.dupe(u8, system_id_raw);
    errdefer allocator.free(system_id);
    const xlog_pos = try allocator.dupe(u8, xlog_pos_raw);
    errdefer allocator.free(xlog_pos);

    var dbname: ?[]u8 = null;
    if (row.getString(3)) |dbname_raw| {
        if (dbname_raw.len != 0) {
            dbname = try allocator.dupe(u8, dbname_raw);
        }
    }

    return .{
        .system_id = system_id,
        .timeline = timeline,
        .xlog_pos = xlog_pos,
        .dbname = dbname,
        .allocator = allocator,
    };
}

fn parseCreateSlotRow(allocator: std.mem.Allocator, row: *const PgRow) !ReplicationSlotInfo {
    const slot_name_raw = row.getString(0) orelse return error.InvalidReplicationResponse;
    const consistent_point_raw = row.getString(1) orelse return error.InvalidReplicationResponse;
    const output_plugin_raw = row.getString(3) orelse return error.InvalidReplicationResponse;

    const slot_name = try allocator.dupe(u8, slot_name_raw);
    errdefer allocator.free(slot_name);
    const consistent_point = try allocator.dupe(u8, consistent_point_raw);
    errdefer allocator.free(consistent_point);
    const output_plugin = try allocator.dupe(u8, output_plugin_raw);
    errdefer allocator.free(output_plugin);

    var snapshot_name: ?[]u8 = null;
    if (row.getString(2)) |snapshot_name_raw| {
        if (snapshot_name_raw.len != 0) {
            snapshot_name = try allocator.dupe(u8, snapshot_name_raw);
        }
    }

    return .{
        .slot_name = slot_name,
        .consistent_point = consistent_point,
        .snapshot_name = snapshot_name,
        .output_plugin = output_plugin,
        .allocator = allocator,
    };
}

fn parseReplicationCopyData(allocator: std.mem.Allocator, payload: []const u8) !ReplicationStreamMessage {
    if (payload.len == 0) return error.InvalidReplicationCopyData;

    switch (payload[0]) {
        'w' => {
            if (payload.len < 25) return error.InvalidReplicationCopyData;

            const wal_start = std.mem.readInt(u64, payload[1..9], .big);
            const wal_end = std.mem.readInt(u64, payload[9..17], .big);
            const server_time_micros = std.mem.readInt(i64, payload[17..25], .big);

            if (wal_end < wal_start) return error.InvalidReplicationCopyData;

            const data_len = payload.len - 25;
            if (data_len > PgDriver.MAX_REPLICATION_XLOGDATA_BYTES) return error.InvalidReplicationCopyData;

            return .{ .xlog_data = .{
                .wal_start = wal_start,
                .wal_end = wal_end,
                .server_time_micros = server_time_micros,
                .data = try allocator.dupe(u8, payload[25..]),
                .allocator = allocator,
            } };
        },
        'k' => {
            if (payload.len != 18) return error.InvalidReplicationCopyData;

            const wal_end = std.mem.readInt(u64, payload[1..9], .big);
            const server_time_micros = std.mem.readInt(i64, payload[9..17], .big);
            const reply_requested = switch (payload[17]) {
                0 => false,
                1 => true,
                else => return error.InvalidReplicationCopyData,
            };

            return .{ .keepalive = .{
                .wal_end = wal_end,
                .server_time_micros = server_time_micros,
                .reply_requested = reply_requested,
            } };
        },
        else => {
            return .{ .raw = .{
                .tag = payload[0],
                .payload = try allocator.dupe(u8, payload[1..]),
                .allocator = allocator,
            } };
        },
    }
}

fn postgresEpochMicrosNow() i64 {
    const pg_unix_epoch_diff_secs: i64 = 946_684_800;
    return std.time.microTimestamp() - (pg_unix_epoch_diff_secs * 1_000_000);
}

fn buildStandbyStatusUpdatePayload(
    write_lsn: u64,
    flush_lsn: u64,
    apply_lsn: u64,
    reply_requested: bool,
) [34]u8 {
    var payload: [34]u8 = undefined;
    payload[0] = 'r';
    std.mem.writeInt(u64, payload[1..9], write_lsn, .big);
    std.mem.writeInt(u64, payload[9..17], flush_lsn, .big);
    std.mem.writeInt(u64, payload[17..25], apply_lsn, .big);
    std.mem.writeInt(i64, payload[25..33], postgresEpochMicrosNow(), .big);
    payload[33] = if (reply_requested) 1 else 0;
    return payload;
}

fn sendCopyData(conn: anytype, data: []const u8) !void {
    if (data.len > std.math.maxInt(u32) - 4) return error.CopyDataTooLarge;
    const len: u32 = @intCast(data.len + 4);
    var header: [5]u8 = undefined;
    header[0] = 'd';
    std.mem.writeInt(u32, header[1..5], len, .big);
    try conn.send(&header);
    try conn.send(data);
}

fn freeRows(allocator: std.mem.Allocator, rows: []PgRow) void {
    for (rows) |*row| row.deinit();
    allocator.free(rows);
}

// Tests
test "pgdriver struct" {
    // Just test the struct can be referenced
    _ = PgDriver;
}

test "parse connection url with query options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseConnectionUrl(
        arena,
        "postgres://alice:secret@db.internal:5433/app?replication=database&channel_binding=require&auth_md5=false&connect_timeout=5",
    );

    try std.testing.expectEqualStrings("db.internal", parsed.host);
    try std.testing.expectEqual(@as(u16, 5433), parsed.port);
    try std.testing.expectEqualStrings("alice", parsed.user);
    try std.testing.expectEqualStrings("app", parsed.database);
    try std.testing.expect(parsed.password != null);
    try std.testing.expectEqualStrings("secret", parsed.password.?);
    try std.testing.expect(parsed.logical_replication);
    try std.testing.expectEqual(auth_options_mod.ScramChannelBindingMode.require, parsed.options.auth_options.scram_channel_binding);
    try std.testing.expect(!parsed.options.auth_options.allow_md5_password);
    try std.testing.expectEqual(@as(?i32, 5000), parsed.options.timeout_ms);
}

test "parse connection url decodes percent encoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseConnectionUrl(arena, "postgresql://user%40name:p%2Bss@127.0.0.1/my%2Ddb");
    try std.testing.expectEqualStrings("user@name", parsed.user);
    try std.testing.expect(parsed.password != null);
    try std.testing.expectEqualStrings("p+ss", parsed.password.?);
    try std.testing.expectEqualStrings("my-db", parsed.database);
}

test "parse connection url rejects invalid sslmode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(
        error.InvalidTlsMode,
        parseConnectionUrl(arena, "postgres://alice@localhost/db?sslmode=bogus"),
    );
}

test "parse connection url preserves strict sslmode variants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed_verify_ca = try parseConnectionUrl(
        arena,
        "postgres://alice@localhost/db?sslmode=verify-ca",
    );
    try std.testing.expectEqual(TlsMode.verify_ca, parsed_verify_ca.options.tls_mode);

    const parsed_verify_full = try parseConnectionUrl(
        arena,
        "postgres://alice@localhost/db?sslmode=verify-full",
    );
    try std.testing.expectEqual(TlsMode.verify_full, parsed_verify_full.options.tls_mode);
}

test "parse connection url loads tls server end point cert der path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cert_der = [_]u8{ 0x30, 0x82, 0x01, 0x0A };
    try tmp.dir.writeFile(.{
        .sub_path = "leaf.der",
        .data = &cert_der,
    });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);
    const cert_path = try std.fmt.allocPrint(
        arena,
        "{s}/.zig-cache/tmp/{s}/leaf.der",
        .{ cwd, tmp.sub_path },
    );
    const url = try std.fmt.allocPrint(
        arena,
        "postgres://alice@localhost/db?tls_server_end_point_cert_der={s}",
        .{cert_path},
    );

    const parsed = try parseConnectionUrl(
        arena,
        url,
    );
    try std.testing.expect(parsed.options.tls_config != null);
    try std.testing.expect(parsed.options.tls_config.?.tls_server_end_point_cert_der != null);
    try std.testing.expectEqual(@as(usize, cert_der.len), parsed.options.tls_config.?.tls_server_end_point_cert_der.?.len);
    try std.testing.expectEqual(TlsMode.require, parsed.options.tls_mode);
}

test "parse connection url rejects missing sslrootcert path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(
        error.FileNotFound,
        parseConnectionUrl(
            arena,
            "postgres://alice@localhost/db?sslrootcert=/definitely-not-found-ca-bundle.pem",
        ),
    );
}

test "builder connect validates required fields" {
    const builder = PgDriver.builder(std.testing.allocator).database("app");
    try std.testing.expectError(error.UserRequired, builder.connect());
}

test "make cancel key preserves wire bytes via bitcast" {
    const key = makeCancelKey(0xFFFF_FF01, 0x8000_0002);
    try std.testing.expectEqual(@as(i32, -255), key.process_id);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8000_0002))), key.secret_key);
}

test "connect with options accepts tls timeout path" {
    const options = ConnectOptions{
        .tls_mode = .require,
        .timeout_ms = 1000,
    };
    const result = PgDriver.connectWithOptions(
        std.testing.allocator,
        "127.0.0.1",
        1,
        "user",
        "db",
        null,
        options,
    );
    if (result) |driver| {
        var mutable_driver = driver;
        mutable_driver.deinit();
    } else |err| {
        try std.testing.expect(err != error.UnsupportedTlsConnectTimeout);
    }
}

test "connect with verify-full requires verification config" {
    const options = ConnectOptions{
        .tls_mode = .verify_full,
    };

    try std.testing.expectError(
        error.TlsVerificationRequired,
        PgDriver.connectWithOptions(
            std.testing.allocator,
            "127.0.0.1",
            5432,
            "user",
            "db",
            null,
            options,
        ),
    );
}

test "quote identifier alloc" {
    const quoted = try quoteIdentifierAlloc(std.testing.allocator, "a\"b");
    defer std.testing.allocator.free(quoted);

    try std.testing.expectEqualStrings("\"a\"\"b\"", quoted);
}

test "parse lsn text" {
    const lsn = try parseLsnText("16/B6C50");
    try std.testing.expectEqual(@as(u64, 0x00000016000B6C50), lsn);
}

test "build start logical replication sql with options" {
    const sql = try buildStartLogicalReplicationSql(
        std.testing.allocator,
        "slot_main",
        "0/16B6C50",
        &.{
            .{ .key = "proto_version", .value = "1" },
            .{ .key = "publication_names", .value = "pub1,pub2" },
        },
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "START_REPLICATION SLOT slot_main LOGICAL 0/16B6C50 (proto_version '1', publication_names 'pub1,pub2')",
        sql,
    );
}

test "build start logical replication sql escapes quoted option values" {
    const sql = try buildStartLogicalReplicationSql(
        std.testing.allocator,
        "slot_main",
        "0/16B6C50",
        &.{
            .{ .key = "publication_names", .value = "pub'one" },
        },
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "START_REPLICATION SLOT slot_main LOGICAL 0/16B6C50 (publication_names 'pub''one')",
        sql,
    );
}

test "build start logical replication sql rejects invalid slot identifier" {
    try std.testing.expectError(
        error.InvalidIdentifier,
        buildStartLogicalReplicationSql(
            std.testing.allocator,
            "slot-main",
            "0/16B6C50",
            &.{},
        ),
    );
}

test "build start logical replication sql rejects invalid lsn" {
    try std.testing.expectError(
        error.InvalidLsn,
        buildStartLogicalReplicationSql(
            std.testing.allocator,
            "slot_main",
            "invalid",
            &.{},
        ),
    );
}

test "build start logical replication sql rejects option value with embedded nul" {
    const invalid_value = [_]u8{ 'b', 'a', 'd', 0, 'x' };
    try std.testing.expectError(
        error.InvalidReplicationOption,
        buildStartLogicalReplicationSql(
            std.testing.allocator,
            "slot_main",
            "0/16B6C50",
            &.{
                .{ .key = "publication_names", .value = invalid_value[0..] },
            },
        ),
    );
}

test "build create logical replication slot sql with flags" {
    const sql = try buildCreateLogicalReplicationSlotSql(
        std.testing.allocator,
        "slot_main",
        "pgoutput",
        true,
        true,
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings(
        "CREATE_REPLICATION_SLOT slot_main TEMPORARY LOGICAL pgoutput TWO_PHASE",
        sql,
    );
}

test "build create logical replication slot sql rejects invalid plugin identifier" {
    try std.testing.expectError(
        error.InvalidIdentifier,
        buildCreateLogicalReplicationSlotSql(
            std.testing.allocator,
            "slot_main",
            "pg-output",
            false,
            false,
        ),
    );
}

test "build drop replication slot sql with wait" {
    const sql = try buildDropReplicationSlotSql(
        std.testing.allocator,
        "slot_main",
        true,
    );
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("DROP_REPLICATION_SLOT slot_main WAIT", sql);
}

test "build drop replication slot sql rejects invalid slot identifier" {
    try std.testing.expectError(
        error.InvalidIdentifier,
        buildDropReplicationSlotSql(
            std.testing.allocator,
            "slot-main",
            false,
        ),
    );
}

test "build alter table rls sql quotes identifier" {
    const sql = try buildAlterTableRlsSql(std.testing.allocator, "tenant\"orders", "ENABLE ROW LEVEL SECURITY");
    defer std.testing.allocator.free(sql);

    try std.testing.expectEqualStrings("ALTER TABLE \"tenant\"\"orders\" ENABLE ROW LEVEL SECURITY", sql);
}

test "parse explain json estimate" {
    const json =
        \\[{"Plan":{"Node Type":"Seq Scan","Relation Name":"users","Total Cost":1234.56,"Plan Rows":5000}}]
    ;

    const estimate = parseExplainJson(json) orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqRel(@as(f64, 1234.56), estimate.total_cost, 1e-12);
    try std.testing.expectEqual(@as(u64, 5000), estimate.plan_rows);
}

test "parse explain json invalid" {
    try std.testing.expect(parseExplainJson("not json") == null);
    try std.testing.expect(parseExplainJson("{}") == null);
    try std.testing.expect(parseExplainJson("[]") == null);
}

test "extract copy columns from add command columns" {
    const cols = [_]Expr{
        Expr.col("id"),
        Expr.colAs("name", "n"),
    };
    const cmd = QailCmd.add("users").select(&cols);

    const extracted = try extractCopyColumns(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(extracted);

    try std.testing.expectEqual(@as(usize, 2), extracted.len);
    try std.testing.expectEqualStrings("id", extracted[0]);
    try std.testing.expectEqualStrings("name", extracted[1]);
}

test "extract copy columns falls back to assignments" {
    const assignments = [_]ast.Assignment{
        .{ .column = "tenant_id", .value = ast.Value.fromInt(1) },
        .{ .column = "name", .value = ast.Value.fromString("alpha") },
    };
    const cmd = QailCmd.add("users").values(&assignments);

    const extracted = try extractCopyColumns(std.testing.allocator, &cmd);
    defer std.testing.allocator.free(extracted);

    try std.testing.expectEqual(@as(usize, 2), extracted.len);
    try std.testing.expectEqualStrings("tenant_id", extracted[0]);
    try std.testing.expectEqualStrings("name", extracted[1]);
}

fn makeOwnedTestRow(columns: []const ?[]const u8, field_names: []const []const u8) !PgRow {
    var owned_columns = try std.testing.allocator.alloc(?[]const u8, columns.len);
    errdefer {
        for (owned_columns) |maybe_col| {
            if (maybe_col) |col| std.testing.allocator.free(col);
        }
        std.testing.allocator.free(owned_columns);
    }

    for (columns, 0..) |maybe_col, i| {
        owned_columns[i] = if (maybe_col) |col|
            try std.testing.allocator.dupe(u8, col)
        else
            null;
    }

    return PgRow.initOwned(std.testing.allocator, owned_columns, field_names);
}

test "parse identify system row" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "sysid", "7", "0/16B6C50", "appdb" },
        &.{ "systemid", "timeline", "xlogpos", "dbname" },
    );
    defer row.deinit();

    var info = try parseIdentifySystemRow(std.testing.allocator, &row);
    defer info.deinit();

    try std.testing.expectEqualStrings("sysid", info.system_id);
    try std.testing.expectEqual(@as(u32, 7), info.timeline);
    try std.testing.expectEqualStrings("0/16B6C50", info.xlog_pos);
    try std.testing.expect(info.dbname != null);
    try std.testing.expectEqualStrings("appdb", info.dbname.?);
}

test "parse identify system row allows empty dbname" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "sysid", "7", "0/16B6C50", "" },
        &.{ "systemid", "timeline", "xlogpos", "dbname" },
    );
    defer row.deinit();

    var info = try parseIdentifySystemRow(std.testing.allocator, &row);
    defer info.deinit();

    try std.testing.expect(info.dbname == null);
}

test "parse identify system row rejects invalid timeline" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "sysid", "bad", "0/16B6C50", "appdb" },
        &.{ "systemid", "timeline", "xlogpos", "dbname" },
    );
    defer row.deinit();

    try std.testing.expectError(error.InvalidReplicationResponse, parseIdentifySystemRow(std.testing.allocator, &row));
}

test "parse create slot row" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "slot_main", "0/16B6C50", "snap_a", "pgoutput" },
        &.{ "slot_name", "consistent_point", "snapshot_name", "output_plugin" },
    );
    defer row.deinit();

    var info = try parseCreateSlotRow(std.testing.allocator, &row);
    defer info.deinit();

    try std.testing.expectEqualStrings("slot_main", info.slot_name);
    try std.testing.expectEqualStrings("0/16B6C50", info.consistent_point);
    try std.testing.expect(info.snapshot_name != null);
    try std.testing.expectEqualStrings("snap_a", info.snapshot_name.?);
    try std.testing.expectEqualStrings("pgoutput", info.output_plugin);
}

test "parse create slot row allows empty snapshot" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "slot_main", "0/16B6C50", "", "pgoutput" },
        &.{ "slot_name", "consistent_point", "snapshot_name", "output_plugin" },
    );
    defer row.deinit();

    var info = try parseCreateSlotRow(std.testing.allocator, &row);
    defer info.deinit();

    try std.testing.expect(info.snapshot_name == null);
}

test "parse create slot row rejects missing output plugin" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "slot_main", "0/16B6C50", "snap_a", null },
        &.{ "slot_name", "consistent_point", "snapshot_name", "output_plugin" },
    );
    defer row.deinit();

    try std.testing.expectError(error.InvalidReplicationResponse, parseCreateSlotRow(std.testing.allocator, &row));
}

fn makeHardeningTestDriver() PgDriver {
    return .{
        .conn = .{ .plain = undefined },
        .allocator = std.testing.allocator,
        .encoder = undefined,
        .cache = undefined,
        .connect_host = null,
        .connect_port = null,
        .notifications = .{},
        .replication_mode_enabled = false,
        .replication_stream_active = false,
        .last_replication_wal_end = null,
    };
}

test "replication hardening: ensure replication mode required" {
    var driver = makeHardeningTestDriver();
    try std.testing.expectError(error.ReplicationModeRequired, driver.ensureReplicationMode("IDENTIFY_SYSTEM"));
}

test "replication hardening: control operations blocked while stream active" {
    var driver = makeHardeningTestDriver();
    driver.replication_mode_enabled = true;
    driver.replication_stream_active = true;

    try std.testing.expectError(error.ReplicationStreamAlreadyActive, driver.ensureReplicationControlIdle("DROP_REPLICATION_SLOT"));
}

test "replication hardening: wal end must be monotonic" {
    var driver = makeHardeningTestDriver();
    driver.replication_mode_enabled = true;
    driver.replication_stream_active = true;
    driver.last_replication_wal_end = 100;

    try std.testing.expectError(error.InvalidReplicationWalEnd, driver.advanceReplicationWalEnd("XLogData", 99));
    try std.testing.expect(!driver.replication_stream_active);
    try std.testing.expect(driver.last_replication_wal_end == null);
}

test "replication hardening: standby update validates lsn ordering" {
    var driver = makeHardeningTestDriver();
    driver.replication_mode_enabled = true;
    driver.replication_stream_active = true;
    driver.last_replication_wal_end = 100;

    try std.testing.expectError(error.InvalidStandbyStatusUpdate, driver.sendStandbyStatusUpdate(90, 91, 91, false));
    try std.testing.expectError(error.InvalidStandbyStatusUpdate, driver.sendStandbyStatusUpdate(90, 90, 91, false));
    try std.testing.expectError(error.InvalidStandbyStatusUpdate, driver.sendStandbyStatusUpdate(101, 100, 100, false));
}

const CopyDataMockConn = struct {
    send_count: usize = 0,

    fn send(self: *CopyDataMockConn, bytes: []const u8) !void {
        _ = bytes;
        self.send_count += 1;
    }
};

test "replication hardening: sendCopyData rejects oversized payload" {
    var conn = CopyDataMockConn{};
    const too_large_len = @as(usize, std.math.maxInt(u32)) - 3;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.CopyDataTooLarge, sendCopyData(&conn, payload));
    try std.testing.expectEqual(@as(usize, 0), conn.send_count);
}

test "parse replication copy data xlog data" {
    var payload: [25 + 3]u8 = undefined;
    payload[0] = 'w';
    std.mem.writeInt(u64, payload[1..9], 0x10, .big);
    std.mem.writeInt(u64, payload[9..17], 0x20, .big);
    std.mem.writeInt(i64, payload[17..25], 1234, .big);
    payload[25] = 'a';
    payload[26] = 'b';
    payload[27] = 'c';

    var msg = try parseReplicationCopyData(std.testing.allocator, &payload);
    defer msg.deinit();

    switch (msg) {
        .xlog_data => |x| {
            try std.testing.expectEqual(@as(u64, 0x10), x.wal_start);
            try std.testing.expectEqual(@as(u64, 0x20), x.wal_end);
            try std.testing.expectEqual(@as(i64, 1234), x.server_time_micros);
            try std.testing.expectEqualStrings("abc", x.data);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse replication copy data keepalive" {
    var payload: [18]u8 = undefined;
    payload[0] = 'k';
    std.mem.writeInt(u64, payload[1..9], 0x20, .big);
    std.mem.writeInt(i64, payload[9..17], 5678, .big);
    payload[17] = 1;

    var msg = try parseReplicationCopyData(std.testing.allocator, &payload);
    defer msg.deinit();

    switch (msg) {
        .keepalive => |k| {
            try std.testing.expectEqual(@as(u64, 0x20), k.wal_end);
            try std.testing.expectEqual(@as(i64, 5678), k.server_time_micros);
            try std.testing.expect(k.reply_requested);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse replication copy data rejects wal end regression" {
    var payload: [25]u8 = undefined;
    payload[0] = 'w';
    std.mem.writeInt(u64, payload[1..9], 0x20, .big);
    std.mem.writeInt(u64, payload[9..17], 0x10, .big);
    std.mem.writeInt(i64, payload[17..25], 0, .big);

    try std.testing.expectError(error.InvalidReplicationCopyData, parseReplicationCopyData(std.testing.allocator, &payload));
}

test "parse replication copy data rejects invalid keepalive reply flag" {
    var payload: [18]u8 = undefined;
    payload[0] = 'k';
    std.mem.writeInt(u64, payload[1..9], 0x20, .big);
    std.mem.writeInt(i64, payload[9..17], 0, .big);
    payload[17] = 2;

    try std.testing.expectError(error.InvalidReplicationCopyData, parseReplicationCopyData(std.testing.allocator, &payload));
}

test "parse replication copy data preserves unknown tags" {
    const payload = [_]u8{ 'z', 'a', 'b', 'c' };
    var msg = try parseReplicationCopyData(std.testing.allocator, &payload);
    defer msg.deinit();

    switch (msg) {
        .raw => |r| {
            try std.testing.expectEqual(@as(u8, 'z'), r.tag);
            try std.testing.expectEqualStrings("abc", r.payload);
        },
        else => return error.TestExpectedEqual,
    }
}
