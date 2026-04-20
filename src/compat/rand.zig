const std = @import("std");
const io_compat = @import("io.zig");

pub fn bytes(dest: []u8) void {
    std.Io.random(io_compat.runtimeIo(), dest);
}
