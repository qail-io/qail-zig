const std = @import("std");
const protocol = @import("../protocol/mod.zig");

const Decoder = protocol.Decoder;

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

    const notification_payload = try allocator.dupe(u8, parsed.payload);

    return .{
        .process_id = parsed.process_id,
        .channel = channel,
        .payload = notification_payload,
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
