// PostgreSQL Driver
//
// Main driver struct for executing QAIL AST queries.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../ast/mod.zig");
const net = @import("../compat/net.zig");
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
const connect_url_mod = @import("connect_url.zig");
const explain_estimate_mod = @import("explain_estimate.zig");
const notification_mod = @import("notification.zig");
const replication_mod = @import("replication.zig");
const raw_policy_mod = @import("raw_policy.zig");
const raw_cmd_mod = @import("raw_cmd.zig");
const raw_sql_mod = @import("raw_sql.zig");
const gssenc_request_mod = @import("gssenc_request.zig");
const gssenc_mod = @import("gssenc.zig");
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
const GssEncConnection = gssenc_mod.GssEncConnection;
const CancelKey = cancel_mod.CancelKey;
const PgRow = row_mod.PgRow;
const StatementCache = query_mod.StatementCache;
const MessageResult = struct {
    msg_type: BackendMessage,
    payload: []const u8,
};

/// LISTEN/NOTIFY message from PostgreSQL.
pub const Notification = notification_mod.Notification;

/// Startup metadata from `IDENTIFY_SYSTEM`.
pub const IdentifySystem = replication_mod.IdentifySystem;

/// Output from `CREATE_REPLICATION_SLOT ... LOGICAL ...`.
pub const ReplicationSlotInfo = replication_mod.ReplicationSlotInfo;

/// Logical replication option (`k 'v'`) used by START_REPLICATION.
pub const ReplicationOption = replication_mod.ReplicationOption;

/// Metadata returned by START_REPLICATION CopyBoth response.
pub const ReplicationStreamStart = replication_mod.ReplicationStreamStart;

/// Replication XLogData message (`CopyData('w'...)`).
pub const ReplicationXLogData = replication_mod.ReplicationXLogData;

/// Primary keepalive message (`CopyData('k'...)`).
pub const ReplicationKeepalive = replication_mod.ReplicationKeepalive;

/// Replication stream message parsed from CopyData payload.
pub const ReplicationStreamMessage = replication_mod.ReplicationStreamMessage;

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
pub const ExplainEstimate = explain_estimate_mod.ExplainEstimate;

/// Callback for streaming COPY TO STDOUT chunks.
/// Chunk memory is only valid until callback returns.
pub const CopyChunkHandler = *const fn (
    ctx: ?*anyopaque,
    chunk: []const u8,
) anyerror!void;

pub const TlsMode = connect_url_mod.TlsMode;
pub const GssEncMode = connect_url_mod.GssEncMode;

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

