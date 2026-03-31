const std = @import("std");
const builtin = @import("builtin");
const tls_client = @import("tls_client.zig");

pub const Address = std.net.Address;
pub const Server = std.net.Server;
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

/// Cross-platform socket read helper.
///
/// `std.net.Stream.read` currently routes through `ReadFile` on Windows, which
/// does not behave correctly for TCP sockets in our test/runtime paths. Use
/// `recv` directly so plain socket I/O behaves consistently across platforms.
pub fn readStream(stream: Stream, buffer: []u8) !usize {
    if (builtin.os.tag != .windows) return stream.read(buffer);

    const windows = std.os.windows;
    const rc = windows.recvfrom(stream.handle, buffer.ptr, buffer.len, 0, null, null);
    if (rc == windows.ws2_32.SOCKET_ERROR) {
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAEFAULT => unreachable,
            .WSAEINPROGRESS, .WSAEINTR => unreachable,
            .WSAEINVAL => return error.SocketNotBound,
            .WSAEMSGSIZE => return error.MessageTooBig,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAENETRESET => return error.ConnectionResetByPeer,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSANOTINITIALISED => unreachable,
            .WSA_IO_PENDING => unreachable,
            .WSA_OPERATION_ABORTED => unreachable,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
    return @intCast(rc);
}

/// Cross-platform socket write helper.
pub fn writeStream(stream: Stream, bytes: []const u8) !usize {
    if (builtin.os.tag != .windows) return stream.write(bytes);

    const windows = std.os.windows;
    const rc = windows.sendto(stream.handle, bytes.ptr, bytes.len, 0, null, 0);
    if (rc == windows.ws2_32.SOCKET_ERROR) {
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAECONNABORTED, .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAEFAULT => unreachable,
            .WSAEINPROGRESS, .WSAEINTR => unreachable,
            .WSAEINVAL => return error.SocketNotBound,
            .WSAEMSGSIZE => return error.MessageTooBig,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAENETRESET => return error.ConnectionResetByPeer,
            .WSAENOBUFS => return error.SystemResources,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAENOTSOCK => unreachable,
            .WSAEOPNOTSUPP => unreachable,
            .WSAESHUTDOWN => unreachable,
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSANOTINITIALISED => unreachable,
            .WSA_IO_PENDING => unreachable,
            .WSA_OPERATION_ABORTED => unreachable,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
    return @intCast(rc);
}

/// Cross-platform socket write-all helper.
pub fn writeAllStream(stream: Stream, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try writeStream(stream, bytes[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
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
    options: tls_client.Options,
) !tls_client.Client {
    return tls_client.Client.init(reader.interface(), &writer.interface, options);
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
