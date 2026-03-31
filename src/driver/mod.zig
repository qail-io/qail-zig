// PostgreSQL Driver Module
//
// Async driver for PostgreSQL using the protocol layer.

pub const connection = @import("connection.zig");
pub const async_connection = @import("async_connection.zig");
pub const tls = @import("tls.zig");
pub const gssenc = @import("gssenc.zig");
pub const driver = @import("driver.zig");
pub const row = @import("row.zig");
pub const pipeline = @import("pipeline.zig");
pub const pool = @import("pool.zig");
pub const copy = @import("copy.zig");
pub const io_backend = @import("io_backend.zig");

// New driver modules
pub const cancel = @import("cancel.zig");
pub const transaction = @import("transaction.zig");
pub const prepared = @import("prepared.zig");
pub const cursor = @import("cursor.zig");
pub const io = @import("io.zig");
pub const query = @import("query.zig");
pub const metrics = @import("metrics.zig");
pub const auth_options = @import("auth_options.zig");
pub const explain_estimate = @import("explain_estimate.zig");
pub const rls = @import("rls.zig");
pub const connect_url = @import("connect_url.zig");
pub const notification = @import("notification.zig");
pub const replication = @import("replication.zig");
pub const kerberos_preflight = @import("kerberos_preflight.zig");
pub const kerberos_provider = @import("kerberos_provider.zig");

// Re-export main types
pub const Connection = connection.Connection;
pub const AsyncConnection = async_connection.AsyncConnection;
pub const TlsConnection = tls.TlsConnection;
pub const GssEncConnection = gssenc.GssEncConnection;
pub const TlsConfig = tls.TlsConfig;
pub const VerifyMode = tls.VerifyMode;
pub const PgDriver = driver.PgDriver;
pub const PgRow = row.PgRow;
pub const Pipeline = pipeline.Pipeline;
pub const PgPool = pool.PgPool;
pub const PoolConfig = pool.PoolConfig;
pub const PooledConnection = pool.PooledConnection;
pub const ScopedPoolOp = pool.ScopedPoolOp;

// New type exports
pub const CancelKey = cancel.CancelKey;
pub const cancelQuery = cancel.cancelQuery;
pub const Transaction = transaction.Transaction;
pub const PreparedStatement = prepared.PreparedStatement;
pub const Cursor = cursor.Cursor;
pub const IoBuffer = io.IoBuffer;
pub const WriteBuffer = io.WriteBuffer;
pub const StatementCache = query.StatementCache;
pub const PoolMetrics = metrics.PoolMetrics;
pub const IoBackend = io_backend.Backend;
pub const IoBackendPolicy = io_backend.Policy;
pub const QueryOpts = driver.QueryOpts;
pub const ExplainEstimate = explain_estimate.ExplainEstimate;
pub const CopyChunkHandler = driver.CopyChunkHandler;
pub const Notification = notification.Notification;
pub const PgDriverBuilder = driver.PgDriverBuilder;
pub const ConnectOptions = connect_url.ConnectOptions;
pub const TlsMode = connect_url.TlsMode;
pub const GssEncMode = connect_url.GssEncMode;
pub const IdentifySystem = replication.IdentifySystem;
pub const ReplicationSlotInfo = replication.ReplicationSlotInfo;
pub const ReplicationOption = replication.ReplicationOption;
pub const ReplicationStreamStart = replication.ReplicationStreamStart;
pub const ReplicationXLogData = replication.ReplicationXLogData;
pub const ReplicationKeepalive = replication.ReplicationKeepalive;
pub const ReplicationStreamMessage = replication.ReplicationStreamMessage;
pub const AuthOptions = auth_options.AuthOptions;
pub const CancelToken = driver.CancelToken;
pub const GssMechanism = auth_options.GssMechanism;
pub const GssTokenProvider = auth_options.GssTokenProvider;
pub const GssTokenRequest = auth_options.GssTokenRequest;
pub const GssTokenProviderEx = auth_options.GssTokenProviderEx;
pub const ScramChannelBindingMode = auth_options.ScramChannelBindingMode;
pub const LinuxKrb5ProviderConfig = kerberos_preflight.LinuxKrb5ProviderConfig;
pub const LinuxKrb5PreflightReport = kerberos_preflight.LinuxKrb5PreflightReport;
pub const linuxKrb5Preflight = kerberos_preflight.linuxKrb5Preflight;
pub const linuxKrb5PreflightWithEnvMap = kerberos_preflight.linuxKrb5PreflightWithEnvMap;
pub const LinuxKrb5Provider = kerberos_provider.LinuxKrb5Provider;
pub const linuxKrb5TokenProvider = kerberos_provider.linuxKrb5TokenProvider;
pub const RlsContext = rls.RlsContext;
pub const SuperAdminToken = rls.SuperAdminToken;
pub const sanitizeGucValue = rls.sanitizeGucValue;
pub const contextToSql = rls.contextToSql;
pub const contextToSqlWithTimeout = rls.contextToSqlWithTimeout;
pub const contextToSqlWithTimeouts = rls.contextToSqlWithTimeouts;
pub const resetRlsSql = rls.resetSql;

// COPY protocol functions
pub const copyIn = copy.copyIn;
pub const copyInRaw = copy.copyInRaw;
pub const copyExport = copy.copyExport;

test {
    @import("std").testing.refAllDecls(@This());
}
