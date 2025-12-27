//! Array Iterator
//!
//! PostgreSQL array type parsing and iteration.

const std = @import("std");

/// Iterator over PostgreSQL array elements
pub fn ArrayIterator(comptime T: type) type {
    return struct {
        data: []const u8,
        pos: usize = 0,
        ndim: i32 = 0,
        elem_count: usize = 0,
        elem_idx: usize = 0,

        const Self = @This();

        /// Initialize from PostgreSQL array wire format
        pub fn init(data: []const u8) Self {
            if (data.len < 12) return .{ .data = data };

            // Array format: ndim(4) + flags(4) + oid(4) + dim_info... + elements
            const ndim = std.mem.readInt(i32, data[0..4], .big);

            var count: usize = 1;
            var offset: usize = 12;

            // Read dimensions
            for (0..@intCast(@max(0, ndim))) |_| {
                if (offset + 8 > data.len) break;
                const dim = std.mem.readInt(i32, data[offset..][0..4], .big);
                count *= @intCast(@max(0, dim));
                offset += 8; // dim + lower_bound
            }

            return .{
                .data = data,
                .pos = offset,
                .ndim = ndim,
                .elem_count = count,
            };
        }

        /// Get next element
        pub fn next(self: *Self) ?T {
            if (self.elem_idx >= self.elem_count) return null;
            if (self.pos + 4 > self.data.len) return null;

            // Read element length (-1 = NULL)
            const len_i32 = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
            self.pos += 4;

            if (len_i32 < 0) {
                self.elem_idx += 1;
                return null; // NULL element
            }

            const len: usize = @intCast(len_i32);
            if (self.pos + len > self.data.len) return null;

            const elem_data = self.data[self.pos..][0..len];
            self.pos += len;
            self.elem_idx += 1;

            // Convert based on type
            return Self.parseElement(elem_data);
        }

        fn parseElement(data: []const u8) T {
            if (T == []const u8) {
                return data;
            } else if (T == i32) {
                if (data.len >= 4) {
                    return std.mem.readInt(i32, data[0..4], .big);
                }
                return 0;
            } else if (T == i64) {
                if (data.len >= 8) {
                    return std.mem.readInt(i64, data[0..8], .big);
                }
                return 0;
            } else {
                @compileError("Unsupported array element type");
            }
        }

        /// Collect all elements to slice
        pub fn toSlice(self: *Self, allocator: std.mem.Allocator) ![]T {
            var result = std.ArrayList(T).init(allocator);
            while (self.next()) |elem| {
                try result.append(elem);
            }
            return result.toOwnedSlice();
        }
    };
}

// ==================== Tests ====================

test "ArrayIterator type" {
    _ = ArrayIterator(i32);
    _ = ArrayIterator(i64);
    _ = ArrayIterator([]const u8);
}
