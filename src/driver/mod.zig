//! PostgreSQL Driver Module
//!
//! Async driver for PostgreSQL using the protocol layer.

pub const connection = @import("connection.zig");
pub const async_connection = @import("async_connection.zig");
pub const tls = @import("tls.zig");
pub const driver = @import("driver.zig");
pub const row = @import("row.zig");
pub const pipeline = @import("pipeline.zig");
pub const pool = @import("pool.zig");
pub const copy = @import("copy.zig");

// Re-export main types
pub const Connection = connection.Connection;
pub const AsyncConnection = async_connection.AsyncConnection;
pub const TlsConnection = tls.TlsConnection;
pub const PgDriver = driver.PgDriver;
pub const PgRow = row.PgRow;
pub const Pipeline = pipeline.Pipeline;
pub const PreparedStatement = pipeline.PreparedStatement;
pub const PgPool = pool.PgPool;
pub const PoolConfig = pool.PoolConfig;
pub const PooledConnection = pool.PooledConnection;

// COPY protocol functions
pub const copyIn = copy.copyIn;
pub const copyInRaw = copy.copyInRaw;
pub const copyExport = copy.copyExport;

test {
    @import("std").testing.refAllDecls(@This());
}
