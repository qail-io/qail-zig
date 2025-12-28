//! QAIL Parser Module
//!
//! Parses .qail schema files for migration and DDL generation.

pub const schema = @import("schema.zig");
pub const differ = @import("differ.zig");
pub const migrations = @import("migrations.zig");

pub const Schema = schema.Schema;
pub const TableDef = schema.TableDef;
pub const ColumnDef = schema.ColumnDef;

pub const MigrationCmd = differ.MigrationCmd;
pub const diffSchemas = differ.diffSchemas;
pub const toSqlStatements = differ.toSqlStatements;

pub const getMigrationTableDdl = migrations.getMigrationTableDdl;
pub const getMigrationTableCmd = migrations.getMigrationTableCmd;
pub const generateVersion = migrations.generateVersion;
pub const computeChecksum = migrations.computeChecksum;

test {
    @import("std").testing.refAllDecls(@This());
}
