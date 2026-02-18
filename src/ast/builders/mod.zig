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
pub const literals = @import("literals.zig");
pub const binary_ops = @import("binary.zig");
pub const cast_mod = @import("cast.zig");
pub const json_mod = @import("json.zig");
pub const time_mod = @import("time.zig");
pub const case_when_mod = @import("case_when.zig");
pub const shortcuts = @import("shortcuts.zig");
pub const typed = @import("typed.zig");

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
pub const now = time_mod.now;
pub const nowMinus = time_mod.nowMinus;
pub const nowPlus = time_mod.nowPlus;
pub const text = literals.text;
pub const caseWhen = case_when_mod.caseWhen;
pub const funcCall = functions.funcCall;

// Literals
pub const int = literals.int;
pub const float = literals.float;
pub const boolean = literals.boolean;
pub const null_val = literals.nullVal;

// Binary
pub const binary = binary_ops.binary;
pub const add = binary_ops.add;
pub const sub = binary_ops.sub;
pub const mul = binary_ops.mul;
pub const div = binary_ops.div;
pub const concat_expr = binary_ops.concat;
pub const andExpr = binary_ops.andExpr;
pub const orExpr = binary_ops.orExpr;

// Cast
pub const cast = cast_mod.cast;

// JSON
pub const json = json_mod.json;
pub const jsonObj = json_mod.jsonObj;
pub const jsonPath2 = json_mod.jsonPath2;
pub const jsonPath3 = json_mod.jsonPath3;

// Time
pub const interval = time_mod.interval;

// Shortcuts
pub const isNotNullExpr = shortcuts.isNotNullExpr;
pub const isNullExpr = shortcuts.isNullExpr;
pub const all = shortcuts.all;
pub const inList = shortcuts.inList;

test "builder imports" {
    _ = columns;
    _ = conditions;
    _ = aggregates;
    _ = functions;
    _ = literals;
    _ = binary_ops;
    _ = cast_mod;
    _ = json_mod;
    _ = time_mod;
    _ = case_when_mod;
    _ = shortcuts;
    _ = typed;
}
