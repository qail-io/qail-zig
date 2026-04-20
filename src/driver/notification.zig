const std = @import("std");
const protocol = @import("../protocol/mod.zig");

const Decoder = protocol.Decoder;

// LISTEN / NOTIFY helpers live here so the driver owns only state-machine logic.

/// LISTEN/NOTIFY message from PostgreSQL.
pub const Notification = struct {
    /// PID of the backend that sent NOTIFY.
    process_id: i32,
    /// Notification channel.
    channel: []u8,
    /// Notification payload (may be empty).
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Notification) void {
        self.allocator.free(self.channel);
        self.allocator.free(self.payload);
    }
};

pub fn decodeNotification(allocator: std.mem.Allocator, payload: []const u8) !Notification {
    var decoder = Decoder.init(payload);
    const parsed = try decoder.parseNotificationResponse();

    const channel = try allocator.dupe(u8, parsed.channel);
    errdefer allocator.free(channel);

    const payload_copy = try allocator.dupe(u8, parsed.payload);

    return .{
        .process_id = parsed.process_id,
        .channel = channel,
        .payload = payload_copy,
        .allocator = allocator,
    };
}

pub fn appendDecodedNotification(
    allocator: std.mem.Allocator,
    notifications: *std.ArrayListUnmanaged(Notification),
    payload: []const u8,
) !void {
    var notification = try decodeNotification(allocator, payload);
    errdefer notification.deinit();
    try notifications.append(allocator, notification);
}

pub fn drainBufferedNotifications(
    allocator: std.mem.Allocator,
    notifications: *std.ArrayListUnmanaged(Notification),
) ![]Notification {
    const out = try allocator.alloc(Notification, notifications.items.len);
    std.mem.copyForwards(Notification, out, notifications.items);
    notifications.clearRetainingCapacity();
    return out;
}

pub fn popBufferedNotification(
    notifications: *std.ArrayListUnmanaged(Notification),
) ?Notification {
    if (notifications.items.len == 0) return null;
    return notifications.orderedRemove(0);
}

test "decode notification response" {
    const data = [_]u8{
        0, 0, 0, 123, // process id
        'm', 'y', '_', 'c', 'h', 'a', 'n', 0, // channel
        'h', 'e', 'l', 'l', 'o', 0, // payload
    };

    var notification = try decodeNotification(std.testing.allocator, &data);
    defer notification.deinit();

    try std.testing.expectEqual(@as(i32, 123), notification.process_id);
    try std.testing.expectEqualStrings("my_chan", notification.channel);
    try std.testing.expectEqualStrings("hello", notification.payload);
}

test "buffered notifications can be appended and popped" {
    var notifications: std.ArrayListUnmanaged(Notification) = .empty;
    defer {
        for (notifications.items) |*notification| notification.deinit();
        notifications.deinit(std.testing.allocator);
    }

    const data = [_]u8{
        0,   0,   0,   9,
        'c', 'h', 'a', 'n',
        0,   'p', 'a', 'y',
        'l', 'o', 'a', 'd',
        0,
    };

    try appendDecodedNotification(std.testing.allocator, &notifications, &data);
    try std.testing.expectEqual(@as(usize, 1), notifications.items.len);

    var notification = popBufferedNotification(&notifications).?;
    defer notification.deinit();

    try std.testing.expectEqual(@as(i32, 9), notification.process_id);
    try std.testing.expectEqualStrings("chan", notification.channel);
    try std.testing.expectEqualStrings("payload", notification.payload);
    try std.testing.expectEqual(@as(usize, 0), notifications.items.len);
}

test "drain buffered notifications preserves order" {
    var notifications: std.ArrayListUnmanaged(Notification) = .empty;
    defer {
        for (notifications.items) |*notification| notification.deinit();
        notifications.deinit(std.testing.allocator);
    }

    const first = [_]u8{ 0, 0, 0, 1, 'a', 0, 'x', 0 };
    const second = [_]u8{ 0, 0, 0, 2, 'b', 0, 'y', 0 };
    try appendDecodedNotification(std.testing.allocator, &notifications, &first);
    try appendDecodedNotification(std.testing.allocator, &notifications, &second);

    const drained = try drainBufferedNotifications(std.testing.allocator, &notifications);
    defer {
        for (drained) |*notification| notification.deinit();
        std.testing.allocator.free(drained);
    }

    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expectEqualStrings("a", drained[0].channel);
    try std.testing.expectEqualStrings("x", drained[0].payload);
    try std.testing.expectEqualStrings("b", drained[1].channel);
    try std.testing.expectEqualStrings("y", drained[1].payload);
    try std.testing.expectEqual(@as(usize, 0), notifications.items.len);
}
