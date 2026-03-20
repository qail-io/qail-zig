const std = @import("std");

pub const Instant = std.time.Instant;

pub fn now() !Instant {
    return Instant.now();
}

pub fn since(end: Instant, start: Instant) u64 {
    return end.since(start);
}
