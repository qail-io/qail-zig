//! Type-safe column references and compile-time query validation.
//!
//! Port of qail.rs typed.rs — uses Zig comptime generics instead of
//! Rust traits + PhantomData for compile-time type/policy enforcement.
//!
//! ## Example
//! ```zig
//! const users = struct {
//!     pub const age = TypedColumn(i64, .public).init("users", "age");
//!     pub const email = TypedColumn([]const u8, .public).init("users", "email");
//!     pub const password_hash = TypedColumn([]const u8, .protected).init("users", "password_hash");
//! };
//!
//! // Type-safe condition — comptime-checked value type
//! const cond = typed.typedEq(users.age, @as(i64, 25));
//!
//! // Policy unlock — Protected columns need a capability witness
//! const unlocked = users.password_hash.unlock(.admin);
//! ```

const std = @import("std");
const ast = @import("../mod.zig");

const Value = ast.Value;
const Expr = ast.Expr;
const Operator = ast.Operator;
const WhereClause = ast.WhereClause;

// =============================================================================
// Access Policies (Compile-Time Data Governance)
// =============================================================================

/// Data access policy levels.
///
/// - `public`: Accessible by default.
/// - `protected`: Requires `admin` or `system` capability.
/// - `restricted`: Requires `system` capability only.
pub const Policy = enum {
    public,
    protected,
    restricted,
};

/// Capability levels — compile-time authorization witnesses.
///
/// Higher capabilities subsume lower ones:
/// `system` > `admin` > `none`.
pub const Capability = enum {
    none,
    admin,
    system,

    /// Check if this capability unlocks the given policy.
    pub fn allowsPolicy(self: Capability, policy: Policy) bool {
        return switch (policy) {
            .public => true,
            .protected => self == .admin or self == .system,
            .restricted => self == .system,
        };
    }
};

// =============================================================================
// TypedColumn — Compile-Time Column Descriptor
// =============================================================================

/// A compile-time typed column reference.
///
/// `T` is the Zig type marker (i64, []const u8, bool, etc.).
/// `P` is the access policy (default: .public).
///
/// Uses comptime for all checks — zero runtime cost.
pub fn TypedColumn(comptime T: type, comptime policy: Policy) type {
    return struct {
        table: []const u8,
        name: []const u8,

        const Self = @This();
        pub const ValueType = T;
        pub const access_policy = policy;

        /// Create a typed column reference.
        pub fn init(table: []const u8, name: []const u8) Self {
            return .{ .table = table, .name = name };
        }

        /// Get the column name as an AST Expr.
        pub fn toExpr(self: Self) Expr {
            return Expr.col(self.name);
        }

        /// Get qualified "table.column" name.
        pub fn qualified(self: Self) struct { table: []const u8, column: []const u8 } {
            return .{ .table = self.table, .column = self.name };
        }

        /// Unlock a policy-protected column with a capability witness.
        ///
        /// Compile-time check: the capability must be sufficient for the policy.
        ///
        /// ```zig
        /// const pwd_hash = TypedColumn([]const u8, .protected).init("users", "password_hash");
        /// const unlocked = pwd_hash.unlock(.admin);  // OK — admin unlocks protected
        /// // pwd_hash.unlock(.none);  // COMPILE ERROR — none cannot unlock protected
        /// ```
        pub fn unlock(self: Self, comptime cap: Capability) TypedColumn(T, .public) {
            comptime {
                if (!cap.allowsPolicy(policy)) {
                    @compileError(
                        "Capability ." ++ @tagName(cap) ++
                            " is insufficient for policy ." ++ @tagName(policy),
                    );
                }
            }
            return TypedColumn(T, .public).init(self.table, self.name);
        }

        /// Create a type-safe WHERE clause — value type is verified at comptime.
        pub fn eql(self: Self, value: T) WhereClause {
            comptime {
                if (access_policy != .public) {
                    @compileError("Column has policy ." ++ @tagName(access_policy) ++
                        " — unlock it first with .unlock(capability)");
                }
            }
            return .{
                .condition = .{
                    .column = self.name,
                    .op = .eq,
                    .value = valueFromTyped(T, value),
                },
            };
        }

        /// Create a not-equal condition.
        pub fn neq(self: Self, value: T) WhereClause {
            comptime {
                if (access_policy != .public) {
                    @compileError("Column has policy ." ++ @tagName(access_policy) ++
                        " — unlock it first");
                }
            }
            return .{
                .condition = .{
                    .column = self.name,
                    .op = .ne,
                    .value = valueFromTyped(T, value),
                },
            };
        }

        /// Create a condition with custom operator.
        pub fn cond(self: Self, op: Operator, value: T) WhereClause {
            comptime {
                if (access_policy != .public) {
                    @compileError("Column has policy ." ++ @tagName(access_policy) ++
                        " — unlock it first");
                }
            }
            return .{
                .condition = .{
                    .column = self.name,
                    .op = op,
                    .value = valueFromTyped(T, value),
                },
            };
        }

        /// Create a type-safe assignment for INSERT/UPDATE.
        pub fn assign(self: Self, value: T) ast.Assignment {
            return .{
                .column = self.name,
                .value = valueFromTyped(T, value),
            };
        }
    };
}

