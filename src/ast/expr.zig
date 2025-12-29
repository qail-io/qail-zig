// QAIL Expressions - Column references, functions, and computed values
//
// Port of Rust qail-core/src/ast/expr.rs

const std = @import("std");
const operators = @import("operators.zig");
const values = @import("values.zig");

const Operator = operators.Operator;
const BinaryOp = operators.BinaryOp;
const AggregateFunc = operators.AggregateFunc;
const Value = values.Value;

/// Expression node - represents any value/column in a query
pub const Expr = union(enum) {
    /// All columns (*)
    star,

    /// A named column reference
    named: []const u8,

    /// An aliased expression (expr AS alias)
    aliased: struct {
        name: []const u8,
        alias: []const u8,
    },

    /// Aggregate function: COUNT(col), SUM(col), etc.
    aggregate: struct {
        func: AggregateFunc,
        column: []const u8,
        distinct: bool = false,
        alias: ?[]const u8 = null,
    },

    /// Literal value
    literal: Value,

    /// Binary expression (left op right)
    binary: struct {
        left: *const Expr,
        op: BinaryOp,
        right: *const Expr,
        alias: ?[]const u8 = null,
    },

    /// JSON accessor (data->>'key' or data->'key')
    json_access: struct {
        column: []const u8,
        path: []const JsonPathSegment,
        alias: ?[]const u8 = null,
    },

    /// Function call
    func_call: struct {
        name: []const u8,
        args: []const Expr,
        alias: ?[]const u8 = null,
    },

    /// CASE expression
    case_expr: struct {
        when_clauses: []const WhenClause,
        else_value: ?*const Expr = null,
        alias: ?[]const u8 = null,
    },

    /// Subquery
    subquery: struct {
        sql: []const u8,
        alias: ?[]const u8 = null,
    },

    /// Coalesce (COALESCE(expr, default))
    coalesce: struct {
        exprs: []const Expr,
        alias: ?[]const u8 = null,
    },

    /// Cast expression (expr::type)
    cast: struct {
        expr: *const Expr,
        target_type: []const u8,
        alias: ?[]const u8 = null,
    },

    /// Column definition for DDL (name TYPE [constraints])
    /// Matches qail.rs Expr::Def structure
    column_def: struct {
        name: []const u8,
        data_type: []const u8,
        constraints: []const Constraint = &.{},
        // Individual constraint fields for AST-native DDL
        is_primary_key: bool = false,
        is_unique: bool = false,
        is_not_null: bool = false,
        default_value: ?[]const u8 = null,
        references: ?[]const u8 = null,
    },

    /// Window function (name OVER (PARTITION BY ... ORDER BY ...))
    /// Matches qail.rs Expr::Window
    window: struct {
        name: []const u8,
        func: []const u8,
        partition: []const []const u8 = &.{},
        order: []const OrderByExpr = &.{},
        frame: ?WindowFrame = null,
        alias: ?[]const u8 = null,
    },

    /// Column modification for ALTER (+col, -col)
    /// Matches qail.rs Expr::Mod
    col_mod: struct {
        kind: ModKind,
        col: *const Expr,
    },

    /// Special SQL function with keyword args (SUBSTRING, EXTRACT, TRIM)
    /// e.g., SUBSTRING(expr FROM pos FOR len), EXTRACT(YEAR FROM date)
    /// Matches qail.rs Expr::SpecialFunction
    special_func: struct {
        name: []const u8,
        /// Arguments as (optional_keyword, expr) pairs
        args: []const SpecialFuncArg,
        alias: ?[]const u8 = null,
    },

    // ==================== Builder Methods ====================

    /// Create a star expression (*)
    pub fn all() Expr {
        return .star;
    }

    /// Create a named column reference
    pub fn col(name: []const u8) Expr {
        return .{ .named = name };
    }

    /// Create an aliased column
    pub fn colAs(name: []const u8, alias: []const u8) Expr {
        return .{ .aliased = .{ .name = name, .alias = alias } };
    }

    /// Create a COUNT(*) aggregate
    pub fn count() Expr {
        return .{ .aggregate = .{ .func = .count, .column = "*" } };
    }

    /// Create a COUNT(column) aggregate
    pub fn countCol(column: []const u8) Expr {
        return .{ .aggregate = .{ .func = .count, .column = column } };
    }

    /// Create a SUM(column) aggregate
    pub fn sum(column: []const u8) Expr {
        return .{ .aggregate = .{ .func = .sum, .column = column } };
    }

    /// Create an AVG(column) aggregate
    pub fn avg(column: []const u8) Expr {
        return .{ .aggregate = .{ .func = .avg, .column = column } };
    }

    /// Create a MIN(column) aggregate
    pub fn min(column: []const u8) Expr {
        return .{ .aggregate = .{ .func = .min, .column = column } };
    }

    /// Create a MAX(column) aggregate
    pub fn max(column: []const u8) Expr {
        return .{ .aggregate = .{ .func = .max, .column = column } };
    }

    /// Create a literal value
    pub fn val(v: Value) Expr {
        return .{ .literal = v };
    }

    /// Create an integer literal
    pub fn int(i: i64) Expr {
        return .{ .literal = Value.fromInt(i) };
    }

    /// Create a string literal
    pub fn str(s: []const u8) Expr {
        return .{ .literal = Value.fromString(s) };
    }

    /// Create a parameter placeholder
    pub fn param(n: u16) Expr {
        return .{ .literal = .{ .param = n } };
    }

    /// Create a column definition for DDL
    pub fn def(name: []const u8, data_type: []const u8) Expr {
        return .{ .column_def = .{ .name = name, .data_type = data_type } };
    }

    /// Create a column definition with constraints
    pub fn defWithConstraints(name: []const u8, data_type: []const u8, constraints: []const Constraint) Expr {
        return .{ .column_def = .{ .name = name, .data_type = data_type, .constraints = constraints } };
    }

    // ==================== Fluent Methods (match Rust col().upper() API) ====================

    /// UPPER(expr) - convert to uppercase
    pub fn upper(self: Expr) Expr {
        return .{ .func_call = .{ .name = "UPPER", .args = &[_]Expr{self} } };
    }

    /// LOWER(expr) - convert to lowercase
    pub fn lower(self: Expr) Expr {
        return .{ .func_call = .{ .name = "LOWER", .args = &[_]Expr{self} } };
    }

    /// TRIM(expr) - remove leading/trailing whitespace
    pub fn trim(self: Expr) Expr {
        return .{ .func_call = .{ .name = "TRIM", .args = &[_]Expr{self} } };
    }

    /// LENGTH(expr) - get string length
    pub fn length(self: Expr) Expr {
        return .{ .func_call = .{ .name = "LENGTH", .args = &[_]Expr{self} } };
    }

    /// ABS(expr) - absolute value
    pub fn absVal(self: Expr) Expr {
        return .{ .func_call = .{ .name = "ABS", .args = &[_]Expr{self} } };
    }

    /// CAST expr AS type (expr::type in Postgres)
    pub fn castTo(self: *const Expr, target_type: []const u8) Expr {
        return .{ .cast = .{ .expr = self, .target_type = target_type } };
    }

    /// Add alias to expression (AS alias)
    pub fn withAlias(self: Expr, alias_name: []const u8) Expr {
        return switch (self) {
            .named => |n| .{ .aliased = .{ .name = n, .alias = alias_name } },
            .aggregate => |a| .{ .aggregate = .{ .func = a.func, .column = a.column, .distinct = a.distinct, .alias = alias_name } },
            .func_call => |f| .{ .func_call = .{ .name = f.name, .args = f.args, .alias = alias_name } },
            .coalesce => |c| .{ .coalesce = .{ .exprs = c.exprs, .alias = alias_name } },
            .cast => |c| .{ .cast = .{ .expr = c.expr, .target_type = c.target_type, .alias = alias_name } },
            .case_expr => |c| .{ .case_expr = .{ .when_clauses = c.when_clauses, .else_value = c.else_value, .alias = alias_name } },
            else => self, // Can't alias other types
        };
    }

    /// COALESCE(expr, default) - return first non-null value
    pub fn orDefault(self: *const Expr, default_expr: Expr) Expr {
        return .{ .coalesce = .{ .exprs = &[_]Expr{ self.*, default_expr } } };
    }

    /// JSON accessor (data->>'key')
    pub fn jsonText(self: Expr, key: []const u8) Expr {
        const col_name = switch (self) {
            .named => |n| n,
            else => "",
        };
        return .{ .json_access = .{ .column = col_name, .path = &[_]JsonPathSegment{.{ .key = key, .as_text = true }} } };
    }
};

