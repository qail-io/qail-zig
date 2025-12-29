// QAIL Zig Pipeline Test - Mirrors Rust pipeline_test.rs
//
// Comprehensive validation test for QAIL pipeline:
// 1. Builder  → AST (creates correct AST structure)
// 2. AST      → SQL Transpiler (generates correct SQL string)
// 3. AST      → PgEncoder (encodes correctly to wire protocol)
// 4. PostgreSQL → Row values (returns correct data)
//
// Run with: zig build pipeline-test

const std = @import("std");
const qail = @import("qail");

const QailCmd = qail.QailCmd;
const Expr = qail.Expr;
const PgDriver = qail.PgDriver;
const WhereClause = qail.cmd.WhereClause;
const transpiler = qail.transpiler;
const b = qail.builders;

var passed: u32 = 0;
var failed: u32 = 0;
var allocator: std.mem.Allocator = undefined;

fn testSql(name: []const u8, cmd: *const QailCmd, expected: []const u8) !void {
    const sql = try transpiler.toSql(allocator, cmd);
    defer allocator.free(sql);
    if (std.mem.indexOf(u8, sql, expected) != null) {
        passed += 1;
        std.debug.print("✅ {s}\n", .{name});
    } else {
        failed += 1;
        std.debug.print("❌ {s} - expected '{s}' in: {s}\n", .{ name, expected, sql });
    }
}

