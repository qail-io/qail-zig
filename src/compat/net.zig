const std = @import("std");
const builtin = @import("builtin");
const tls = std.crypto.tls;

pub const Address = std.net.Address;
pub const Stream = std.net.Stream;
pub const StreamReader = std.net.Stream.Reader;
pub const StreamWriter = std.net.Stream.Writer;

pub fn parseIp4(host: []const u8, port: u16) !Address {
    return std.net.Address.parseIp4(host, port);
}

pub fn tcpConnectToAddress(address: Address) !Stream {
    return std.net.tcpConnectToAddress(address);
}

pub fn tcpConnectToHost(allocator: std.mem.Allocator, host: []const u8, port: u16) !Stream {
    return std.net.tcpConnectToHost(allocator, host, port);
}

pub fn tcpConnectToAddressWithTimeout(address: Address, timeout_ms: i32) !Stream {
    const posix = std.posix;

    // Create socket (initially blocking)
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    // Set non-blocking
    try setBlocking(fd, false);

    // Attempt connect (will return EINPROGRESS/WSAEWOULDBLOCK for non-blocking)
    const result = posix.connect(fd, &address.any, address.getOsSockLen());
    if (result) |_| {
        // Connected immediately
    } else |err| {
        if (err == error.WouldBlock) {
            // Wait for connection with timeout using poll
            var fds = [1]posix.pollfd{
                .{ .fd = if (builtin.os.tag == .windows) @ptrCast(fd) else fd, .events = posix.POLL.OUT, .revents = 0 },
            };
            const poll_result = try posix.poll(&fds, timeout_ms);
            if (poll_result == 0) {
                return error.ConnectionTimeout;
            }

            // Check for socket error (skip on Windows - getsockopt requires libc)
            if (builtin.os.tag != .windows) {
                try posix.getsockoptError(fd);
            }
        } else {
            return err;
        }
    }

    // Set socket back to blocking mode
    try setBlocking(fd, true);

    return .{ .handle = fd };
}

pub fn tcpConnectToIp4WithTimeout(host: []const u8, port: u16, timeout_ms: i32) !Stream {
    const address = try parseIp4(host, port);
    return tcpConnectToAddressWithTimeout(address, timeout_ms);
}

/// Construct the std stream reader via a compatibility shim.
pub fn streamReader(stream: Stream, buffer: []u8) StreamReader {
    return stream.reader(buffer);
}

/// Construct the std stream writer via a compatibility shim.
pub fn streamWriter(stream: Stream, buffer: []u8) StreamWriter {
    return stream.writer(buffer);
}

/// Initialize std TLS client via compatibility shim.
///
/// Any stream interface shape changes in future Zig versions should be localized
/// to this function.
pub fn initTlsClient(
    reader: *StreamReader,
    writer: *StreamWriter,
    options: tls.Client.Options,
) !tls.Client {
    return tls.Client.init(reader.interface(), &writer.interface, options);
}

fn setBlocking(fd: std.posix.fd_t, blocking: bool) !void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        // 0 = blocking, 1 = non-blocking
        var mode: c_ulong = if (blocking) 0 else 1;
        const socket: windows.ws2_32.SOCKET = @ptrCast(fd);
        const res = windows.ws2_32.ioctlsocket(socket, windows.ws2_32.FIONBIO, &mode);
        if (res != 0) return error.SocketError;
    } else {
        const posix = std.posix;
        // O_NONBLOCK values: Linux=2048, macOS/BSD=4
        const O_NONBLOCK: u32 = if (builtin.os.tag == .linux) 2048 else 4;
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        const new_flags = if (blocking)
            flags & ~O_NONBLOCK
        else
            flags | O_NONBLOCK;
        _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
    }
}
