const std = @import("std");
const io_compat = @import("io.zig");

pub const Instant = std.Io.Timestamp;

pub fn now() !Instant {
    return std.Io.Clock.now(.awake, io_compat.runtimeIo());
}

pub fn since(end: Instant, start: Instant) u64 {
    const ns = start.durationTo(end).toNanoseconds();
    if (ns <= 0) return 0;
    return @intCast(ns);
}