pub const ConnectOptions = connect_url_mod.ConnectOptions;

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
        if (self.force_logical_replication and !connect_url_mod.hasLogicalReplicationStartupMode(options.startup_params) and options.startup_params.len == 0) {
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
    gssenc: GssEncConnection,

    pub fn close(self: *DriverConnection) void {
        switch (self.*) {
            .plain => |*conn| conn.close(),
            .tls => |*conn| conn.close(),
            .gssenc => |*conn| conn.close(),
        }
    }

    pub fn ioBackend(self: *const DriverConnection) io_backend_mod.Backend {
        return switch (self.*) {
            .plain => |conn| conn.ioBackend(),
            .tls => .sync,
            .gssenc => .sync,
        };
    }

    pub fn send(self: *DriverConnection, bytes: []const u8) !void {
        switch (self.*) {
            .plain => |*conn| try conn.send(bytes),
            .tls => |*conn| try conn.send(bytes),
            .gssenc => |*conn| try conn.send(bytes),
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
            .gssenc => |*conn| blk: {
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
            .gssenc => |*conn| try conn.startupWithParamsAndAuth(user, database, password, startup_params, auth_options),
        }
    }

    pub fn sslAccepted(self: *const DriverConnection) bool {
        return switch (self.*) {
            .plain => false,
            .tls => |conn| conn.sslAccepted(),
            .gssenc => false,
        };
    }

    pub fn processId(self: *const DriverConnection) u32 {
        return switch (self.*) {
            .plain => |conn| conn.process_id,
            .tls => |conn| conn.process_id,
            .gssenc => |conn| conn.process_id,
        };
    }

    pub fn secretKey(self: *const DriverConnection) u32 {
        return switch (self.*) {
            .plain => |conn| conn.secret_key,
            .tls => |conn| conn.secret_key,
            .gssenc => |conn| conn.secret_key,
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

        const parsed = try connect_url_mod.parseConnectionUrl(arena, url);
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
        if (options.gss_enc_mode != .disable) {
            const negotiation = try gssenc_request_mod.tryGssEncRequestStream(allocator, host, port, options.timeout_ms);
            switch (negotiation) {
                .accepted => |stream| {
                    const gssenc_conn = gssenc_mod.GssEncConnection.connectFromAcceptedStream(allocator, host, stream) catch |err| {
                        if (builtin.os.tag != .linux and err == error.UnsupportedGssEncTransportPlatform) {
                            return error.GssEncAcceptedButUnsupported;
                        }
                        return err;
                    };
                    return initDriverFromTransport(
                        allocator,
                        host,
                        port,
                        user,
                        database,
                        password,
                        options.startup_params,
                        options.auth_options,
                        .{ .gssenc = gssenc_conn },
                    );
                },
                .rejected, .server_error => {
                    if (options.gss_enc_mode == .require) return error.GssEncRequiredButRejected;
                },
            }
        }

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
        const transport: DriverConnection = switch (tls_mode) {
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
        return initDriverFromTransport(
            allocator,
            host,
            port,
            user,
            database,
            password,
            startup_params,
            auth_options,
            transport,
        );
    }

    fn initDriverFromTransport(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        database: []const u8,
        password: ?[]const u8,
        startup_params: []const StartupParam,
        auth_options: AuthOptions,
        transport: DriverConnection,
    ) !PgDriver {
        var owned_transport = transport;
        errdefer owned_transport.close();

        try owned_transport.startupWithParamsAndAuth(user, database, password, startup_params, auth_options);

        var driver = PgDriver.initTransport(owned_transport, allocator);
        errdefer driver.deinit();
        driver.connect_host = try allocator.dupe(u8, host);
        driver.connect_port = port;
        driver.replication_mode_enabled = connect_url_mod.hasLogicalReplicationStartupMode(startup_params);
        return driver;
    }

    // ==================== AST-Native Query Execution ====================

    /// Execute a QAIL AST command and fetch all rows
    pub fn fetchAll(self: *PgDriver, cmd: *const QailCmd) ![]PgRow {
        try raw_policy_mod.rejectPublicRuntimeCmd(cmd);
        return try self.fetchAllTrusted(cmd);
    }

    fn fetchAllTrusted(self: *PgDriver, cmd: *const QailCmd) ![]PgRow {
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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
        try raw_policy_mod.rejectPublicRuntimeCmd(cmd);
        return try self.executeTrusted(cmd);
    }

    fn executeTrusted(self: *PgDriver, cmd: *const QailCmd) !u64 {
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
                else => {},
            }
        }

        return affected_rows;
    }

    // ==================== Transaction Control ====================

    /// Begin a transaction
    pub fn begin(self: *PgDriver) !void {
        _ = try self.executeTrustedRaw(raw_sql_mod.begin());
    }

    /// Commit the transaction
    pub fn commit(self: *PgDriver) !void {
        _ = try self.executeTrustedRaw(raw_sql_mod.commit());
    }

    /// Rollback the transaction
    pub fn rollback(self: *PgDriver) !void {
        _ = try self.executeTrustedRaw(raw_sql_mod.rollback());
    }

    /// Execute trusted internal raw SQL string.
    fn executeTrustedRaw(self: *PgDriver, sql: []const u8) !u64 {
        const cmd = raw_cmd_mod.command(sql);
        return try self.executeTrusted(&cmd);
    }

    fn fetchAllTrustedRaw(self: *PgDriver, sql: []const u8) ![]PgRow {
        const cmd = raw_cmd_mod.command(sql);
        return try self.fetchAllTrusted(&cmd);
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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
        _ = try self.executeTrustedRaw(sql);
    }

    /// Configure RLS context and statement timeout in one roundtrip.
    pub fn setRlsContextWithTimeout(self: *PgDriver, ctx: *const rls_mod.RlsContext, timeout_ms: u32) !void {
        const sql = try rls_mod.contextToSqlWithTimeout(self.allocator, ctx, timeout_ms);
        defer self.allocator.free(sql);
        _ = try self.executeTrustedRaw(sql);
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
        _ = try self.executeTrustedRaw(sql);
    }

    /// Reset transaction-local RLS/session context.
    pub fn clearRlsContext(self: *PgDriver) !void {
        _ = try self.executeTrustedRaw(rls_mod.resetSql());
    }

    /// ALTER TABLE ... ENABLE ROW LEVEL SECURITY.
    pub fn enableRls(self: *PgDriver, table: []const u8) !void {
        const sql = try raw_sql_mod.buildAlterTableRls(self.allocator, table, .enable);
        defer self.allocator.free(sql);
        _ = try self.executeTrustedRaw(sql);
    }

    /// ALTER TABLE ... DISABLE ROW LEVEL SECURITY.
    pub fn disableRls(self: *PgDriver, table: []const u8) !void {
        const sql = try raw_sql_mod.buildAlterTableRls(self.allocator, table, .disable);
        defer self.allocator.free(sql);
        _ = try self.executeTrustedRaw(sql);
    }

    /// ALTER TABLE ... FORCE ROW LEVEL SECURITY.
    pub fn forceRls(self: *PgDriver, table: []const u8) !void {
        const sql = try raw_sql_mod.buildAlterTableRls(self.allocator, table, .force);
        defer self.allocator.free(sql);
        _ = try self.executeTrustedRaw(sql);
    }

    /// ALTER TABLE ... NO FORCE ROW LEVEL SECURITY.
    pub fn noForceRls(self: *PgDriver, table: []const u8) !void {
        const sql = try raw_sql_mod.buildAlterTableRls(self.allocator, table, .no_force);
        defer self.allocator.free(sql);
        _ = try self.executeTrustedRaw(sql);
    }

    // ==================== EXPLAIN Helpers ====================

    /// Run EXPLAIN (FORMAT JSON) for a QAIL command and parse estimate.
    pub fn explainEstimate(self: *PgDriver, cmd: *const QailCmd) !?ExplainEstimate {
        try raw_policy_mod.rejectPublicRuntimeCmd(cmd);
        const sql = try transpiler.toSql(self.allocator, cmd);
        defer self.allocator.free(sql);
        return try self.explainEstimateSql(sql);
    }

    /// Run EXPLAIN (FORMAT JSON) for raw SQL and parse estimate.
    pub fn explainEstimateSql(self: *PgDriver, sql: []const u8) !?ExplainEstimate {
        const explain_sql = try raw_sql_mod.buildExplainFormatJson(self.allocator, sql);
        defer self.allocator.free(explain_sql);

        const rows = try self.fetchAllTrustedRaw(explain_sql);
        defer freeRows(self.allocator, rows);

        if (rows.len == 0) return null;
        const json_output = rows[0].getString(0) orelse return null;
        return explain_estimate_mod.parseExplainJson(json_output);
    }

    // ==================== LISTEN / NOTIFY ====================

    /// Subscribe to a notification channel.
    pub fn listen(self: *PgDriver, channel: []const u8) !void {
        const sql = try raw_sql_mod.buildListen(self.allocator, channel);
        defer self.allocator.free(sql);

        _ = try self.executeTrustedRaw(sql);
    }

    /// Unsubscribe from a notification channel.
    pub fn unlisten(self: *PgDriver, channel: []const u8) !void {
        const sql = try raw_sql_mod.buildUnlisten(self.allocator, channel);
        defer self.allocator.free(sql);

        _ = try self.executeTrustedRaw(sql);
    }

    /// Unsubscribe from all notification channels.
    pub fn unlistenAll(self: *PgDriver) !void {
        _ = try self.executeTrustedRaw(raw_sql_mod.unlistenAll());
    }

    /// Drain buffered notifications without blocking.
    ///
    /// Caller owns returned slice and each notification payload.
    pub fn pollNotifications(self: *PgDriver) ![]Notification {
        return notification_mod.drainBufferedNotifications(self.allocator, &self.notifications);
    }

    /// Wait for the next notification (blocking).
    ///
    /// Caller owns the returned notification and must call `deinit()`.
    pub fn recvNotification(self: *PgDriver) !Notification {
        if (notification_mod.popBufferedNotification(&self.notifications)) |notification| return notification;

        // Flush pending async messages first.
        var encoder = PgEncoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.encodeQuery("");
        try self.conn.send(encoder.getWritten());

        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .notification => return try notification_mod.decodeNotification(self.allocator, msg.payload),
                .empty_query, .command_complete, .notice, .parameter_status => {},
                .ready_for_query => {
                    if (notification_mod.popBufferedNotification(&self.notifications)) |notification| return notification;
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

        const rows = try self.fetchAllTrustedRaw(raw_sql_mod.identifySystem());
        defer freeRows(self.allocator, rows);

        if (rows.len == 0) return error.InvalidReplicationResponse;
        return try replication_mod.parseIdentifySystemRow(self.allocator, &rows[0]);
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

        const sql = try replication_mod.buildCreateLogicalReplicationSlotSql(self.allocator, slot_name, output_plugin, temporary, two_phase);
        defer self.allocator.free(sql);

        const rows = try self.fetchAllTrustedRaw(sql);
        defer freeRows(self.allocator, rows);

        if (rows.len == 0) return error.InvalidReplicationResponse;
        return try replication_mod.parseCreateSlotRow(self.allocator, &rows[0]);
    }

    /// Drop a replication slot.
    pub fn dropReplicationSlot(self: *PgDriver, slot_name: []const u8, wait: bool) !void {
        try self.ensureReplicationMode("DROP_REPLICATION_SLOT");
        try self.ensureReplicationControlIdle("DROP_REPLICATION_SLOT");

        const sql = try replication_mod.buildDropReplicationSlotSql(self.allocator, slot_name, wait);
        defer self.allocator.free(sql);

        _ = try self.executeTrustedRaw(sql);
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

        const sql = try replication_mod.buildStartLogicalReplicationSql(self.allocator, slot_name, start_lsn, options);
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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
                    var parsed = replication_mod.parseReplicationCopyData(self.allocator, msg.payload) catch |err| {
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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

        const payload = replication_mod.buildStandbyStatusUpdatePayload(write_lsn, flush_lsn, apply_lsn, reply_requested);
        try replication_mod.sendCopyData(&self.conn, &payload);
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
        try raw_policy_mod.rejectPublicRuntimeCmd(cmd);
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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
        try raw_policy_mod.rejectPublicRuntimeCmd(cmd);
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
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
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
                else => {},
            }
        }

        return try rows.toOwnedSlice(self.allocator);
    }

    fn drainUntilReadyForQuery(self: *PgDriver) !void {
        while (true) {
            const msg = try self.conn.readMessage();
            switch (msg.msg_type) {
                .ready_for_query => return,
                .notification => try notification_mod.appendDecodedNotification(self.allocator, &self.notifications, msg.payload),
                else => {},
            }
        }
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

fn makeCancelKey(process_id: u32, secret_key: u32) CancelKey {
    return .{
        .process_id = @bitCast(process_id),
        .secret_key = @bitCast(secret_key),
    };
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

    const parsed = try connect_url_mod.parseConnectionUrl(
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

    const parsed = try connect_url_mod.parseConnectionUrl(arena, "postgresql://user%40name:p%2Bss@127.0.0.1/my%2Ddb");
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
        connect_url_mod.parseConnectionUrl(arena, "postgres://alice@localhost/db?sslmode=bogus"),
    );
}

test "parse connection url preserves strict sslmode variants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed_verify_ca = try connect_url_mod.parseConnectionUrl(
        arena,
        "postgres://alice@localhost/db?sslmode=verify-ca",
    );
    try std.testing.expectEqual(TlsMode.verify_ca, parsed_verify_ca.options.tls_mode);

    const parsed_verify_full = try connect_url_mod.parseConnectionUrl(
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

    const parsed = try connect_url_mod.parseConnectionUrl(
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
        connect_url_mod.parseConnectionUrl(
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

const GssEncServerMode = enum {
    accepted,
    rejected,
    rejected_then_plain_auth_ok,
};

const GssEncServerCtx = struct {
    server: *net.Server,
    mode: GssEncServerMode,
};

fn gssEncServerThread(ctx: *GssEncServerCtx) void {
    defer ctx.server.deinit();

    {
        var conn = ctx.server.accept() catch return;
        defer conn.stream.close();

        var request: [8]u8 = undefined;
        _ = net.readStream(conn.stream, &request) catch return;
        const request_code = std.mem.readInt(u32, request[4..8], .big);
        if (request_code != gssenc_request_mod.GSSENC_REQUEST_CODE) return;

        switch (ctx.mode) {
            .accepted => {
                net.writeAllStream(conn.stream, "G") catch {};
                return;
            },
            .rejected => {
                net.writeAllStream(conn.stream, "N") catch {};
                return;
            },
            .rejected_then_plain_auth_ok => {
                net.writeAllStream(conn.stream, "N") catch {};
            },
        }
    }

    if (ctx.mode == .rejected_then_plain_auth_ok) {
        var conn = ctx.server.accept() catch return;
        defer conn.stream.close();

        readStartupMessage(conn.stream) catch return;
        sendAuthOk(conn.stream) catch return;
        sendReadyForQuery(conn.stream, 'I') catch {};
    }
}

fn readExactStream(stream: net.Stream, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = try net.readStream(stream, buffer[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

fn readStartupMessage(stream: net.Stream) !void {
    var len_buf: [4]u8 = undefined;
    try readExactStream(stream, &len_buf);
    const length = std.mem.readInt(u32, &len_buf, .big);
    if (length < 8) return error.InvalidStartupLength;

    var remaining_buf: [1024]u8 = undefined;
    const remaining = length - 4;
    if (remaining > remaining_buf.len) return error.StartupTooLarge;
    try readExactStream(stream, remaining_buf[0..remaining]);
}

fn writeByte(stream: net.Stream, byte: u8) !void {
    try net.writeAllStream(stream, &.{byte});
}

fn writeU32(stream: net.Stream, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try net.writeAllStream(stream, &buf);
}

fn sendAuthOk(stream: net.Stream) !void {
    try writeByte(stream, 'R');
    try writeU32(stream, 8);
    try writeU32(stream, 0);
}

fn sendReadyForQuery(stream: net.Stream, status: u8) !void {
    try writeByte(stream, 'Z');
    try writeU32(stream, 5);
    try writeByte(stream, status);
}

test "connect with options handles accepted gssenc by platform" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = GssEncServerCtx{ .server = &server, .mode = .accepted };
    var thread = try std.Thread.spawn(.{}, gssEncServerThread, .{&ctx});
    defer thread.join();

    if (builtin.os.tag == .linux) {
        try std.testing.expectError(
            error.ConnectionClosed,
            PgDriver.connectWithOptions(
                std.testing.allocator,
                "127.0.0.1",
                port,
                "user",
                "db",
                null,
                .{ .gss_enc_mode = .prefer },
            ),
        );
    } else {
        try std.testing.expectError(
            error.GssEncAcceptedButUnsupported,
            PgDriver.connectWithOptions(
                std.testing.allocator,
                "127.0.0.1",
                port,
                "user",
                "db",
                null,
                .{ .gss_enc_mode = .prefer },
            ),
        );
    }
}

test "connect with options require fails when gssenc is rejected" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = GssEncServerCtx{ .server = &server, .mode = .rejected };
    var thread = try std.Thread.spawn(.{}, gssEncServerThread, .{&ctx});
    defer thread.join();

    try std.testing.expectError(
        error.GssEncRequiredButRejected,
        PgDriver.connectWithOptions(
            std.testing.allocator,
            "127.0.0.1",
            port,
            "user",
            "db",
            null,
            .{ .gss_enc_mode = .require },
        ),
    );
}

test "connect with options prefer falls through after gssenc rejection over localhost" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = GssEncServerCtx{ .server = &server, .mode = .rejected_then_plain_auth_ok };
    var thread = try std.Thread.spawn(.{}, gssEncServerThread, .{&ctx});
    defer thread.join();

    var driver = try PgDriver.connectWithOptions(
        std.testing.allocator,
        "localhost",
        port,
        "user",
        "db",
        null,
        .{ .gss_enc_mode = .prefer },
    );
    defer driver.deinit();

    try std.testing.expect(driver.connect_port != null);
    try std.testing.expectEqual(port, driver.connect_port.?);
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

test "parse lsn text" {
    const lsn = try replication_mod.parseLsnText("16/B6C50");
    try std.testing.expectEqual(@as(u64, 0x00000016000B6C50), lsn);
}

test "build start logical replication sql with options" {
    const sql = try replication_mod.buildStartLogicalReplicationSql(
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
    const sql = try replication_mod.buildStartLogicalReplicationSql(
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
        replication_mod.buildStartLogicalReplicationSql(
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
        replication_mod.buildStartLogicalReplicationSql(
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
        replication_mod.buildStartLogicalReplicationSql(
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
    const sql = try replication_mod.buildCreateLogicalReplicationSlotSql(
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
        replication_mod.buildCreateLogicalReplicationSlotSql(
            std.testing.allocator,
            "slot_main",
            "pg-output",
            false,
            false,
        ),
    );
}

test "build drop replication slot sql with wait" {
    const sql = try replication_mod.buildDropReplicationSlotSql(
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
        replication_mod.buildDropReplicationSlotSql(
            std.testing.allocator,
            "slot-main",
            false,
        ),
    );
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

    var info = try replication_mod.parseIdentifySystemRow(std.testing.allocator, &row);
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

    var info = try replication_mod.parseIdentifySystemRow(std.testing.allocator, &row);
    defer info.deinit();

    try std.testing.expect(info.dbname == null);
}

test "parse identify system row rejects invalid timeline" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "sysid", "bad", "0/16B6C50", "appdb" },
        &.{ "systemid", "timeline", "xlogpos", "dbname" },
    );
    defer row.deinit();

    try std.testing.expectError(error.InvalidReplicationResponse, replication_mod.parseIdentifySystemRow(std.testing.allocator, &row));
}

test "parse create slot row" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "slot_main", "0/16B6C50", "snap_a", "pgoutput" },
        &.{ "slot_name", "consistent_point", "snapshot_name", "output_plugin" },
    );
    defer row.deinit();

    var info = try replication_mod.parseCreateSlotRow(std.testing.allocator, &row);
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

    var info = try replication_mod.parseCreateSlotRow(std.testing.allocator, &row);
    defer info.deinit();

    try std.testing.expect(info.snapshot_name == null);
}

test "parse create slot row rejects missing output plugin" {
    var row = try makeOwnedTestRow(
        &[_]?[]const u8{ "slot_main", "0/16B6C50", "snap_a", null },
        &.{ "slot_name", "consistent_point", "snapshot_name", "output_plugin" },
    );
    defer row.deinit();

    try std.testing.expectError(error.InvalidReplicationResponse, replication_mod.parseCreateSlotRow(std.testing.allocator, &row));
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

    pub fn send(self: *CopyDataMockConn, bytes: []const u8) !void {
        _ = bytes;
        self.send_count += 1;
    }
};

test "replication hardening: sendCopyData rejects oversized payload" {
    var conn = CopyDataMockConn{};
    const too_large_len = @as(usize, std.math.maxInt(u32)) - 3;
    const payload = @as([*]const u8, @ptrFromInt(1))[0..too_large_len];

    try std.testing.expectError(error.CopyDataTooLarge, replication_mod.sendCopyData(&conn, payload));
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

    var msg = try replication_mod.parseReplicationCopyData(std.testing.allocator, &payload);
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

    var msg = try replication_mod.parseReplicationCopyData(std.testing.allocator, &payload);
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

    try std.testing.expectError(error.InvalidReplicationCopyData, replication_mod.parseReplicationCopyData(std.testing.allocator, &payload));
}

test "parse replication copy data rejects invalid keepalive reply flag" {
    var payload: [18]u8 = undefined;
    payload[0] = 'k';
    std.mem.writeInt(u64, payload[1..9], 0x20, .big);
    std.mem.writeInt(i64, payload[9..17], 0, .big);
    payload[17] = 2;

    try std.testing.expectError(error.InvalidReplicationCopyData, replication_mod.parseReplicationCopyData(std.testing.allocator, &payload));
}

test "parse replication copy data preserves unknown tags" {
    const payload = [_]u8{ 'z', 'a', 'b', 'c' };
    var msg = try replication_mod.parseReplicationCopyData(std.testing.allocator, &payload);
    defer msg.deinit();

    switch (msg) {
        .raw => |r| {
            try std.testing.expectEqual(@as(u8, 'z'), r.tag);
            try std.testing.expectEqualStrings("abc", r.payload);
        },
        else => return error.TestExpectedEqual,
    }
}
