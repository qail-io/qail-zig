const std = @import("std");

/// Return the number of positional bind parameters required by PostgreSQL SQL.
///
/// PostgreSQL placeholders are 1-based and reusable, so the required bind count
/// is the highest `$N` seen outside quoted strings, quoted identifiers, comments,
/// and dollar-quoted strings.
pub fn countSqlParams(sql: []const u8) usize {
    var max_index: usize = 0;
    var i: usize = 0;

    while (i < sql.len) {
        switch (sql[i]) {
            '\'' => skipSingleQuoted(sql, &i),
            '"' => skipDoubleQuoted(sql, &i),
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    skipLineComment(sql, &i);
                } else {
                    i += 1;
                }
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    skipBlockComment(sql, &i);
                } else {
                    i += 1;
                }
            },
            '$' => {
                if (dollarQuoteDelimiterLen(sql, i)) |delim_len| {
                    skipDollarQuoted(sql, &i, delim_len);
                } else if (i + 1 < sql.len and std.ascii.isDigit(sql[i + 1])) {
                    const index = readParamIndex(sql, &i);
                    if (index > max_index) max_index = index;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }

    return max_index;
}

fn skipSingleQuoted(sql: []const u8, index: *usize) void {
    index.* += 1;
    while (index.* < sql.len) {
        if (sql[index.*] == '\'') {
            if (index.* + 1 < sql.len and sql[index.* + 1] == '\'') {
                index.* += 2;
                continue;
            }
            index.* += 1;
            return;
        }
        index.* += 1;
    }
}

fn skipDoubleQuoted(sql: []const u8, index: *usize) void {
    index.* += 1;
    while (index.* < sql.len) {
        if (sql[index.*] == '"') {
            if (index.* + 1 < sql.len and sql[index.* + 1] == '"') {
                index.* += 2;
                continue;
            }
            index.* += 1;
            return;
        }
        index.* += 1;
    }
}

fn skipLineComment(sql: []const u8, index: *usize) void {
    index.* += 2;
    while (index.* < sql.len and sql[index.*] != '\n') {
        index.* += 1;
    }
}

fn skipBlockComment(sql: []const u8, index: *usize) void {
    index.* += 2;
    var depth: usize = 1;

    while (index.* < sql.len and depth > 0) {
        if (index.* + 1 < sql.len and sql[index.*] == '/' and sql[index.* + 1] == '*') {
            depth += 1;
            index.* += 2;
        } else if (index.* + 1 < sql.len and sql[index.*] == '*' and sql[index.* + 1] == '/') {
            depth -= 1;
            index.* += 2;
        } else {
            index.* += 1;
        }
    }
}

fn dollarQuoteDelimiterLen(sql: []const u8, start: usize) ?usize {
    std.debug.assert(sql[start] == '$');

    var i = start + 1;
    if (i >= sql.len) return null;
    if (sql[i] == '$') return 2;
    if (!isIdentStart(sql[i])) return null;

    i += 1;
    while (i < sql.len and isIdentRest(sql[i])) {
        i += 1;
    }

    if (i < sql.len and sql[i] == '$') return i - start + 1;
    return null;
}

fn skipDollarQuoted(sql: []const u8, index: *usize, delimiter_len: usize) void {
    const delimiter = sql[index.* .. index.* + delimiter_len];
    const search_start = index.* + delimiter_len;
    if (std.mem.indexOf(u8, sql[search_start..], delimiter)) |offset| {
        index.* = search_start + offset + delimiter_len;
    } else {
        index.* = sql.len;
    }
}

fn readParamIndex(sql: []const u8, index: *usize) usize {
    std.debug.assert(sql[index.*] == '$');

    index.* += 1;
    var value: usize = 0;
    while (index.* < sql.len and std.ascii.isDigit(sql[index.*])) {
        const digit: usize = @intCast(sql[index.*] - '0');
        value = std.math.mul(usize, value, 10) catch {
            skipParamDigits(sql, index);
            return std.math.maxInt(usize);
        };
        value = std.math.add(usize, value, digit) catch {
            skipParamDigits(sql, index);
            return std.math.maxInt(usize);
        };
        index.* += 1;
    }
    return value;
}

fn skipParamDigits(sql: []const u8, index: *usize) void {
    while (index.* < sql.len and std.ascii.isDigit(sql[index.*])) {
        index.* += 1;
    }
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentRest(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "countSqlParams counts highest positional placeholder" {
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT * FROM users"));
    try std.testing.expectEqual(@as(usize, 1), countSqlParams("SELECT * FROM users WHERE id = $1"));
    try std.testing.expectEqual(@as(usize, 2), countSqlParams("SELECT * FROM users WHERE id = $1 AND name = $2"));
    try std.testing.expectEqual(@as(usize, 1), countSqlParams("SELECT $1, $1"));
    try std.testing.expectEqual(@as(usize, 10), countSqlParams("SELECT $10"));
}

test "countSqlParams ignores placeholders in SQL text contexts" {
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT '$1'"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT 'it''s $1'"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT \"$1\" FROM users"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT 1 -- $1\n"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT /* $1 */ 1"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT /* outer /* $1 */ still outer */ 1"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT $$ $1 $$"));
    try std.testing.expectEqual(@as(usize, 0), countSqlParams("SELECT $tag$ $1 $tag$"));
}

test "countSqlParams resumes after skipped SQL text contexts" {
    try std.testing.expectEqual(@as(usize, 1), countSqlParams("SELECT '$2', $1"));
    try std.testing.expectEqual(@as(usize, 2), countSqlParams("SELECT $$ $9 $$, $2"));
    try std.testing.expectEqual(@as(usize, 3), countSqlParams("SELECT /* $1 */ $3"));
    try std.testing.expectEqual(@as(usize, 4), countSqlParams("SELECT \"col$1\", $4"));
}
