// PostgreSQL Driver Module
//
// Async driver for PostgreSQL using the protocol layer.

pub const connection = @import("connection.zig");
pub const async_connection = @import("async_connection.zig");
pub const tls = @import("tls.zig");
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

// Re-export main types
pub const Connection = connection.Connection;
pub const AsyncConnection = async_connection.AsyncConnection;
pub const TlsConnection = tls.TlsConnection;
pub const PgDriver = driver.PgDriver;
pub const PgRow = row.PgRow;
pub const Pipeline = pipeline.Pipeline;
pub const PgPool = pool.PgPool;
pub const PoolConfig = pool.PoolConfig;
pub const PooledConnection = pool.PooledConnection;

// New type exports
pub const CancelKey = cancel.CancelKey;
pub const cancelQuery = cancel.cancelQuery;
pub const Transaction = transaction.Transaction;
pub const PreparedStatement = prepared.PreparedStatement;
pub const Cursor = cursor.Cursor;
pub const IoBuffer = io.IoBuffer;
pub const WriteBuffer = io.WriteBuffer;
pub const StatementCache = query.StatementCache;

// COPY protocol functions
pub const copyIn = copy.copyIn;
pub const copyInRaw = copy.copyInRaw;
pub const copyExport = copy.copyExport;

test {
    @import("std").testing.refAllDecls(@This());
}
