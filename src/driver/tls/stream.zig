//! TLS Stream Wrappers
//!
//! Wraps std.net.Stream to implement std.Io.Reader and std.Io.Writer
//! interfaces required by std.crypto.tls.Client.

const std = @import("std");
const tls = std.crypto.tls;

/// Minimum buffer size for TLS records (per std.crypto.tls spec)
pub const MIN_BUFFER_LEN = tls.max_ciphertext_record_len;

/// Reader wrapper for std.net.Stream
/// Implements the interface expected by std.crypto.tls.Client
pub const StreamReader = struct {
    stream: std.net.Stream,
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,

    const Self = @This();

    pub fn init(stream: std.net.Stream, buffer: []u8) Self {
        std.debug.assert(buffer.len >= MIN_BUFFER_LEN);
        return .{
            .stream = stream,
            .buffer = buffer,
        };
    }

    /// Read bytes into destination buffer
    pub fn read(self: *Self, dest: []u8) !usize {
        // First drain buffered data
        const buffered = self.end - self.start;
        if (buffered > 0) {
            const to_copy = @min(buffered, dest.len);
            @memcpy(dest[0..to_copy], self.buffer[self.start..][0..to_copy]);
            self.start += to_copy;
            return to_copy;
        }

        // Buffer empty, read directly from stream
        return self.stream.read(dest);
    }

    /// Peek at buffered data without consuming
    pub fn peek(self: *Self, n: usize) ![]const u8 {
        // Ensure we have enough data buffered
        try self.ensureBuffered(n);
        return self.buffer[self.start..][0..n];
    }

    /// Ensure at least n bytes are buffered
    pub fn ensureBuffered(self: *Self, n: usize) !void {
        while (self.end - self.start < n) {
            // Compact if needed
            if (self.start > 0) {
                const used = self.end - self.start;
                std.mem.copyForwards(u8, self.buffer[0..used], self.buffer[self.start..self.end]);
                self.end = used;
                self.start = 0;
            }

            // Read more
            const bytes_read = try self.stream.read(self.buffer[self.end..]);
            if (bytes_read == 0) return error.EndOfStream;
            self.end += bytes_read;
        }
    }

    /// Discard n bytes from buffer
    pub fn discard(self: *Self, n: usize) void {
        self.start += n;
        if (self.start >= self.end) {
            self.start = 0;
            self.end = 0;
        }
    }

    /// Get current buffered slice
    pub fn bufferedSlice(self: *Self) []const u8 {
        return self.buffer[self.start..self.end];
    }
};

/// Writer wrapper for std.net.Stream
/// Implements buffered writing for TLS records
pub const StreamWriter = struct {
    stream: std.net.Stream,
    buffer: []u8,
    pos: usize = 0,

    const Self = @This();

    pub fn init(stream: std.net.Stream, buffer: []u8) Self {
        return .{
            .stream = stream,
            .buffer = buffer,
        };
    }

    /// Write bytes to buffer
    pub fn write(self: *Self, data: []const u8) !usize {
        const available = self.buffer.len - self.pos;
        const to_write = @min(available, data.len);

        @memcpy(self.buffer[self.pos..][0..to_write], data[0..to_write]);
        self.pos += to_write;

        // Auto-flush if buffer full
        if (self.pos >= self.buffer.len) {
            try self.flush();
        }

        return to_write;
    }

    /// Write all bytes (may require multiple writes)
    pub fn writeAll(self: *Self, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const written = try self.write(remaining);
            remaining = remaining[written..];
        }
    }

    /// Flush buffer to stream
    pub fn flush(self: *Self) !void {
        if (self.pos > 0) {
            try self.stream.writeAll(self.buffer[0..self.pos]);
            self.pos = 0;
        }
    }

    /// Write vectored data
    pub fn writeVecAll(self: *Self, iovecs: []const []const u8) !void {
        for (iovecs) |iov| {
            try self.writeAll(iov);
        }
    }
};

// ==================== Tests ====================

test "StreamReader init" {
    var buf: [MIN_BUFFER_LEN]u8 = undefined;
    // Can't test without actual stream, just verify struct
    _ = StreamReader{
        .stream = undefined,
        .buffer = &buf,
    };
}

test "StreamWriter init" {
    var buf: [1024]u8 = undefined;
    _ = StreamWriter{
        .stream = undefined,
        .buffer = &buf,
    };
}

test "MIN_BUFFER_LEN is correct" {
    try std.testing.expect(MIN_BUFFER_LEN >= 16384);
}
