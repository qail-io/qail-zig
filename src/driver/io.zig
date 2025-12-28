//! High-Performance I/O Layer for PostgreSQL Driver
//!
//! Optimized receive functions for fast message processing.
//! Port of qail.rs/qail-pg/src/driver/io.rs
//!
//! Key optimizations:
//! - recvMsgTypeFast: Skip parsing, return message type only
//! - recvWithDataFast: Inline DataRow parsing (no enum allocation)
//! - recvDataZerocopy: Zero-copy column slices
//! - recvDataUltra: Ultra-fast 2-column optimized path

const std = @import("std");

/// I/O buffer configuration
pub const IoConfig = struct {
    /// Read buffer size (128KB default)
    read_buffer_size: usize = 131072,
    /// Write buffer size (64KB default)
    write_buffer_size: usize = 65536,
    /// Minimum free space before re-reserving
    min_free_space: usize = 65536,
};

/// High-performance I/O buffer for PostgreSQL messages.
///
/// Uses a dynamic ring buffer with zero-copy message access.
pub const IoBuffer = struct {
    data: []u8,
    allocator: std.mem.Allocator,
    read_pos: usize = 0,
    write_pos: usize = 0,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize) !IoBuffer {
        const data = try allocator.alloc(u8, size);
        return .{
            .data = data,
            .allocator = allocator,
            .capacity = size,
        };
    }

    pub fn deinit(self: *IoBuffer) void {
        self.allocator.free(self.data);
    }

    /// Available bytes to read
    pub fn len(self: *const IoBuffer) usize {
        return self.write_pos - self.read_pos;
    }

    /// Free space for writing
    pub fn freeSpace(self: *const IoBuffer) usize {
        return self.capacity - self.write_pos;
    }

    /// Get readable slice
    pub fn readable(self: *const IoBuffer) []const u8 {
        return self.data[self.read_pos..self.write_pos];
    }

    /// Get writable slice
    pub fn writable(self: *IoBuffer) []u8 {
        return self.data[self.write_pos..self.capacity];
    }

    /// Advance read position (consume bytes)
    pub fn consume(self: *IoBuffer, n: usize) void {
        self.read_pos += n;
        // Compact if too much wasted space
        if (self.read_pos > self.capacity / 2 and self.len() < self.capacity / 4) {
            self.compact();
        }
    }

    /// Advance write position (new data written)
    pub fn commit(self: *IoBuffer, n: usize) void {
        self.write_pos += n;
    }

    /// Compact buffer by moving unread data to front
    fn compact(self: *IoBuffer) void {
        const unread = self.len();
        if (self.read_pos > 0 and unread > 0) {
            std.mem.copyForwards(u8, self.data[0..unread], self.data[self.read_pos .. self.read_pos + unread]);
        }
        self.read_pos = 0;
        self.write_pos = unread;
    }

    /// Ensure enough space for n bytes
    pub fn ensureSpace(self: *IoBuffer, n: usize) !void {
        if (self.freeSpace() < n) {
            self.compact();
            if (self.freeSpace() < n) {
                // Need to grow
                const new_capacity = self.capacity * 2;
                const new_data = try self.allocator.realloc(self.data, new_capacity);
                self.data = new_data;
                self.capacity = new_capacity;
            }
        }
    }

    /// Read message type without full parse (FAST PATH)
    ///
    /// Returns message type byte if complete message available.
    /// Caller must call consumeMessage() after processing.
    pub fn peekMsgType(self: *const IoBuffer) ?u8 {
        const buf = self.readable();
        if (buf.len < 5) return null;

        const msg_len = std.mem.readInt(u32, buf[1..5], .big);
        if (buf.len < msg_len + 1) return null;

        return buf[0];
    }

    /// Get message length (excluding type byte)
    pub fn peekMsgLen(self: *const IoBuffer) ?u32 {
        const buf = self.readable();
        if (buf.len < 5) return null;
        return std.mem.readInt(u32, buf[1..5], .big);
    }

    /// Get message payload (excluding type byte and length)
    pub fn peekMsgPayload(self: *const IoBuffer) ?[]const u8 {
        const buf = self.readable();
        if (buf.len < 5) return null;

        const msg_len = std.mem.readInt(u32, buf[1..5], .big);
        if (buf.len < msg_len + 1) return null;

        // Payload starts after type (1) + length (4) = 5 bytes
        // Payload length is msg_len - 4 (length includes itself)
        return buf[5 .. msg_len + 1];
    }

    /// Consume a complete message
    pub fn consumeMessage(self: *IoBuffer) void {
        const buf = self.readable();
        if (buf.len >= 5) {
            const msg_len = std.mem.readInt(u32, buf[1..5], .big);
            self.consume(msg_len + 1);
        }
    }

    /// FAST DataRow parsing - returns columns as slices into buffer
    ///
    /// For 'D' (DataRow): returns parsed columns as slices
    /// CRITICAL: Slices are only valid until next buffer operation!
    pub fn parseDataRowFast(self: *const IoBuffer, allocator: std.mem.Allocator) !?[]?[]const u8 {
        const payload = self.peekMsgPayload() orelse return null;

        if (payload.len < 2) return null;

        const column_count = std.mem.readInt(u16, payload[0..2], .big);
        var columns = try allocator.alloc(?[]const u8, column_count);
        errdefer allocator.free(columns);

        var pos: usize = 2;
        for (0..column_count) |i| {
            if (pos + 4 > payload.len) break;

            const col_len = std.mem.readInt(i32, payload[pos..][0..4], .big);
            pos += 4;

            if (col_len == -1) {
                columns[i] = null;
            } else {
                const ulen: usize = @intCast(col_len);
                if (pos + ulen <= payload.len) {
                    columns[i] = payload[pos .. pos + ulen];
                    pos += ulen;
                } else {
                    columns[i] = null;
                }
            }
        }

        return columns;
    }

    /// ULTRA-FAST 2-column parsing for (id, name) pattern
    ///
    /// Returns (col0, col1) slices or null if not DataRow
    /// Optimized for common SELECT id, name queries
    pub fn parseDataRowUltra(self: *const IoBuffer) ?struct { col0: ?[]const u8, col1: ?[]const u8 } {
        const payload = self.peekMsgPayload() orelse return null;

        if (payload.len < 2) return null;

        // Skip column count (assume 2)
        var pos: usize = 2;

        // Column 0
        if (pos + 4 > payload.len) return null;
        const len0 = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;

        const col0: ?[]const u8 = if (len0 == -1)
            null
        else blk: {
            const ulen: usize = @intCast(len0);
            const slice = payload[pos .. pos + ulen];
            pos += ulen;
            break :blk slice;
        };

        // Column 1
        if (pos + 4 > payload.len) return null;
        const len1 = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;

        const col1: ?[]const u8 = if (len1 == -1)
            null
        else blk: {
            const ulen: usize = @intCast(len1);
            const slice = payload[pos .. pos + ulen];
            break :blk slice;
        };

        return .{ .col0 = col0, .col1 = col1 };
    }
};

