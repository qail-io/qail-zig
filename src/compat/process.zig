const std = @import("std");

pub fn argsAlloc(allocator: std.mem.Allocator) ![][:0]u8 {
    return std.process.argsAlloc(allocator);
}

pub fn argsFree(allocator: std.mem.Allocator, args: []const [:0]u8) void {
    std.process.argsFree(allocator, args);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, key);
}
