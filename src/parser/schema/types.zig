const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_cmd = @import("../../ast/cmd.zig");

pub const PolicyTarget = ast_cmd.PolicyTarget;
pub const PolicyPermissiveness = ast_cmd.PolicyPermissiveness;
pub const PolicyDef = ast_cmd.PolicyDef;

pub const GrantAction = enum {
    grant,
    revoke,
};

pub const GrantDef = struct {
    action: GrantAction,
    privileges: []const []const u8,
    on_object: []const u8,
    role: []const u8,

    pub fn deinit(self: *const GrantDef, allocator: Allocator) void {
        for (self.privileges) |p| allocator.free(p);
        allocator.free(self.privileges);
        allocator.free(self.on_object);
        allocator.free(self.role);
    }
};

pub const TableDef = struct {
    name: []const u8,
    columns: std.ArrayList(ColumnDef),

    pub fn init(allocator: Allocator, name: []const u8) TableDef {
        return .{
            .name = name,
            .columns = std.ArrayList(ColumnDef).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *TableDef, allocator: Allocator) void {
        for (self.columns.items) |*col| {
            col.deinit(allocator);
        }
        self.columns.deinit(allocator);
        allocator.free(self.name);
    }

    pub fn findColumn(self: *const TableDef, name: []const u8) ?*const ColumnDef {
        for (self.columns.items) |*col| {
            if (std.ascii.eqlIgnoreCase(col.name, name)) {
                return col;
            }
        }
        return null;
    }

    pub fn toDdl(self: *const TableDef, allocator: Allocator) ![]const u8 {
        const io = @import("../../runtime/io.zig");
        var ddl_writer = io.AllocatingWriter.init(allocator);
        defer ddl_writer.deinit();
        const writer = ddl_writer.writer();

        try writer.print("CREATE TABLE IF NOT EXISTS {s} (\n", .{self.name});

        for (self.columns.items, 0..) |col, i| {
            try writer.print("    {s} {s}", .{ col.name, col.typ });

            if (col.type_params) |params| {
                try writer.print("({s})", .{params});
            }
            if (col.is_array) {
                try writer.writeAll("[]");
            }
            if (col.primary_key) {
                try writer.writeAll(" PRIMARY KEY");
            }
            if (!col.nullable and !col.primary_key and !col.is_serial) {
                try writer.writeAll(" NOT NULL");
            }
            if (col.unique and !col.primary_key) {
                try writer.writeAll(" UNIQUE");
            }
            if (col.default_value) |default| {
                try writer.print(" DEFAULT {s}", .{default});
            }
            if (col.references) |refs| {
                try writer.print(" REFERENCES {s}", .{refs});
            }
            if (col.check) |check_expr| {
                try writer.print(" CHECK({s})", .{check_expr});
            }

            if (i < self.columns.items.len - 1) {
                try writer.writeAll(",");
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll(")");
        return ddl_writer.toOwnedSlice();
    }
};

pub const ColumnDef = struct {
    name: []const u8,
    typ: []const u8,
    type_params: ?[]const u8 = null,
    is_array: bool = false,
    is_serial: bool = false,
    nullable: bool = true,
    primary_key: bool = false,
    unique: bool = false,
    references: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    check: ?[]const u8 = null,

    pub fn deinit(self: *ColumnDef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.typ);
        if (self.type_params) |p| allocator.free(p);
        if (self.references) |r| allocator.free(r);
        if (self.default_value) |d| allocator.free(d);
        if (self.check) |c| allocator.free(c);
    }
};
