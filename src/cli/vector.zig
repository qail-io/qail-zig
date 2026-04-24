//! Vector database CLI module.
//!
//! Implements `vector create|drop|backup|restore|snapshots` against
//! Qdrant REST endpoints.

const std = @import("std");
const io_compat = @import("../runtime/io.zig");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

const SnapshotInfo = struct {
    name: []const u8,
    creation_time: ?[]const u8 = null,
    size: u64 = 0,
};

const SnapshotCreateResponse = struct {
    result: SnapshotInfo,
};

const SnapshotListResponse = struct {
    result: []SnapshotInfo,
};

const SnapshotRecoverRequest = struct {
    location: []const u8,
    priority: ?[]const u8 = null,
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn statusCode(status: std.http.Status) u10 {
    return @intFromEnum(status);
}

fn statusSuccess(status: std.http.Status) bool {
    const code = statusCode(status);
    return code >= 200 and code < 300;
}

fn trimBaseUrl(url: []const u8) []const u8 {
    var out = std.mem.trim(u8, url, " \t\r\n");
    while (out.len > 1 and out[out.len - 1] == '/') {
        out = out[0 .. out.len - 1];
    }
    return out;
}

fn normalizeDistance(raw: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "cosine")) return "Cosine";
    if (std.ascii.eqlIgnoreCase(raw, "euclidean")) return "Euclid";
    if (std.ascii.eqlIgnoreCase(raw, "euclid")) return "Euclid";
    if (std.ascii.eqlIgnoreCase(raw, "dot")) return "Dot";
    return error.InvalidArgument;
}

fn jsonEncodeAlloc(allocator: Allocator, value: anytype) ![]u8 {
    var out = io_compat.AllocatingWriter.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, out.writer());
    return try out.toOwnedSlice();
}

fn qdrantRequest(
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
) !HttpResponse {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io_compat.runtimeIo(),
    };
    defer client.deinit();

    var response_body = io_compat.AllocatingWriter.init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = response_body.writer(),
    });

    return .{
        .status = result.status,
        .body = try response_body.toOwnedSlice(),
    };
}

fn createCollection(
    allocator: Allocator,
    collection: []const u8,
    size: u64,
    distance: []const u8,
    url: []const u8,
) !void {
    const distance_wire = try normalizeDistance(distance);
    const base = trimBaseUrl(url);

    print("→ Creating collection: {s}\n", .{collection});
    print("  Size: {d} dimensions\n", .{size});
    print("  Distance: {s}\n", .{distance_wire});
    print("  URL: {s}\n", .{base});

    const body = .{
        .vectors = .{
            .size = size,
            .distance = distance_wire,
        },
    };
    const payload = try jsonEncodeAlloc(allocator, body);
    defer allocator.free(payload);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}", .{ base, collection });
    defer allocator.free(endpoint);

    const response = try qdrantRequest(allocator, .PUT, endpoint, payload);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Qdrant create failed: {d} {s}\n{s}\n", .{
            statusCode(response.status),
            response.status.phrase() orelse "",
            response.body,
        });
        return error.CreateCollectionFailed;
    }

    print("✓ Collection '{s}' created successfully!\n", .{collection});
}

fn dropCollection(allocator: Allocator, collection: []const u8, url: []const u8) !void {
    const base = trimBaseUrl(url);
    print("→ Dropping collection: {s}\n", .{collection});
    print("  URL: {s}\n", .{base});

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}", .{ base, collection });
    defer allocator.free(endpoint);

    const response = try qdrantRequest(allocator, .DELETE, endpoint, null);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Qdrant drop failed: {d} {s}\n{s}\n", .{
            statusCode(response.status),
            response.status.phrase() orelse "",
            response.body,
        });
        return error.DropCollectionFailed;
    }

    print("✓ Collection '{s}' dropped successfully!\n", .{collection});
}

fn createSnapshot(allocator: Allocator, collection: []const u8, url: []const u8) ![]u8 {
    const base = trimBaseUrl(url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}/snapshots", .{ base, collection });
    defer allocator.free(endpoint);

    print("→ Creating snapshot of '{s}'...\n", .{collection});
    const response = try qdrantRequest(allocator, .POST, endpoint, null);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Snapshot creation failed: {d} {s}\n{s}\n", .{
            statusCode(response.status),
            response.status.phrase() orelse "",
            response.body,
        });
        return error.SnapshotCreateFailed;
    }

    const parsed = try std.json.parseFromSlice(
        SnapshotCreateResponse,
        allocator,
        response.body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const snapshot_name = try allocator.dupe(u8, parsed.value.result.name);
    print("✓ Snapshot created: {s}\n", .{snapshot_name});
    return snapshot_name;
}