/// DDL constraint types (matches qail.rs Constraint enum)
pub const Constraint = union(enum) {
    /// PRIMARY KEY
    primary_key,
    /// NULL allowed (?)
    nullable,
    /// UNIQUE
    unique,
    /// NOT NULL (explicit)
    not_null,
    /// DEFAULT value
    default: []const u8,
    /// CHECK constraint with allowed values
    check: []const []const u8,
    /// REFERENCES table(column)
    references: []const u8,
    /// COMMENT ON COLUMN
    comment: []const u8,

    /// Check if constraint list contains primary_key
    pub fn hasPrimaryKey(constraints: []const Constraint) bool {
        for (constraints) |c| {
            if (c == .primary_key) return true;
        }
        return false;
    }

    /// Check if constraint list contains nullable
    pub fn hasNullable(constraints: []const Constraint) bool {
        for (constraints) |c| {
            if (c == .nullable) return true;
        }
        return false;
    }

    /// Check if constraint list contains unique
    pub fn hasUnique(constraints: []const Constraint) bool {
        for (constraints) |c| {
            if (c == .unique) return true;
        }
        return false;
    }

    /// Get default value if present
    pub fn getDefault(constraints: []const Constraint) ?[]const u8 {
        for (constraints) |c| {
            if (c == .default) return c.default;
        }
        return null;
    }
};

