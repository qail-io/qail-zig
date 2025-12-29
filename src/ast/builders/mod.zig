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

// Convenient direct imports - Columns
pub const col = columns.col;
pub const star = columns.star;
pub const param = columns.param;

// Conditions - Comparison
pub const eq = conditions.eq;
pub const ne = conditions.ne;
pub const gt = conditions.gt;
pub const gte = conditions.gte;
pub const lt = conditions.lt;
pub const lte = conditions.lte;

// Conditions - Pattern Matching
pub const like = conditions.like;
pub const notLike = conditions.notLike;
pub const ilike = conditions.ilike;
pub const notIlike = conditions.notIlike;
pub const regex = conditions.regex;
pub const regexI = conditions.regexI;
pub const similarTo = conditions.similarTo;

// Conditions - Range & Sets
pub const between = conditions.between;
pub const notBetween = conditions.notBetween;
pub const isIn = conditions.isIn;
pub const notIn = conditions.notIn;

// Conditions - Null
pub const isNull = conditions.isNull;
pub const isNotNull = conditions.isNotNull;

// Conditions - Array/JSON
pub const contains = conditions.contains;
pub const overlaps = conditions.overlaps;
pub const keyExists = conditions.keyExists;

// Aggregates
pub const count = aggregates.count;
pub const countDistinct = functions.countDistinct;
pub const sum = aggregates.sum;
pub const avg = aggregates.avg;
pub const min = aggregates.min;
pub const max = aggregates.max;
pub const arrayAgg = functions.arrayAgg;
pub const stringAgg = functions.stringAgg;
pub const jsonAgg = functions.jsonAgg;

// Functions
pub const coalesceSlice = functions.coalesceSlice;
pub const nullif = functions.nullif;
pub const now = functions.now;
pub const nowMinus = functions.nowMinus;
pub const nowPlus = functions.nowPlus;
pub const text = functions.text;
pub const caseWhen = functions.caseWhen;
pub const funcCall = functions.funcCall;

test "builder imports" {
    _ = columns;
    _ = conditions;
    _ = aggregates;
    _ = functions;
}
