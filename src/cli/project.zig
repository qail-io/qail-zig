const std = @import("std");
const io_compat = @import("../runtime/io.zig");

const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub fn initProject(allocator: Allocator, target_dir: []const u8) !void {
    const io_iface = io_compat.runtimeIo();
    const root = std.mem.trim(u8, target_dir, " \t\r\n");
    if (root.len == 0) return error.MissingArgument;

    if (!std.mem.eql(u8, root, ".")) {
        try std.Io.Dir.cwd().createDirPath(io_iface, root);
    }

    const schema_path = if (std.mem.eql(u8, root, "."))
        "schema.qail"
    else
        try std.fmt.allocPrint(allocator, "{s}/schema.qail", .{root});
    defer if (!std.mem.eql(u8, root, ".")) allocator.free(schema_path);

    const migrations_path = if (std.mem.eql(u8, root, "."))
        "migrations"
    else
        try std.fmt.allocPrint(allocator, "{s}/migrations", .{root});
    defer if (!std.mem.eql(u8, root, ".")) allocator.free(migrations_path);

    try std.Io.Dir.cwd().createDirPath(io_iface, migrations_path);

    const schema_template =
        \\-- QAIL schema
        \\table users (
        \\  id uuid primary_key
        \\  email text unique
        \\  created_at timestamptz default NOW()
        \\)
        \\
    ;

    var created_schema = true;
    std.Io.Dir.cwd().writeFile(io_iface, .{
        .sub_path = schema_path,
        .data = schema_template,
        .flags = .{
            .truncate = false,
            .exclusive = true,
        },
    }) catch |err| {
        if (err == error.PathAlreadyExists) {
            created_schema = false;
        } else {
            return err;
        }
    };

    print("📦 Initialized QAIL project at {s}\n", .{root});
    if (created_schema) {
        print("  ✓ {s}\n", .{schema_path});
    } else {
        print("  • {s} already exists\n", .{schema_path});
    }
    print("  ✓ {s}/\n", .{migrations_path});
    print("  Next: qail check {s}\n", .{schema_path});
}
