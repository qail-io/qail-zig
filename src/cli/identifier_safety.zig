const std = @import("std");

pub fn isValidBareIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 63) return false;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

pub fn isValidQualifiedIdentifier(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (!isValidBareIdentifier(part)) return false;
    }
    return count > 0;
}

test "cli identifier safety validates generated qail identifiers" {
    try std.testing.expect(isValidBareIdentifier("description"));
    try std.testing.expect(isValidQualifiedIdentifier("public.orders"));

    try std.testing.expect(!isValidBareIdentifier(""));
    try std.testing.expect(!isValidBareIdentifier("1description"));
    try std.testing.expect(!isValidBareIdentifier("description;drop"));
    try std.testing.expect(!isValidQualifiedIdentifier("public..orders"));
    try std.testing.expect(!isValidQualifiedIdentifier("public.orders;drop"));
}
