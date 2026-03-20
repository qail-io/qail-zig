const std = @import("std");
const builtin = @import("builtin");

pub const FixedBufferStream = std.io.FixedBufferStream([]u8);
pub const FixedBufferStreamWriter = FixedBufferStream.Writer;
pub const AllocatingListWriter = std.ArrayListUnmanaged(u8).Writer;

/// Stable fixed-buffer writer adapter.
///
/// This provides a tiny API surface (`writer`, `getWritten`) that stays stable
/// across std I/O migrations.
pub const FixedBufferWriter = struct {
    stream: FixedBufferStream,

    pub fn init(buffer: []u8) FixedBufferWriter {
        return .{ .stream = std.io.fixedBufferStream(buffer) };
    }

    pub fn writer(self: *FixedBufferWriter) FixedBufferStreamWriter {
        return self.stream.writer();
    }

    pub fn getWritten(self: *const FixedBufferWriter) []const u8 {
        return self.stream.getWritten();
    }
};

/// Stable allocating writer adapter.
pub const AllocatingWriter = struct {
    list: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AllocatingWriter {
        return .{ .allocator = allocator };
    }

    pub fn writer(self: *AllocatingWriter) AllocatingListWriter {
        return self.list.writer(self.allocator);
    }

    pub fn toOwnedSlice(self: *AllocatingWriter) error{OutOfMemory}![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *AllocatingWriter) void {
        self.list.deinit(self.allocator);
    }
};

/// Cross-platform stdin read shim.
///
/// Today this uses `std.posix.read`; future std I/O migrations should only
/// require changes in this module.
pub fn readStdin(buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        return error.UnsupportedPlatform;
    }
    return std.posix.read(std.posix.STDIN_FILENO, buf);
}

/// Cross-platform stdout write shim.
///
/// Today this uses `std.posix.write`; future std I/O migrations should only
/// require changes in this module.
pub fn writeStdout(bytes: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        return error.UnsupportedPlatform;
    }
    return std.posix.write(std.posix.STDOUT_FILENO, bytes);
}

/// Cross-platform stdout write-all helper.
pub fn writeAllStdout(bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try writeStdout(bytes[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}
