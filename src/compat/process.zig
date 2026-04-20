const std = @import("std");
const builtin = @import("builtin");

pub const EnvMap = std.process.Environ.Map;

pub fn getEnvMap(allocator: std.mem.Allocator) !EnvMap {
    return switch (builtin.os.tag) {
        .windows => std.process.Environ.createMap(.{ .block = .global }, allocator),
        else => blk: {
            var map = EnvMap.init(allocator);
            errdefer map.deinit();

            if (!builtin.link_libc) break :blk map;

            const c = std.c;
            if (!@hasDecl(c, "environ")) break :blk map;

            var len: usize = 0;
            while (c.environ[len] != null) : (len += 1) {}
            const env_slice = c.environ[0..len :null];
            try map.putPosixBlock(.{ .slice = @ptrCast(env_slice) });
            break :blk map;
        },
    };
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();
    const value = env_map.get(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}
