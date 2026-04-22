const std = @import("std");

/// Parsed estimate from `EXPLAIN (FORMAT JSON)`.
pub const ExplainEstimate = struct {
    total_cost: f64,
    plan_rows: u64,
};

pub fn parseExplainJson(json: []const u8) ?ExplainEstimate {
    const total_cost = extractJsonNumber(json, "Total Cost") orelse return null;
    const plan_rows_f = extractJsonNumber(json, "Plan Rows") orelse return null;

    if (!std.math.isFinite(total_cost) or !std.math.isFinite(plan_rows_f)) return null;
    if (plan_rows_f < 0) return null;

    const max_u64_f = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    if (plan_rows_f > max_u64_f) return null;

    return .{
        .total_cost = total_cost,
        .plan_rows = @intFromFloat(plan_rows_f),
    };
}

fn extractJsonNumber(json: []const u8, key: []const u8) ?f64 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after_key = json[start + pattern.len ..];
    const trimmed = std.mem.trimStart(u8, after_key, " \t\r\n");

    var end: usize = 0;
    while (end < trimmed.len and isJsonNumberByte(trimmed[end])) : (end += 1) {}
    if (end == 0) return null;

    return std.fmt.parseFloat(f64, trimmed[0..end]) catch null;
}

fn isJsonNumberByte(ch: u8) bool {
    return std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E';
}

test "parse explain json estimate" {
    const json =
        \\[{"Plan":{"Node Type":"Seq Scan","Relation Name":"users","Total Cost":1234.56,"Plan Rows":5000}}]
    ;

    const estimate = parseExplainJson(json) orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqRel(@as(f64, 1234.56), estimate.total_cost, 1e-12);
    try std.testing.expectEqual(@as(u64, 5000), estimate.plan_rows);
}

test "parse explain json invalid" {
    try std.testing.expect(parseExplainJson("not json") == null);
    try std.testing.expect(parseExplainJson("{}") == null);
    try std.testing.expect(parseExplainJson("[]") == null);
}
