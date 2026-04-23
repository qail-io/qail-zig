//! QAIL CLI Entry Point
//!
//! Usage: qail <QUERY> | qail <COMMAND> [ARGS]

const std = @import("std");
const cli = @import("cli/mod.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try init.args.toSlice(allocator);
    defer allocator.free(args);

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
