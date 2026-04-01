// Array Iterator
//
// PostgreSQL array type parsing and iteration.

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
            if (ndim < 0) {
                return .{
                    .data = data,
                    .pos = data.len,
                    .ndim = ndim,
                    .elem_count = 0,
                };
            }
            const ndim_usize: usize = @intCast(ndim);

            const dims_len = std.math.mul(usize, ndim_usize, 8) catch {
                return .{
                    .data = data,
                    .pos = data.len,
                    .ndim = ndim,
                    .elem_count = 0,
                };
            };
            const dims_end = std.math.add(usize, 12, dims_len) catch {
                return .{
                    .data = data,
                    .pos = data.len,
                    .ndim = ndim,
                    .elem_count = 0,
                };
            };
            if (dims_end > data.len) {
                return .{
                    .data = data,
                    .pos = data.len,
                    .ndim = ndim,
                    .elem_count = 0,
                };
            }

            var count: usize = 1;
            var offset: usize = 12;

            // Read dimensions
            for (0..ndim_usize) |_| {
                const dim = std.mem.readInt(i32, data[offset..][0..4], .big);
                if (dim < 0) {
                    return .{
                        .data = data,
                        .pos = data.len,
                        .ndim = ndim,
                        .elem_count = 0,
                    };
                }
                const dim_usize: usize = @intCast(dim);
                count = std.math.mul(usize, count, dim_usize) catch {
                    return .{
                        .data = data,
                        .pos = data.len,
                        .ndim = ndim,
                        .elem_count = 0,
                    };
                };
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
            if (self.pos + 4 > self.data.len) {
                self.elem_idx = self.elem_count;
                return null;
            }

            // Read element length (-1 = NULL)
            const len_i32 = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
            self.pos += 4;

            if (len_i32 == -1) {
                self.elem_idx += 1;
                return null; // NULL element
            }
            if (len_i32 < -1) {
                self.elem_idx = self.elem_count;
                return null;
            }

            const len: usize = @intCast(len_i32);
            const end = std.math.add(usize, self.pos, len) catch {
                self.elem_idx = self.elem_count;
                return null;
            };
            if (end > self.data.len) {
                self.elem_idx = self.elem_count;
                return null;
            }

            const elem_data = self.data[self.pos..][0..len];
            self.pos = end;
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
            var result: std.ArrayList(T) = .empty;
            defer result.deinit(allocator);
            while (self.elem_idx < self.elem_count) {
                if (self.next()) |elem| {
                    try result.append(allocator, elem);
                }
            }
            return result.toOwnedSlice(allocator);
        }
    };
}

// ==================== Tests ====================

test "ArrayIterator type" {
    _ = ArrayIterator(i32);
    _ = ArrayIterator(i64);
    _ = ArrayIterator([]const u8);
}

test "ArrayIterator toSlice skips null elements but continues iteration" {
    const data = [_]u8{
        0, 0, 0, 1, // ndim = 1
        0, 0, 0, 0, // flags
        0, 0, 0, 23, // element oid (int4)
        0, 0, 0, 3, // dim length = 3
        0, 0, 0, 1, // lower bound = 1
        0, 0, 0, 4, // elem0 len
        0, 0, 0, 1, // elem0 value
        255, 255, 255, 255, // elem1 NULL
        0, 0, 0, 4, // elem2 len
        0, 0, 0, 3, // elem2 value
    };

    var it = ArrayIterator(i32).init(&data);
    const values = try it.toSlice(std.testing.allocator);
    defer std.testing.allocator.free(values);

    try std.testing.expectEqualSlices(i32, &.{ 1, 3 }, values);
}

test "ArrayIterator handles malformed element length safely" {
    const data = [_]u8{
        0, 0, 0, 1, // ndim = 1
        0, 0, 0, 0, // flags
        0, 0, 0, 23, // element oid
        0, 0, 0, 1, // dim length = 1
        0, 0, 0, 1, // lower bound = 1
        255, 255, 255, 254, // invalid element length = -2
    };

    var it = ArrayIterator(i32).init(&data);
    try std.testing.expectEqual(@as(?i32, null), it.next());
    try std.testing.expectEqual(it.elem_count, it.elem_idx);
}

test "ArrayIterator rejects truncated dimension header" {
    const data = [_]u8{
        0, 0, 0, 2, // ndim = 2
        0, 0, 0, 0, // flags
        0, 0, 0, 23, // element oid
        0, 0, 0, 1, // only one dimension entry (truncated)
        0, 0, 0, 1,
    };

    var it = ArrayIterator(i32).init(&data);
    try std.testing.expectEqual(@as(usize, 0), it.elem_count);
    try std.testing.expectEqual(@as(?i32, null), it.next());
}
