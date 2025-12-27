//! QAIL Operators - Comparison and Binary operators
//!
//! Port of Rust qail-core/src/ast/operators.rs

const std = @import("std");

/// Comparison operators for WHERE clauses
pub const Operator = enum {
    /// Equal (=)
    eq,
    /// Not equal (<> or !=)
    ne,
    /// Greater than (>)
    gt,
    /// Greater than or equal (>=)
    gte,
    /// Less than (<)
    lt,
    /// Less than or equal (<=)
    lte,
    /// LIKE pattern match
    like,
    /// NOT LIKE pattern match
    not_like,
    /// ILIKE (case-insensitive LIKE)
    ilike,
    /// IS NULL
    is_null,
    /// IS NOT NULL
    is_not_null,
    /// IN (list)
    in,
    /// NOT IN (list)
    not_in,
    /// BETWEEN min AND max
    between,
    /// Array contains (@>)
    contains,
    /// Array is contained by (<@)
    contained_by,
    /// Array overlap (&&)
    overlaps,
    /// JSON path exists (@?)
    json_exists,
    /// SIMILAR TO
    similar_to,
    /// Regular expression match (~)
    regex,
    /// Case-insensitive regex (~*)
    regex_i,

    pub fn toSql(self: Operator) []const u8 {
        return switch (self) {
            .eq => "=",
            .ne => "<>",
            .gt => ">",
            .gte => ">=",
            .lt => "<",
            .lte => "<=",
            .like => "LIKE",
            .not_like => "NOT LIKE",
            .ilike => "ILIKE",
            .is_null => "IS NULL",
            .is_not_null => "IS NOT NULL",
            .in => "IN",
            .not_in => "NOT IN",
            .between => "BETWEEN",
            .contains => "@>",
            .contained_by => "<@",
            .overlaps => "&&",
            .json_exists => "@?",
            .similar_to => "SIMILAR TO",
            .regex => "~",
            .regex_i => "~*",
        };
    }
};

/// Binary operators for arithmetic/string expressions
pub const BinaryOp = enum {
    /// String concatenation (||)
    concat,
    /// Addition (+)
    add,
    /// Subtraction (-)
    sub,
    /// Multiplication (*)
    mul,
    /// Division (/)
    div,
    /// Modulo (%)
    rem,

    pub fn toSql(self: BinaryOp) []const u8 {
        return switch (self) {
            .concat => "||",
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
        };
    }
};

/// Logical operators for combining conditions
pub const LogicalOp = enum {
    @"and",
    @"or",

    pub fn toSql(self: LogicalOp) []const u8 {
        return switch (self) {
            .@"and" => "AND",
            .@"or" => "OR",
        };
    }
};

/// Sort order for ORDER BY
pub const SortOrder = enum {
    asc,
    desc,
    asc_nulls_first,
    asc_nulls_last,
    desc_nulls_first,
    desc_nulls_last,

    pub fn toSql(self: SortOrder) []const u8 {
        return switch (self) {
            .asc => "ASC",
            .desc => "DESC",
            .asc_nulls_first => "ASC NULLS FIRST",
            .asc_nulls_last => "ASC NULLS LAST",
            .desc_nulls_first => "DESC NULLS FIRST",
            .desc_nulls_last => "DESC NULLS LAST",
        };
    }
};

/// Aggregate functions
pub const AggregateFunc = enum {
    count,
    sum,
    avg,
    min,
    max,
    array_agg,
    string_agg,
    json_agg,
    jsonb_agg,
    bool_and,
    bool_or,

    pub fn toSql(self: AggregateFunc) []const u8 {
        return switch (self) {
            .count => "COUNT",
            .sum => "SUM",
            .avg => "AVG",
            .min => "MIN",
            .max => "MAX",
            .array_agg => "ARRAY_AGG",
            .string_agg => "STRING_AGG",
            .json_agg => "JSON_AGG",
            .jsonb_agg => "JSONB_AGG",
            .bool_and => "BOOL_AND",
            .bool_or => "BOOL_OR",
        };
    }
};

// Tests
test "operator to sql" {
    try std.testing.expectEqualStrings("=", Operator.eq.toSql());
    try std.testing.expectEqualStrings(">=", Operator.gte.toSql());
    try std.testing.expectEqualStrings("LIKE", Operator.like.toSql());
}

test "binary op to sql" {
    try std.testing.expectEqualStrings("+", BinaryOp.add.toSql());
    try std.testing.expectEqualStrings("||", BinaryOp.concat.toSql());
}

test "aggregate func to sql" {
    try std.testing.expectEqualStrings("COUNT", AggregateFunc.count.toSql());
    try std.testing.expectEqualStrings("SUM", AggregateFunc.sum.toSql());
}
