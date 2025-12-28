//! Codebase analyzer for migration impact detection.
//!
//! Scans source files for QAIL queries and raw SQL to detect
//! breaking changes before migrations are applied.

pub const scanner = @import("scanner.zig");
pub const impact = @import("impact.zig");

// Re-export main types
pub const CodebaseScanner = scanner.CodebaseScanner;
pub const CodeReference = scanner.CodeReference;
pub const QueryType = scanner.QueryType;
pub const MigrationImpact = impact.MigrationImpact;
pub const BreakingChange = impact.BreakingChange;
pub const Warning = impact.Warning;

test {
    _ = scanner;
    _ = impact;
}
