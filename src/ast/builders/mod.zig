//! Ergonomic Builder Functions for QAIL AST
//!
//! Port of qail.rs builder patterns.
//! Usage: `const b = @import("builders/mod.zig");`
//!
//! Example:
//! ```zig
//! const query = QailCmd.get("users")
//!     .column(b.col("id"))
//!     .column(b.count("*"))
//!     .filter(b.eq("status", .{ .string = "active" }));
//! ```

// Re-export all builders
pub const columns = @import("columns.zig");
pub const conditions = @import("conditions.zig");
pub const aggregates = @import("aggregates.zig");
pub const functions = @import("functions.zig");

// Convenient direct imports
pub const col = columns.col;
pub const star = columns.star;
pub const param = columns.param;

pub const eq = conditions.eq;
pub const ne = conditions.ne;
pub const gt = conditions.gt;
pub const gte = conditions.gte;
pub const lt = conditions.lt;
pub const lte = conditions.lte;
pub const isIn = conditions.isIn;
pub const isNull = conditions.isNull;
pub const isNotNull = conditions.isNotNull;
pub const like = conditions.like;

pub const count = aggregates.count;
pub const countDistinct = aggregates.countDistinct;
pub const sum = aggregates.sum;
pub const avg = aggregates.avg;
pub const min = aggregates.min;
pub const max = aggregates.max;

pub const coalesceSlice = functions.coalesceSlice;
pub const nullif = functions.nullif;

test "builder imports" {
    _ = columns;
    _ = conditions;
    _ = aggregates;
    _ = functions;
}
