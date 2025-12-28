//! QAIL CLI Entry Point
//!
//! Usage: qail <QUERY> | qail <COMMAND> [ARGS]

const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd = cli.parse(allocator, args) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.debug.print("Try 'qail --help' for usage\n", .{});
        std.process.exit(1);
    };

    cli.run(allocator, cmd) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}