/// Convert a typed Zig value to an AST Value.
fn valueFromTyped(comptime T: type, value: T) Value {
    if (T == i64) {
        return .{ .int = value };
    } else if (T == i32) {
        return .{ .int = @as(i64, @intCast(value)) };
    } else if (T == f64) {
        return .{ .float = value };
    } else if (T == f32) {
        return .{ .float = @as(f64, @floatCast(value)) };
    } else if (T == bool) {
        return .{ .bool = value };
    } else if (T == []const u8) {
        return .{ .string = value };
    } else {
        @compileError("Unsupported typed value: " ++ @typeName(T));
    }
}

// =============================================================================
// Test Schema (for testing)
// =============================================================================
const test_schema = struct {
    pub const age = TypedColumn(i64, .public).init("users", "age");
    pub const name = TypedColumn([]const u8, .public).init("users", "name");
    pub const email = TypedColumn([]const u8, .public).init("users", "email");
    pub const active = TypedColumn(bool, .public).init("users", "active");
    pub const rating = TypedColumn(f64, .public).init("products", "rating");
    pub const password_hash = TypedColumn([]const u8, .protected).init("users", "password_hash");
    pub const secret_key = TypedColumn([]const u8, .restricted).init("config", "secret_key");
};

// =============================================================================
// Tests
// =============================================================================

test "typed column basic" {
    try std.testing.expectEqualStrings("age", test_schema.age.name);
    try std.testing.expectEqualStrings("users", test_schema.age.table);
    const q = test_schema.age.qualified();
    try std.testing.expectEqualStrings("users", q.table);
    try std.testing.expectEqualStrings("age", q.column);
}

test "typed column toExpr" {
    const expr = test_schema.name.toExpr();
    try std.testing.expectEqualStrings("name", expr.named);
}

test "typed eq creates where clause" {
    const clause = test_schema.age.eql(25);
    try std.testing.expectEqualStrings("age", clause.condition.column);
    try std.testing.expectEqual(Operator.eq, clause.condition.op);
    try std.testing.expectEqual(@as(i64, 25), clause.condition.value.int);
}

test "typed ne creates where clause" {
    const clause = test_schema.name.neq("inactive");
    try std.testing.expectEqual(Operator.ne, clause.condition.op);
    try std.testing.expectEqualStrings("inactive", clause.condition.value.string);
}

test "typed assign creates assignment" {
    const a = test_schema.email.assign("alice@example.com");
    try std.testing.expectEqualStrings("email", a.column);
    try std.testing.expectEqualStrings("alice@example.com", a.value.string);
}

test "typed bool column" {
    const clause = test_schema.active.eql(true);
    try std.testing.expectEqual(true, clause.condition.value.bool);
}

test "typed float column" {
    const clause = test_schema.rating.cond(.gt, 4.5);
    try std.testing.expectEqual(@as(f64, 4.5), clause.condition.value.float);
}

test "policy allows checks" {
    // Public is allowed by all capabilities
    try std.testing.expect(Capability.none.allowsPolicy(.public));
    try std.testing.expect(Capability.admin.allowsPolicy(.public));
    try std.testing.expect(Capability.system.allowsPolicy(.public));

    // Protected requires admin or system
    try std.testing.expect(!Capability.none.allowsPolicy(.protected));
    try std.testing.expect(Capability.admin.allowsPolicy(.protected));
    try std.testing.expect(Capability.system.allowsPolicy(.protected));

    // Restricted requires system only
    try std.testing.expect(!Capability.none.allowsPolicy(.restricted));
    try std.testing.expect(!Capability.admin.allowsPolicy(.restricted));
    try std.testing.expect(Capability.system.allowsPolicy(.restricted));
}

test "unlock protected column with admin" {
    const unlocked = test_schema.password_hash.unlock(.admin);
    try std.testing.expectEqualStrings("password_hash", unlocked.name);
    try std.testing.expectEqual(Policy.public, @TypeOf(unlocked).access_policy);
}

test "unlock restricted column with system" {
    const unlocked = test_schema.secret_key.unlock(.system);
    const clause = unlocked.eql("abc123");
    try std.testing.expectEqualStrings("secret_key", clause.condition.column);
}

test "typed integration with QailCmd" {
    // Build typed conditions, then use in QailCmd
    const clauses = [_]WhereClause{
        test_schema.age.eql(25),
        test_schema.name.neq("admin"),
    };

    const assigns = [_]ast.Assignment{
        test_schema.age.assign(30),
    };

    const cmd = ast.QailCmd.set("users").values(&assigns).where(&clauses);
    try std.testing.expectEqualStrings("users", cmd.table);
}
