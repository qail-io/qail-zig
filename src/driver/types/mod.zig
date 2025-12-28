// PostgreSQL Types Module
//
// Re-exports all PostgreSQL type definitions.

pub const uuid = @import("uuid.zig");
pub const inet = @import("inet.zig");
pub const numeric = @import("numeric.zig");
pub const timestamp = @import("timestamp.zig");
pub const json = @import("json.zig");
pub const array = @import("array.zig");
pub const macaddr = @import("macaddr.zig");

// Re-export main types
pub const Uuid = uuid.Uuid;
pub const Cidr = inet.Cidr;
pub const Family = inet.Family;
pub const Numeric = numeric.Numeric;
pub const Sign = numeric.Sign;
pub const Timestamp = timestamp.Timestamp;
pub const ArrayIterator = array.ArrayIterator;
pub const MacAddr = macaddr.MacAddr;
pub const MacAddr8 = macaddr.MacAddr8;

// JSON helpers
pub const parseJson = json.parseJson;
pub const parseJsonb = json.parseJsonb;

// Constants
pub const PG_EPOCH_OFFSET = timestamp.PG_EPOCH_OFFSET;

test {
    @import("std").testing.refAllDecls(@This());
}
