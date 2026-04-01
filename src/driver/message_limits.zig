const std = @import("std");

/// Maximum backend message length field (`length` includes its own 4 bytes).
///
/// Mirrors qail.rs guardrail to cap memory pressure from malformed/malicious
/// servers. Individual transports with fixed buffers can enforce stricter caps.
pub const max_backend_message_len_field: usize = 64 * 1024 * 1024; // 64 MiB

/// Validate PostgreSQL backend `length` field and return payload length.
///
/// `max_len_field` is the maximum accepted value of the wire `length` field.
pub fn validateLengthField(length: u32, max_len_field: usize) !usize {
    const len_field: usize = @intCast(length);
    if (len_field < 4) return error.InvalidMessageLength;
    if (len_field > max_len_field) return error.MessageTooLarge;
    return len_field - 4;
}

test "validateLengthField rejects too-small length" {
    try std.testing.expectError(error.InvalidMessageLength, validateLengthField(3, 1024));
}

test "validateLengthField rejects oversized length" {
    try std.testing.expectError(error.MessageTooLarge, validateLengthField(2048, 1024));
}

test "validateLengthField returns payload length on valid frame" {
    try std.testing.expectEqual(@as(usize, 5), try validateLengthField(9, 1024));
}
