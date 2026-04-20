const std = @import("std");
const net = @import("../compat/net.zig");

/// GSSENC Request code (80877104 = version 1234.5680)
pub const GSSENC_REQUEST_CODE: u32 = 80877104;

pub const GssEncNegotiationResult = enum {
    accepted,
    rejected,
    server_error,
};

pub const GssEncNegotiationStreamResult = union(enum) {
    accepted: net.Stream,
    rejected,
    server_error,
};

pub fn tryGssEncRequestStream(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_ms: ?i32,
) !GssEncNegotiationStreamResult {
    var stream = if (timeout_ms) |ms|
        try net.tcpConnectToHostWithTimeout(allocator, host, port, ms)
    else
        try net.tcpConnectToHost(allocator, host, port);
    var handoff = false;
    defer if (!handoff) stream.close();

    var request: [8]u8 = undefined;
    std.mem.writeInt(u32, request[0..4], 8, .big);
    std.mem.writeInt(u32, request[4..8], GSSENC_REQUEST_CODE, .big);
    try net.writeAllStream(stream, &request);

    var response: [1]u8 = undefined;
    const read_n = try net.readStream(stream, &response);
    if (read_n != 1) return error.EndOfStream;

    return switch (response[0]) {
        'G' => blk: {
            try net.setStreamBlocking(stream, false);
            defer net.setStreamBlocking(stream, true) catch {};

            var extra: [1]u8 = undefined;
            const extra_n = net.readStream(stream, &extra) catch 0;
            if (extra_n > 0) return error.GssEncBufferStuffingDetected;

            handoff = true;
            break :blk .{ .accepted = stream };
        },
        'N' => .rejected,
        'E' => .server_error,
        else => error.InvalidGssEncResponse,
    };
}

pub fn tryGssEncRequest(
    host: []const u8,
    port: u16,
    timeout_ms: ?i32,
) !GssEncNegotiationResult {
    const result = try tryGssEncRequestStream(std.heap.page_allocator, host, port, timeout_ms);
    return switch (result) {
        .accepted => |stream| blk: {
            var owned = stream;
            owned.close();
            break :blk .accepted;
        },
        .rejected => .rejected,
        .server_error => .server_error,
    };
}

const Mode = enum {
    accept,
    accept_extra,
    reject,
    server_error,
    invalid,
};

const ServerCtx = struct {
    server: *net.Server,
    mode: Mode,
};

fn serverThread(ctx: *ServerCtx) void {
    defer ctx.server.deinit();

    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var request: [8]u8 = undefined;
    _ = net.readStream(conn.stream, &request) catch return;

    const request_code = std.mem.readInt(u32, request[4..8], .big);
    if (request_code != GSSENC_REQUEST_CODE) return;

    switch (ctx.mode) {
        .accept => {
            net.writeAllStream(conn.stream, "G") catch {};
        },
        .accept_extra => {
            net.writeAllStream(conn.stream, "GX") catch {};
        },
        .reject => {
            net.writeAllStream(conn.stream, "N") catch {};
        },
        .server_error => {
            net.writeAllStream(conn.stream, "E") catch {};
        },
        .invalid => {
            net.writeAllStream(conn.stream, "X") catch {};
        },
    }
}

fn runScript(mode: Mode) !GssEncNegotiationResult {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();

    var ctx = ServerCtx{ .server = &server, .mode = mode };
    var thread = try std.Thread.spawn(.{}, serverThread, .{&ctx});
    defer thread.join();

    return try tryGssEncRequest("127.0.0.1", port, 1000);
}

test "gssenc request code" {
    try std.testing.expectEqual(@as(u32, 80877104), GSSENC_REQUEST_CODE);
}

test "gssenc request accepts accepted response" {
    try std.testing.expectEqual(GssEncNegotiationResult.accepted, try runScript(.accept));
}

test "gssenc request detects extra bytes after accepted response" {
    try std.testing.expectError(error.GssEncBufferStuffingDetected, runScript(.accept_extra));
}

test "gssenc request accepts rejected response" {
    try std.testing.expectEqual(GssEncNegotiationResult.rejected, try runScript(.reject));
}

test "gssenc request suppresses server error response" {
    try std.testing.expectEqual(GssEncNegotiationResult.server_error, try runScript(.server_error));
}

test "gssenc request rejects invalid response byte" {
    try std.testing.expectError(error.InvalidGssEncResponse, runScript(.invalid));
}

test "gssenc request resolves localhost hostname" {
    var server = try net.Address.listen(try net.Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();
    const nudge_addr = try net.Address.parseIp4("127.0.0.1", port);

    var ctx = ServerCtx{ .server = &server, .mode = .accept };
    var thread = try std.Thread.spawn(.{}, serverThread, .{&ctx});
    defer {
        const nudge_stream = net.tcpConnectToAddress(nudge_addr) catch null;
        if (nudge_stream) |stream| stream.close();
        thread.join();
    }

    try std.testing.expectEqual(GssEncNegotiationResult.accepted, try tryGssEncRequest("localhost", port, 1000));
}