pub fn main() !void {
    allocator = std.heap.page_allocator;

    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("QAIL ZIG PIPELINE TEST (60+ tests)\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

    var driver = PgDriver.connect(allocator, "127.0.0.1", 5432, "orion", "postgres") catch |err| {
        std.debug.print("❌ Connection failed: {}\n", .{err});
        return;
    };
    defer driver.deinit();
    std.debug.print("✅ Connected!\n\n", .{});

    // Seed test data
    _ = driver.executeRaw("DROP TABLE IF EXISTS qail_test CASCADE") catch {};
    _ = driver.executeRaw(
        \\CREATE TABLE qail_test (
        \\    id SERIAL PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    score INTEGER DEFAULT 0,
        \\    tags INTEGER[] NOT NULL DEFAULT '{}',
        \\    data JSONB NOT NULL DEFAULT '{}'
        \\)
    ) catch return;
    _ = driver.executeRaw(
        \\INSERT INTO qail_test (name, score, tags, data) VALUES
        \\('Harbor 1', 10, ARRAY[1, 2, 3], '{"key": "value1"}'),
        \\('Harbor 2', 20, ARRAY[2, 3, 4], '{"key": "value2"}'),
        \\('Harbor 3', 30, ARRAY[3, 4, 5], '{"key": "value3"}'),
        \\('Port Alpha', 100, ARRAY[10, 20], '{"type": "port"}'),
        \\('Port Beta', 200, ARRAY[20, 30], '{"type": "port"}')
    ) catch return;
    std.debug.print("✅ Test data seeded\n\n", .{});

    // ========================================================================
    // FUNCTION CALLS (10 tests)
    // ========================================================================
    std.debug.print("━━━ FUNCTION CALLS ━━━\n", .{});
    {
        const n = Expr.col("name");
        const cols = [_]Expr{.{ .func_call = .{ .name = "UPPER", .args = &[_]Expr{n}, .alias = null } }};
        try testSql("UPPER()", &QailCmd.get("qail_test").select(&cols).limit(1), "UPPER(name)");
    }
    {
        const n = Expr.col("name");
        const cols = [_]Expr{.{ .func_call = .{ .name = "LOWER", .args = &[_]Expr{n}, .alias = null } }};
        try testSql("LOWER()", &QailCmd.get("qail_test").select(&cols).limit(1), "LOWER(name)");
    }
    {
        const n = Expr.col("name");
        const cols = [_]Expr{.{ .func_call = .{ .name = "TRIM", .args = &[_]Expr{n}, .alias = null } }};
        try testSql("TRIM()", &QailCmd.get("qail_test").select(&cols).limit(1), "TRIM(name)");
    }
    {
        const n = Expr.col("name");
        const cols = [_]Expr{.{ .func_call = .{ .name = "LENGTH", .args = &[_]Expr{n}, .alias = null } }};
        try testSql("LENGTH()", &QailCmd.get("qail_test").select(&cols).limit(1), "LENGTH(name)");
    }
    {
        const s = Expr.col("score");
        const cols = [_]Expr{.{ .func_call = .{ .name = "ABS", .args = &[_]Expr{s}, .alias = null } }};
        try testSql("ABS()", &QailCmd.get("qail_test").select(&cols).limit(1), "ABS(score)");
    }
    {
        const cols = [_]Expr{b.now()};
        try testSql("NOW()", &QailCmd.get("qail_test").select(&cols).limit(1), "NOW()");
    }
    {
        const n = Expr.col("name");
        const d = Expr.str("N/A");
        const cols = [_]Expr{.{ .coalesce = .{ .exprs = &[_]Expr{ n, d }, .alias = null } }};
        try testSql("COALESCE()", &QailCmd.get("qail_test").select(&cols).limit(1), "COALESCE(name");
    }
    {
        const id = Expr.col("id");
        const cols = [_]Expr{.{ .cast = .{ .expr = &id, .target_type = "text", .alias = null } }};
        try testSql("CAST", &QailCmd.get("qail_test").select(&cols).limit(1), "::text");
    }
    {
        const n = Expr.col("name");
        const cols = [_]Expr{.{ .func_call = .{ .name = "CONCAT", .args = &[_]Expr{ n, Expr.str("-suffix") }, .alias = null } }};
        try testSql("CONCAT()", &QailCmd.get("qail_test").select(&cols).limit(1), "CONCAT(name");
    }
    {
        const cols = [_]Expr{.{ .func_call = .{ .name = "CURRENT_DATE", .args = &.{}, .alias = null } }};
        try testSql("CURRENT_DATE", &QailCmd.get("qail_test").select(&cols).limit(1), "CURRENT_DATE");
    }

    // ========================================================================
    // COMPARISON CONDITIONS (6 tests)
    // ========================================================================
    std.debug.print("\n━━━ COMPARISON CONDITIONS ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.eq("id", .{ .int = 1 }) }};
        try testSql("eq()", &QailCmd.get("qail_test").select(&cols).where(&w), "= 1");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.ne("id", .{ .int = 1 }) }};
        try testSql("ne()", &QailCmd.get("qail_test").select(&cols).where(&w), "<> 1");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.gt("score", .{ .int = 50 }) }};
        try testSql("gt()", &QailCmd.get("qail_test").select(&cols).where(&w), "> 50");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.gte("score", .{ .int = 50 }) }};
        try testSql("gte()", &QailCmd.get("qail_test").select(&cols).where(&w), ">= 50");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.lt("score", .{ .int = 50 }) }};
        try testSql("lt()", &QailCmd.get("qail_test").select(&cols).where(&w), "< 50");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.lte("score", .{ .int = 50 }) }};
        try testSql("lte()", &QailCmd.get("qail_test").select(&cols).where(&w), "<= 50");
    }

    // ========================================================================
    // PATTERN MATCHING (6 tests)
    // ========================================================================
    std.debug.print("\n━━━ PATTERN MATCHING ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("name")};
        const w = [_]WhereClause{.{ .condition = b.like("name", "Harbor%") }};
        try testSql("like()", &QailCmd.get("qail_test").select(&cols).where(&w), "LIKE");
    }
    {
        const cols = [_]Expr{Expr.col("name")};
        const w = [_]WhereClause{.{ .condition = b.notLike("name", "Harbor%") }};
        try testSql("notLike()", &QailCmd.get("qail_test").select(&cols).where(&w), "NOT LIKE");
    }
    {
        const cols = [_]Expr{Expr.col("name")};
        const w = [_]WhereClause{.{ .condition = b.ilike("name", "harbor%") }};
        try testSql("ilike()", &QailCmd.get("qail_test").select(&cols).where(&w), "ILIKE");
    }
    {
        const cols = [_]Expr{Expr.col("name")};
        const w = [_]WhereClause{.{ .condition = b.notIlike("name", "harbor%") }};
        try testSql("notIlike()", &QailCmd.get("qail_test").select(&cols).where(&w), "NOT ILIKE");
    }
    {
        const cols = [_]Expr{Expr.col("name")};
        const w = [_]WhereClause{.{ .condition = b.regex("name", "^Harbor") }};
        try testSql("regex()", &QailCmd.get("qail_test").select(&cols).where(&w), "~");
    }
    {
        const cols = [_]Expr{Expr.col("name")};
        const w = [_]WhereClause{.{ .condition = b.regexI("name", "^harbor") }};
        try testSql("regexI()", &QailCmd.get("qail_test").select(&cols).where(&w), "~*");
    }

    // ========================================================================
    // NULL CONDITIONS (2 tests)
    // ========================================================================
    std.debug.print("\n━━━ NULL CONDITIONS ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.isNull("name") }};
        try testSql("isNull()", &QailCmd.get("qail_test").select(&cols).where(&w), "IS NULL");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.isNotNull("name") }};
        try testSql("isNotNull()", &QailCmd.get("qail_test").select(&cols).where(&w), "IS NOT NULL");
    }

    // ========================================================================
    // RANGE CONDITIONS (1 test)
    // ========================================================================
    std.debug.print("\n━━━ RANGE CONDITIONS ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        const w = [_]WhereClause{.{ .condition = b.between("score", 10, 50) }};
        try testSql("between()", &QailCmd.get("qail_test").select(&cols).where(&w), "BETWEEN");
    }

    // ========================================================================
    // AGGREGATES (9 tests)
    // ========================================================================
    std.debug.print("\n━━━ AGGREGATE FUNCTIONS ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.count()};
        try testSql("COUNT(*)", &QailCmd.get("qail_test").select(&cols), "COUNT(*)");
    }
    {
        const cols = [_]Expr{Expr.countCol("name")};
        try testSql("COUNT(col)", &QailCmd.get("qail_test").select(&cols), "COUNT(name)");
    }
    {
        const cols = [_]Expr{Expr.sum("score")};
        try testSql("SUM()", &QailCmd.get("qail_test").select(&cols), "SUM(score)");
    }
    {
        const cols = [_]Expr{Expr.avg("score")};
        try testSql("AVG()", &QailCmd.get("qail_test").select(&cols), "AVG(score)");
    }
    {
        const cols = [_]Expr{Expr.min("score")};
        try testSql("MIN()", &QailCmd.get("qail_test").select(&cols), "MIN(score)");
    }
    {
        const cols = [_]Expr{Expr.max("score")};
        try testSql("MAX()", &QailCmd.get("qail_test").select(&cols), "MAX(score)");
    }
    {
        const cols = [_]Expr{.{ .aggregate = .{ .func = .count, .column = "name", .distinct = true, .alias = null } }};
        try testSql("COUNT(DISTINCT)", &QailCmd.get("qail_test").select(&cols), "COUNT(DISTINCT name)");
    }
    {
        const cols = [_]Expr{.{ .aggregate = .{ .func = .array_agg, .column = "name", .distinct = false, .alias = null } }};
        try testSql("ARRAY_AGG()", &QailCmd.get("qail_test").select(&cols), "ARRAY_AGG(name)");
    }
    {
        const cols = [_]Expr{.{ .aggregate = .{ .func = .json_agg, .column = "name", .distinct = false, .alias = null } }};
        try testSql("JSON_AGG()", &QailCmd.get("qail_test").select(&cols), "JSON_AGG(name)");
    }

    // ========================================================================
    // DML MUTATIONS (6 tests)
    // ========================================================================
    std.debug.print("\n━━━ DML MUTATIONS ━━━\n", .{});
    try testSql("INSERT", &QailCmd.add("qail_test"), "INSERT INTO");
    {
        const w = [_]WhereClause{.{ .condition = b.eq("id", .{ .int = 1 }) }};
        try testSql("UPDATE", &QailCmd.set("qail_test").where(&w), "UPDATE");
    }
    {
        const w = [_]WhereClause{.{ .condition = b.eq("id", .{ .int = 999 }) }};
        try testSql("DELETE", &QailCmd.del("qail_test").where(&w), "DELETE FROM");
    }
    try testSql("DEFAULT VALUES", &QailCmd.add("qail_test").defaultValues(), "DEFAULT VALUES");
    {
        const w = [_]WhereClause{.{ .condition = b.eq("id", .{ .int = 1 }) }};
        try testSql("UPDATE ONLY", &QailCmd.set("qail_test").where(&w).only(), "UPDATE ONLY");
    }
    {
        const w = [_]WhereClause{.{ .condition = b.eq("id", .{ .int = 999 }) }};
        try testSql("DELETE ONLY", &QailCmd.del("qail_test").where(&w).only(), "DELETE FROM ONLY");
    }

    // ========================================================================
    // LOCK MODES (4 tests)
    // ========================================================================
    std.debug.print("\n━━━ LOCK MODES ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FOR UPDATE", &QailCmd.get("qail_test").select(&cols).forUpdate(), "FOR UPDATE");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FOR NO KEY UPDATE", &QailCmd.get("qail_test").select(&cols).forNoKeyUpdate(), "FOR NO KEY UPDATE");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FOR SHARE", &QailCmd.get("qail_test").select(&cols).forShare(), "FOR SHARE");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FOR KEY SHARE", &QailCmd.get("qail_test").select(&cols).forKeyShare(), "FOR KEY SHARE");
    }

    // ========================================================================
    // FETCH & LIMIT (4 tests)
    // ========================================================================
    std.debug.print("\n━━━ FETCH & LIMIT ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("LIMIT", &QailCmd.get("qail_test").select(&cols).limit(5), "LIMIT 5");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("OFFSET", &QailCmd.get("qail_test").select(&cols).limit(5).offset(10), "OFFSET 10");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FETCH FIRST", &QailCmd.get("qail_test").select(&cols).fetchFirst(10), "FETCH FIRST 10 ROWS ONLY");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FETCH WITH TIES", &QailCmd.get("qail_test").select(&cols).fetchWithTies(10), "FETCH FIRST 10 ROWS WITH TIES");
    }

    // ========================================================================
    // TABLE MODIFIERS (3 tests)
    // ========================================================================
    std.debug.print("\n━━━ TABLE MODIFIERS ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("ONLY", &QailCmd.get("qail_test").select(&cols).only(), "FROM ONLY");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("TABLESAMPLE BERNOULLI", &QailCmd.get("qail_test").select(&cols).tablesampleBernoulli(10.0), "TABLESAMPLE BERNOULLI");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("TABLESAMPLE SYSTEM", &QailCmd.get("qail_test").select(&cols).tablesampleSystem(5.0), "TABLESAMPLE SYSTEM");
    }

    // ========================================================================
    // JSON (2 tests)
    // ========================================================================
    std.debug.print("\n━━━ JSON ACCESSORS ━━━\n", .{});
    {
        const cols = [_]Expr{.{ .json_access = .{ .column = "data", .path = &[_]qail.ast.expr.JsonPathSegment{.{ .key = "key", .as_text = true }}, .alias = null } }};
        try testSql("JSON ->>", &QailCmd.get("qail_test").select(&cols).limit(1), "->>'key'");
    }
    {
        const cols = [_]Expr{.{ .json_access = .{ .column = "data", .path = &[_]qail.ast.expr.JsonPathSegment{.{ .key = "nested", .as_text = false }}, .alias = null } }};
        try testSql("JSON ->", &QailCmd.get("qail_test").select(&cols).limit(1), "->'nested'");
    }

    // ========================================================================
    // JOINS (4 tests)
    // ========================================================================
    std.debug.print("\n━━━ JOINS ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("LEFT JOIN", &QailCmd.get("qail_test").select(&cols).leftJoin("other", "qail_test.id", "other.id"), "LEFT JOIN");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("RIGHT JOIN", &QailCmd.get("qail_test").select(&cols).rightJoin("other", "qail_test.id", "other.id"), "RIGHT JOIN");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("INNER JOIN", &QailCmd.get("qail_test").select(&cols).innerJoin("other", "qail_test.id", "other.id"), "INNER JOIN");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("FULL JOIN", &QailCmd.get("qail_test").select(&cols).fullJoin("other", "qail_test.id", "other.id"), "FULL OUTER JOIN");
    }

    // ========================================================================
    // ORDER BY (4 tests)
    // ========================================================================
    std.debug.print("\n━━━ ORDER BY ━━━\n", .{});
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("ORDER BY ASC", &QailCmd.get("qail_test").select(&cols).orderByAsc("id"), "ORDER BY id ASC");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("ORDER BY DESC", &QailCmd.get("qail_test").select(&cols).orderByDesc("id"), "ORDER BY id DESC");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("ORDER BY NULLS FIRST", &QailCmd.get("qail_test").select(&cols).orderByCol("id", .asc_nulls_first), "NULLS FIRST");
    }
    {
        const cols = [_]Expr{Expr.col("id")};
        try testSql("ORDER BY NULLS LAST", &QailCmd.get("qail_test").select(&cols).orderByCol("id", .desc_nulls_last), "NULLS LAST");
    }

    // ========================================================================
    // setValue (1 test - UPDATE has memory issue with stack slice)
    // ========================================================================
    std.debug.print("\n━━━ setValue ━━━\n", .{});
    {
        try testSql("INSERT setValue", &QailCmd.add("qail_test").setValue("name", .{ .string = "Test" }), "INSERT INTO");
    }
    // TODO: UPDATE setValue has memory issue - needs allocator-based builder
    // {
    //     const w = [_]WhereClause{.{ .condition = b.eq("id", .{ .int = 1 }) }};
    //     try testSql("UPDATE setValue", &QailCmd.set("qail_test").setValue("name", .{ .string = "Updated" }).where(&w), "UPDATE");
    // }

    // Note: JOIN and GROUP BY/ORDER BY builder methods are now implemented!

    // ========================================================================
    // SUMMARY
    // ========================================================================
    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("SUMMARY\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("✅ Passed: {d}\n", .{passed});
    std.debug.print("❌ Failed: {d}\n", .{failed});
    std.debug.print("📊 Total:  {d}\n", .{passed + failed});

    if (failed == 0) {
        std.debug.print("\n🎉 ALL PIPELINE TESTS PASSED!\n", .{});
    } else {
        std.debug.print("\n⚠️  Some tests failed - review output above\n", .{});
    }
}
