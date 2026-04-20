const std = @import("std");
const builtin = @import("builtin");
const process_compat = @import("process.zig");

// Zig 0.16.0 has unresolved Linux Evented/uring compile issues in some
// cross-target/no-libc CI paths. Keep dual-mode support on non-Linux targets.
const supports_evented = builtin.os.tag != .linux and std.Io.Evented != void;

pub const FixedBufferStreamWriter = *std.Io.Writer;
pub const AllocatingListWriter = *std.Io.Writer;

const RuntimeMode = enum(u32) {
    threaded,
    evented,
};

const RequestedMode = enum {
    auto,
    threaded,
    evented,
};

const InitState = enum(u8) {
    uninitialized,
    initializing,
    initialized,
};

const StdIoRuntime = struct {
    var init_state: std.atomic.Value(InitState) = .init(.uninitialized);
    var active_mode: std.atomic.Value(RuntimeMode) = .init(.threaded);
    var threaded: std.Io.Threaded = undefined;
    var evented: if (supports_evented) std.Io.Evented else void = if (supports_evented) undefined else {};

    fn getIo() std.Io {
        ensureInit();
        return switch (active_mode.load(.acquire)) {
            .threaded => threaded.io(),
            .evented => if (supports_evented) evented.io() else threaded.io(),
        };
    }

    fn runtimeUsesEvented() bool {
        ensureInit();
        return active_mode.load(.acquire) == .evented;
    }

    fn downgradeToThreadedOnNetworkDown(err: anyerror) bool {
        if (err != error.NetworkDown) return false;
        if (!supports_evented) return false;
        ensureInit();
        return active_mode.cmpxchgStrong(.evented, .threaded, .acq_rel, .acquire) == null;
    }

    fn ensureInit() void {
        while (true) {
            switch (init_state.load(.acquire)) {
                .initialized => return,
                .initializing => std.atomic.spinLoopHint(),
                .uninitialized => {
                    if (init_state.cmpxchgStrong(.uninitialized, .initializing, .acq_rel, .acquire) != null) {
                        continue;
                    }

                    threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
                    active_mode.store(.threaded, .release);

                    const requested_mode = requestedMode();
                    if (supports_evented and requested_mode != .threaded) {
                        if (std.Io.Evented.init(&evented, std.heap.page_allocator, .{})) |_| {
                            active_mode.store(.evented, .release);
                        } else |_| {
                            active_mode.store(.threaded, .release);
                        }
                    }

                    init_state.store(.initialized, .release);
                    return;
                },
            }
        }
    }

    fn requestedMode() RequestedMode {
        if (modeFromEnv()) |mode| {
            return switch (mode) {
                .auto => if (supports_evented) .evented else .threaded,
                else => mode,
            };
        }
        if (wantEvented()) return .evented;
        return .threaded;
    }

    fn modeFromEnv() ?RequestedMode {
        const value = process_compat.getEnvVarOwned(std.heap.page_allocator, "QAIL_STD_IO_MODE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return null,
            else => return null,
        };
        defer std.heap.page_allocator.free(value);

        if (value.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(value, "threaded")) return .threaded;
        if (std.ascii.eqlIgnoreCase(value, "evented")) return .evented;
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        return null;
    }
};

fn wantEvented() bool {
    const value = process_compat.getEnvVarOwned(std.heap.page_allocator, "QAIL_STD_IO_EVENTED") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    defer std.heap.page_allocator.free(value);
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return true;
}

pub fn runtimeIo() std.Io {
    return StdIoRuntime.getIo();
}

pub fn runtimeUsesEvented() bool {
    return StdIoRuntime.runtimeUsesEvented();
}

/// Returns true when caller should retry operation with threaded runtime.
pub fn retryWithThreaded(err: anyerror) bool {
    return StdIoRuntime.downgradeToThreadedOnNetworkDown(err);
}

/// Stable fixed-buffer writer adapter.
pub const FixedBufferWriter = struct {
    impl: std.Io.Writer,

    pub fn init(buffer: []u8) FixedBufferWriter {
        return .{ .impl = std.Io.Writer.fixed(buffer) };
    }

    pub fn writer(self: *FixedBufferWriter) FixedBufferStreamWriter {
        return &self.impl;
    }

    pub fn getWritten(self: *const FixedBufferWriter) []const u8 {
        return self.impl.buffered();
    }
};

/// Stable allocating writer adapter.
pub const AllocatingWriter = struct {
    impl: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) AllocatingWriter {
        return .{ .impl = std.Io.Writer.Allocating.init(allocator) };
    }

    pub fn writer(self: *AllocatingWriter) AllocatingListWriter {
        return &self.impl.writer;
    }

    pub fn toOwnedSlice(self: *AllocatingWriter) error{OutOfMemory}![]u8 {
        return self.impl.toOwnedSlice();
    }

    pub fn deinit(self: *AllocatingWriter) void {
        self.impl.deinit();
    }
};

/// Cross-platform stdin read shim using std.Io dual mode.
pub fn readStdin(buf: []u8) !usize {
    const io_iface = StdIoRuntime.getIo();
    return std.Io.File.stdin().readStreaming(io_iface, &.{buf});
}

/// Cross-platform stdout write shim using std.Io dual mode.
pub fn writeStdout(bytes: []const u8) !usize {
    const io_iface = StdIoRuntime.getIo();
    return std.Io.File.stdout().writeStreaming(io_iface, &.{}, &.{bytes}, 1);
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