/// JSON path segment for JSON accessor expressions
pub const JsonPathSegment = struct {
    key: []const u8,
    as_text: bool = false, // true for ->> (text), false for -> (jsonb)
};

/// WHEN clause for CASE expressions
pub const WhenClause = struct {
    condition: Condition,
    result: Expr,
};

/// Order by expression for window functions
pub const OrderByExpr = struct {
    column: []const u8,
    direction: SortOrder = .asc,
};

/// Window frame definition (ROWS/RANGE BETWEEN...)
pub const WindowFrame = struct {
    kind: FrameKind = .rows,
    start_bound: FrameBound = .{ .unbounded_preceding = {} },
    end_bound: ?FrameBound = null,
};

/// Frame kind (ROWS or RANGE)
pub const FrameKind = enum {
    rows,
    range,
};

/// Frame bound
pub const FrameBound = union(enum) {
    unbounded_preceding,
    unbounded_following,
    current_row,
    preceding: i64,
    following: i64,
};

/// Column modification kind for ALTER
pub const ModKind = enum {
    add,
    drop,
};

/// Special function argument with optional keyword
pub const SpecialFuncArg = struct {
    keyword: ?[]const u8 = null, // e.g., "FROM", "FOR"
    expr: *const Expr,
};

// Re-import SortOrder
const SortOrder = @import("operators.zig").SortOrder;

/// A filter condition (expr op value)
pub const Condition = struct {
    /// Left side (column or expression)
    left: Expr = .star,
    /// Column name shorthand (used if left is star)
    column: []const u8 = "",
    /// Comparison operator
    op: Operator = .eq,
    /// Value to compare
    value: Value = .null,
    /// Whether this is an array unnest operation
    is_array_unnest: bool = false,

    /// Create a simple column condition
    pub fn init(col: []const u8, op_: Operator, val: Value) Condition {
        return .{ .column = col, .op = op_, .value = val };
    }
};

// Tests
test "expr col creates named" {
    const e = Expr.col("id");
    try std.testing.expectEqualStrings("id", e.named);
}

test "expr count creates aggregate" {
    const e = Expr.count();
    try std.testing.expectEqual(AggregateFunc.count, e.aggregate.func);
    try std.testing.expectEqualStrings("*", e.aggregate.column);
}

test "expr sum creates aggregate" {
    const e = Expr.sum("amount");
    try std.testing.expectEqual(AggregateFunc.sum, e.aggregate.func);
    try std.testing.expectEqualStrings("amount", e.aggregate.column);
}

test "expr int creates literal" {
    const e = Expr.int(42);
    try std.testing.expectEqual(@as(i64, 42), e.literal.int);
}

test "expr param creates placeholder" {
    const e = Expr.param(1);
    try std.testing.expectEqual(@as(u16, 1), e.literal.param);
}
