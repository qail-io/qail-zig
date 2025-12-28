//! QAIL Parser Module
//!
//! Parses .qail schema files and QAIL text syntax.

pub const schema = @import("schema.zig");
pub const differ = @import("differ.zig");
pub const migrations = @import("migrations.zig");
pub const grammar = @import("grammar/mod.zig");

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

/// Parse QAIL text syntax into QailCmd AST
pub const parse = grammar.parse;
pub const parseRoot = grammar.parseRoot;

test {
    @import("std").testing.refAllDecls(@This());
}
