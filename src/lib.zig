// QAIL Zig - Pure Zig PostgreSQL Driver with AST-Native Query Building
//
// This is the root module that exports all QAIL functionality.

pub const ast = @import("ast/mod.zig");
pub const protocol = @import("protocol/mod.zig");
pub const driver = @import("driver/mod.zig");
pub const transpiler = @import("transpiler/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const analyzer = @import("analyzer/mod.zig");
pub const validator = @import("validator.zig");
pub const sanitize = @import("sanitize.zig");
pub const fmt = @import("fmt.zig");
pub const compat = @import("compat/mod.zig");
// LSP is built as a standalone binary, not exported from lib

// Re-export key types for convenience
pub const QailCmd = ast.QailCmd;
pub const Expr = ast.Expr;
pub const Operator = ast.Operator;
pub const Value = ast.Value;
pub const OwnedExpr = ast.OwnedExpr;
pub const OwnedPolicyDef = ast.OwnedPolicyDef;

pub const PgDriver = driver.PgDriver;
pub const PgRow = driver.PgRow;
pub const PgBytesRow = driver.PgBytesRow;
pub const TlsConnection = driver.TlsConnection;
pub const GssEncConnection = driver.GssEncConnection;
pub const TlsConfig = driver.TlsConfig;
pub const VerifyMode = driver.VerifyMode;
pub const ExplainEstimate = driver.ExplainEstimate;
pub const CopyChunkHandler = driver.CopyChunkHandler;
pub const BytesRowHandler = driver.BytesRowHandler;
pub const Notification = driver.Notification;
pub const PgDriverBuilder = driver.PgDriverBuilder;
pub const ConnectOptions = driver.ConnectOptions;
pub const TlsMode = driver.TlsMode;
pub const GssEncMode = driver.GssEncMode;
pub const IdentifySystem = driver.IdentifySystem;
pub const ReplicationSlotInfo = driver.ReplicationSlotInfo;
pub const ReplicationOption = driver.ReplicationOption;
pub const ReplicationStreamStart = driver.ReplicationStreamStart;
pub const ReplicationXLogData = driver.ReplicationXLogData;
pub const ReplicationKeepalive = driver.ReplicationKeepalive;
pub const ReplicationStreamMessage = driver.ReplicationStreamMessage;
pub const AuthOptions = driver.AuthOptions;
pub const CancelToken = driver.CancelToken;
pub const GssMechanism = driver.GssMechanism;
pub const GssTokenProvider = driver.GssTokenProvider;
pub const GssTokenRequest = driver.GssTokenRequest;
pub const GssTokenProviderEx = driver.GssTokenProviderEx;
pub const LinuxKrb5ProviderConfig = driver.LinuxKrb5ProviderConfig;
pub const LinuxKrb5PreflightReport = driver.LinuxKrb5PreflightReport;
pub const LinuxKrb5Provider = driver.LinuxKrb5Provider;
pub const linuxKrb5Preflight = driver.linuxKrb5Preflight;
pub const linuxKrb5PreflightWithEnvMap = driver.linuxKrb5PreflightWithEnvMap;
pub const linuxKrb5TokenProvider = driver.linuxKrb5TokenProvider;
pub const ScramChannelBindingMode = driver.ScramChannelBindingMode;
pub const IoBackend = driver.IoBackend;
pub const IoBackendPolicy = driver.IoBackendPolicy;
pub const RlsContext = driver.RlsContext;
pub const SuperAdminToken = driver.SuperAdminToken;
pub const rlsSqlWithTimeout = driver.contextToSqlWithTimeout;
pub const rlsSqlWithTimeouts = driver.contextToSqlWithTimeouts;
pub const ScopedPoolOp = driver.ScopedPoolOp;
pub const validateAst = sanitize.validateCmd;

// Re-export builders for convenience
pub const builders = ast.builders;
pub const cmd = ast.cmd;
pub const policy = ast.policy;

test {
    @import("std").testing.refAllDecls(@This());
    // Fuzz tests — discovered via explicit import
    _ = @import("fuzz/fuzz_decoder.zig");
    _ = @import("fuzz/fuzz_value.zig");
    _ = @import("fuzz/fuzz_transpiler.zig");
    _ = @import("hardening/protocol_hardening.zig");
    _ = @import("hardening/replication_hardening.zig");
    _ = @import("hardening/startup_hardening.zig");
}