fn downloadSnapshot(
    allocator: Allocator,
    collection: []const u8,
    snapshot_name: []const u8,
    output_path: []const u8,
    url: []const u8,
) !void {
    const base = trimBaseUrl(url);
    print("→ Downloading snapshot to '{s}'...\n", .{output_path});
    const endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}/collections/{s}/snapshots/{s}",
        .{ base, collection, snapshot_name },
    );
    defer allocator.free(endpoint);

    const response = try qdrantRequest(allocator, .GET, endpoint, null);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Snapshot download failed: {d} {s}\n{s}\n", .{
            statusCode(response.status),
            response.status.phrase() orelse "",
            response.body,
        });
        return error.SnapshotDownloadFailed;
    }

    try std.Io.Dir.cwd().writeFile(io_compat.runtimeIo(), .{
        .sub_path = output_path,
        .data = response.body,
    });
    print("✓ Downloaded {d} bytes to {s}\n", .{ response.body.len, output_path });
}

fn backupCollection(
    allocator: Allocator,
    collection: []const u8,
    output: ?[]const u8,
    url: []const u8,
) !void {
    const snapshot_name = try createSnapshot(allocator, collection, url);
    defer allocator.free(snapshot_name);
    if (output) |path| {
        try downloadSnapshot(allocator, collection, snapshot_name, path, url);
    }
}

fn restoreSnapshot(
    allocator: Allocator,
    collection: []const u8,
    snapshot_location: []const u8,
    url: []const u8,
) !void {
    const base = trimBaseUrl(url);
    print("→ Restoring '{s}' from snapshot...\n", .{collection});
    print("  Location: {s}\n", .{snapshot_location});

    const endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}/collections/{s}/snapshots/recover",
        .{ base, collection },
    );
    defer allocator.free(endpoint);

    const body = SnapshotRecoverRequest{
        .location = snapshot_location,
        .priority = "snapshot",
    };
    const payload = try jsonEncodeAlloc(allocator, body);
    defer allocator.free(payload);

    const response = try qdrantRequest(allocator, .PUT, endpoint, payload);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Snapshot restore failed: {d} {s}\n{s}\n", .{
            statusCode(response.status),
            response.status.phrase() orelse "",
            response.body,
        });
        return error.SnapshotRestoreFailed;
    }

    print("✓ Collection '{s}' restored successfully!\n", .{collection});
}

fn listSnapshots(allocator: Allocator, collection: []const u8, url: []const u8) !void {
    const base = trimBaseUrl(url);
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/collections/{s}/snapshots", .{ base, collection });
    defer allocator.free(endpoint);

    const response = try qdrantRequest(allocator, .GET, endpoint, null);
    defer allocator.free(response.body);
    if (!statusSuccess(response.status)) {
        print("Failed to list snapshots: {d} {s}\n{s}\n", .{
            statusCode(response.status),
            response.status.phrase() orelse "",
            response.body,
        });
        return error.SnapshotListFailed;
    }

    const parsed = try std.json.parseFromSlice(
        SnapshotListResponse,
        allocator,
        response.body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    if (parsed.value.result.len == 0) {
        print("No snapshots found for '{s}'\n", .{collection});
        return;
    }

    print("Snapshots for '{s}':\n", .{collection});
    for (parsed.value.result) |snapshot| {
        print("  {s} ({d} bytes, created: {s})\n", .{
            snapshot.name,
            snapshot.size,
            snapshot.creation_time orelse "unknown",
        });
    }
}

pub fn make(comptime Cli: type) type {
    const VectorAction = Cli.VectorAction;
    return struct {
        pub fn runVector(allocator: Allocator, action: VectorAction) !void {
            switch (action) {
                .create => |c| try createCollection(allocator, c.collection, c.size, c.distance, c.url),
                .drop => |d| try dropCollection(allocator, d.collection, d.url),
                .backup => |b| try backupCollection(allocator, b.collection, b.output, b.url),
                .restore => |r| try restoreSnapshot(allocator, r.collection, r.snapshot, r.url),
                .snapshots => |s| try listSnapshots(allocator, s.collection, s.url),
            }
        }
    };
}

test "normalize distance supports qail aliases" {
    try std.testing.expectEqualStrings("Cosine", try normalizeDistance("cosine"));
    try std.testing.expectEqualStrings("Euclid", try normalizeDistance("euclidean"));
    try std.testing.expectEqualStrings("Euclid", try normalizeDistance("euclid"));
    try std.testing.expectEqualStrings("Dot", try normalizeDistance("dot"));
    try std.testing.expectError(error.InvalidArgument, normalizeDistance("manhattan"));
}

test "trim base url removes trailing slash but preserves root" {
    try std.testing.expectEqualStrings("http://localhost:6333", trimBaseUrl("http://localhost:6333/"));
    try std.testing.expectEqualStrings("http://localhost:6333", trimBaseUrl(" http://localhost:6333  "));
    try std.testing.expectEqualStrings("/", trimBaseUrl("/"));
}
