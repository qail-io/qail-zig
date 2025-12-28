//! QAIL Parser Module
//!
//! Parses .qail schema files for migration and DDL generation.

pub const schema = @import("schema.zig");

pub const Schema = schema.Schema;
pub const TableDef = schema.TableDef;
pub const ColumnDef = schema.ColumnDef;

test {
    @import("std").testing.refAllDecls(@This());
}
