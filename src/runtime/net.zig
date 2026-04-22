const std = @import("std");
const builtin = @import("builtin");
const io_compat = @import("io.zig");
const tls_client = @import("tls_client.zig");

const Io = std.Io;
const IpAddress = std.Io.net.IpAddress;
const IoServer = std.Io.net.Server;
const IoStream = std.Io.net.Stream;
const HostName = std.Io.net.HostName;

pub const StreamReader = std.Io.net.Stream.Reader;
pub const StreamWriter = std.Io.net.Stream.Writer;

pub const Address = struct {
    inner: IpAddress,

    pub fn parseIp4(host: []const u8, port: u16) !Address {
        return .{ .inner = try IpAddress.parseIp4(host, port) };
    }

    pub fn getPort(self: Address) u16 {
        return self.inner.getPort();
    }

    pub fn listen(self: Address, options: IpAddress.ListenOptions) !Server {
        const server = try self.inner.listen(runtimeIo(), options);
        return .{
            .inner = server,
            .listen_address = .{ .inner = server.socket.address },
        };
    }
};

pub const Stream = struct {
    inner: IoStream,
    handle: std.posix.fd_t,

    fn fromInner(stream: IoStream) Stream {
        const wrapped = Stream{
            .inner = stream,
            .handle = stream.socket.handle,
        };
        enableTcpNoDelay(wrapped.handle);
        return wrapped;
    }

    pub fn close(self: Stream) void {
        self.inner.close(runtimeIo());
    }

    pub fn read(self: Stream, buffer: []u8) !usize {
        var data = [1][]u8{buffer};
        const io_iface = runtimeIo();
        return io_iface.vtable.netRead(io_iface.userdata, self.handle, &data);
    }

    pub fn write(self: Stream, bytes: []const u8) !usize {
        const io_iface = runtimeIo();
        return io_iface.vtable.netWrite(io_iface.userdata, self.handle, &.{}, &.{bytes}, 1);
    }

    pub fn writeAll(self: Stream, bytes: []const u8) !void {
        return writeAllStream(self, bytes);
    }

    pub fn reader(self: Stream, buffer: []u8) StreamReader {
        return self.inner.reader(runtimeIo(), buffer);
    }

    pub fn writer(self: Stream, buffer: []u8) StreamWriter {
        return self.inner.writer(runtimeIo(), buffer);
    }
};

pub const Server = struct {
    inner: IoServer,
    listen_address: Address,

    pub fn deinit(self: *Server) void {
        self.inner.deinit(runtimeIo());
    }

    pub fn accept(self: *Server) !struct { stream: Stream, address: Address } {
        const stream = try self.inner.accept(runtimeIo());
        return .{
            .stream = Stream.fromInner(stream),
            .address = .{ .inner = stream.socket.address },
        };
    }
};

pub fn parseIp4(host: []const u8, port: u16) !Address {
    return Address.parseIp4(host, port);
}

pub fn tcpConnectToAddress(address: Address) !Stream {
    const stream = try address.inner.connect(runtimeIo(), .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    });
    return Stream.fromInner(stream);
}

pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
    _ = allocator;
    return tcpConnectToHostInner(host, port, .none);
}

pub fn tcpConnectToHostWithTimeout(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_ms: i32,
) !Stream {
    _ = allocator;
    return tcpConnectToHostInner(host, port, sanitizeTimeout(timeoutFromMs(timeout_ms)));
}

pub fn tcpConnectToAddressWithTimeout(address: Address, timeout_ms: i32) !Stream {
    const timeout = sanitizeTimeout(timeoutFromMs(timeout_ms));
    const stream = try address.inner.connect(runtimeIo(), .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = timeout,
    });
    return Stream.fromInner(stream);
}

pub fn tcpConnectToIp4WithTimeout(host: []const u8, port: u16, timeout_ms: i32) !Stream {
    const address = try parseIp4(host, port);
    return tcpConnectToAddressWithTimeout(address, timeout_ms);
}