/// Write buffer for batched writes
pub const WriteBuffer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WriteBuffer {
        return .{
            .data = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WriteBuffer) void {
        self.data.deinit(self.allocator);
    }

    /// Buffer bytes for later flush (no syscall)
    pub fn buffer(self: *WriteBuffer, bytes: []const u8) !void {
        try self.data.appendSlice(self.allocator, bytes);
    }

    /// Get buffered data for flushing
    pub fn getBuffered(self: *const WriteBuffer) []const u8 {
        return self.data.items;
    }

    /// Clear the buffer after flush
    pub fn clear(self: *WriteBuffer) void {
        self.data.clearRetainingCapacity();
    }

    /// Check if buffer has data
    pub fn hasData(self: *const WriteBuffer) bool {
        return self.data.items.len > 0;
    }
};

// ==================== Tests ====================

test "IoBuffer basic operations" {
    const allocator = std.testing.allocator;
    var buf = try IoBuffer.init(allocator, 1024);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.len());
    try std.testing.expectEqual(@as(usize, 1024), buf.freeSpace());
}

test "IoBuffer message peek" {
    const allocator = std.testing.allocator;
    var buf = try IoBuffer.init(allocator, 1024);
    defer buf.deinit();

    // Simulate a complete PostgreSQL message: 'D' + length(8) + payload
    buf.data[0] = 'D';
    std.mem.writeInt(u32, buf.data[1..5], 8, .big); // length includes itself
    buf.data[5] = 0; // column count high
    buf.data[6] = 1; // column count low = 1
    buf.data[7] = 0; // len high
    buf.data[8] = 0; // len
    buf.commit(9);

    try std.testing.expectEqual(@as(?u8, 'D'), buf.peekMsgType());
}

test "WriteBuffer operations" {
    const allocator = std.testing.allocator;
    var wb = WriteBuffer.init(allocator);
    defer wb.deinit();

    try wb.buffer("hello");
    try wb.buffer(" world");

    try std.testing.expectEqualStrings("hello world", wb.getBuffered());
    try std.testing.expect(wb.hasData());

    wb.clear();
    try std.testing.expect(!wb.hasData());
}
