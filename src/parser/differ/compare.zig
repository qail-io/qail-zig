const std = @import("std");
const schema = @import("../schema.zig");

const PolicyDef = schema.PolicyDef;
const GrantDef = schema.GrantDef;

fn optionalStrEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn policyEquals(a: *const PolicyDef, b: *const PolicyDef) bool {
    return std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.table, b.table) and
        a.target == b.target and
        a.permissiveness == b.permissiveness and
        optionalStrEq(a.role, b.role) and
        optionalStrEq(a.using_sql, b.using_sql) and
        optionalStrEq(a.with_check_sql, b.with_check_sql);
}

pub fn grantEquals(a: *const GrantDef, b: *const GrantDef) bool {
    if (a.action != b.action) return false;
    if (!std.mem.eql(u8, a.on_object, b.on_object)) return false;
    if (!std.mem.eql(u8, a.role, b.role)) return false;
    if (a.privileges.len != b.privileges.len) return false;
    for (a.privileges, 0..) |privilege, i| {
        if (!std.mem.eql(u8, privilege, b.privileges[i])) return false;
    }
    return true;
}