pub fn readStream(stream: Stream, buffer: []u8) !usize {
    return stream.read(buffer);
}

pub fn writeStream(stream: Stream, bytes: []const u8) !usize {
    return stream.write(bytes);
}

pub fn writeAllStream(stream: Stream, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try writeStream(stream, bytes[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

pub fn streamReader(stream: Stream, buffer: []u8) StreamReader {
    return stream.reader(buffer);
}

pub fn streamWriter(stream: Stream, buffer: []u8) StreamWriter {
    return stream.writer(buffer);
}

pub fn initTlsClient(
    reader: *StreamReader,
    writer: *StreamWriter,
    options: tls_client.Options,
) !tls_client.Client {
    return tls_client.Client.init(&reader.interface, &writer.interface, options);
}

fn setBlocking(fd: std.posix.fd_t, blocking: bool) !void {
    if (comptime builtin.os.tag == .windows) {
        return;
    }

    const posix = std.posix;
    const nonblock_bit = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

    var flags: usize = 0;
    while (true) {
        const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                flags = @intCast(rc);
                break;
            },
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    const new_flags = if (blocking) (flags & ~nonblock_bit) else (flags | nonblock_bit);
    while (true) {
        switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, new_flags))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn enableTcpNoDelay(fd: std.posix.fd_t) void {
    if (comptime builtin.os.tag == .windows) return;

    const one: i32 = 1;
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

pub fn setStreamBlocking(stream: Stream, blocking: bool) !void {
    try setBlocking(stream.handle, blocking);
}

fn runtimeIo() Io {
    return io_compat.runtimeIo();
}

fn timeoutFromMs(timeout_ms: i32) Io.Timeout {
    if (timeout_ms <= 0) return .none;
    return .{
        .duration = .{
            .clock = .awake,
            .raw = Io.Duration.fromMilliseconds(timeout_ms),
        },
    };
}

fn sanitizeTimeout(timeout: Io.Timeout) Io.Timeout {
    if (timeout == .none) return .none;
    if (!io_compat.runtimeUsesEvented()) return .none;
    return timeout;
}

fn tcpConnectToHostInner(host: []const u8, port: u16, timeout: Io.Timeout) !Stream {
    if (IpAddress.parse(host, port)) |ip_address| {
        const stream = try ip_address.connect(runtimeIo(), .{
            .mode = .stream,
            .protocol = .tcp,
            .timeout = timeout,
        });
        return Stream.fromInner(stream);
    } else |_| {}

    const host_name = try HostName.init(host);
    const stream = try HostName.connect(host_name, runtimeIo(), port, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = timeout,
    });
    return Stream.fromInner(stream);
}

const LocalhostAcceptCtx = struct {
    server: *Server,
    done: *std.atomic.Value(bool),
};

fn localhostAcceptThread(ctx: *LocalhostAcceptCtx) void {
    defer ctx.done.store(true, .release);
    defer ctx.server.deinit();

    var conn = ctx.server.accept() catch return;
    defer conn.stream.close();
}

test "tcp connect to host with timeout resolves localhost" {
    var server = try Address.listen(try Address.parseIp4("127.0.0.1", 0), .{ .reuse_address = true });
    const port = server.listen_address.getPort();
    const nudge_addr = try Address.parseIp4("127.0.0.1", port);
    var done = std.atomic.Value(bool).init(false);
    var ctx = LocalhostAcceptCtx{ .server = &server, .done = &done };

    var thread = try std.Thread.spawn(.{}, localhostAcceptThread, .{&ctx});
    defer {
        if (!done.load(.acquire)) {
            const nudge_stream = tcpConnectToAddress(nudge_addr) catch null;
            if (nudge_stream) |stream| stream.close();
        }
        thread.join();
    }

    var stream = try tcpConnectToHostWithTimeout(std.testing.allocator, "localhost", port, 1000);
    stream.close();
}
