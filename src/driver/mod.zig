const builtin = @import("builtin");

// PostgreSQL Driver Module
//
// Async driver for PostgreSQL using the protocol layer.

pub const connection = @import("connection.zig");
pub const async_connection = if (builtin.os.tag == .windows)
    @import("async_connection_stub.zig")
else
    @import("async_connection.zig");
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
pub const extended_flow = @import("extended_flow.zig");
pub const kerberos_preflight = @import("kerberos_preflight.zig");
pub const kerberos_provider = @import("kerberos_provider.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
