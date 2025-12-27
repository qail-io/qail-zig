//! PostgreSQL Wire Protocol Constants and Message Types
//!
//! Reference: https://www.postgresql.org/docs/current/protocol-message-formats.html

const std = @import("std");

/// PostgreSQL protocol version (3.0)
pub const PROTOCOL_VERSION: u32 = 196608; // 3 << 16

/// Frontend message types (client -> server)
pub const FrontendMessage = enum(u8) {
    /// Bind (B)
    bind = 'B',
    /// Close (C)
    close = 'C',
    /// CopyData (d)
    copy_data = 'd',
    /// CopyDone (c)
    copy_done = 'c',
    /// CopyFail (f)
    copy_fail = 'f',
    /// Describe (D)
    describe = 'D',
    /// Execute (E)
    execute = 'E',
    /// Flush (H)
    flush = 'H',
    /// FunctionCall (F)
    function_call = 'F',
    /// Parse (P)
    parse = 'P',
    /// PasswordMessage (p)
    password = 'p',
    /// Query (Q)
    query = 'Q',
    /// Sync (S)
    sync = 'S',
    /// Terminate (X)
    terminate = 'X',
};

/// Backend message types (server -> client)
pub const BackendMessage = enum(u8) {
    /// AuthenticationOk (R)
    authentication = 'R',
    /// BackendKeyData (K)
    backend_key_data = 'K',
    /// BindComplete (2)
    bind_complete = '2',
    /// CloseComplete (3)
    close_complete = '3',
    /// CommandComplete (C)
    command_complete = 'C',
    /// CopyData (d)
    copy_data = 'd',
    /// CopyDone (c)
    copy_done = 'c',
    /// CopyInResponse (G)
    copy_in_response = 'G',
    /// CopyOutResponse (H)
    copy_out_response = 'H',
    /// DataRow (D)
    data_row = 'D',
    /// EmptyQueryResponse (I)
    empty_query = 'I',
    /// ErrorResponse (E)
    error_response = 'E',
    /// NoData (n)
    no_data = 'n',
    /// NoticeResponse (N)
    notice = 'N',
    /// NotificationResponse (A)
    notification = 'A',
    /// ParameterDescription (t)
    parameter_description = 't',
    /// ParameterStatus (S)
    parameter_status = 'S',
    /// ParseComplete (1)
    parse_complete = '1',
    /// PortalSuspended (s)
    portal_suspended = 's',
    /// ReadyForQuery (Z)
    ready_for_query = 'Z',
    /// RowDescription (T)
    row_description = 'T',
    _,
};

/// Authentication types
pub const AuthType = enum(u32) {
    ok = 0,
    kerberos_v5 = 2,
    cleartext_password = 3,
    md5_password = 5,
    scm_credential = 6,
    gss = 7,
    gss_continue = 8,
    sspi = 9,
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,
    _,
};

/// Transaction status indicators
pub const TransactionStatus = enum(u8) {
    /// Idle (not in transaction)
    idle = 'I',
    /// In a transaction block
    in_transaction = 'T',
    /// In a failed transaction block
    failed = 'E',
};

/// Error/Notice field codes
pub const ErrorField = enum(u8) {
    severity = 'S',
    severity_nonlocalized = 'V',
    code = 'C',
    message = 'M',
    detail = 'D',
    hint = 'H',
    position = 'P',
    internal_position = 'p',
    internal_query = 'q',
    where = 'W',
    schema_name = 's',
    table_name = 't',
    column_name = 'c',
    data_type_name = 'd',
    constraint_name = 'n',
    file = 'F',
    line = 'L',
    routine = 'R',
    _,
};

/// Parsed field description from RowDescription
pub const FieldDescription = struct {
    name: []const u8,
    table_oid: u32,
    column_index: u16,
    type_oid: u32,
    type_len: i16,
    type_modifier: i32,
    format_code: u16, // 0 = text, 1 = binary
};

/// Parsed error response
pub const ErrorInfo = struct {
    severity: ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    position: ?[]const u8 = null,
};

// Tests
test "protocol version" {
    try std.testing.expectEqual(@as(u32, 196608), PROTOCOL_VERSION);
}

test "frontend message types" {
    try std.testing.expectEqual(@as(u8, 'Q'), @intFromEnum(FrontendMessage.query));
    try std.testing.expectEqual(@as(u8, 'P'), @intFromEnum(FrontendMessage.parse));
    try std.testing.expectEqual(@as(u8, 'B'), @intFromEnum(FrontendMessage.bind));
}

test "backend message types" {
    try std.testing.expectEqual(@as(u8, 'D'), @intFromEnum(BackendMessage.data_row));
    try std.testing.expectEqual(@as(u8, 'T'), @intFromEnum(BackendMessage.row_description));
    try std.testing.expectEqual(@as(u8, 'Z'), @intFromEnum(BackendMessage.ready_for_query));
}
