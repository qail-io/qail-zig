const std = @import("std");

pub fn bytes(dest: []u8) void {
    std.crypto.random.bytes(dest);
}
