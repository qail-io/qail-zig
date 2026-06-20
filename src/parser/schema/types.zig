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

pub const IndexDef = struct {
    name: []const u8,
    table: []const u8,
    columns: []const u8,
    unique: bool = false,
    index_type: ?[]const u8 = null,
    include: ?[]const u8 = null,
    concurrently: bool = false,
    where_clause: ?[]const u8 = null,

    pub fn deinit(self: *const IndexDef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.table);
        allocator.free(self.columns);
        if (self.index_type) |index_type| allocator.free(index_type);
        if (self.include) |include| allocator.free(include);
        if (self.where_clause) |where_clause| allocator.free(where_clause);
    }
};

pub fn referenceActionSql(action: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(action, "cascade")) return "CASCADE";
    if (std.ascii.eqlIgnoreCase(action, "set_null")) return "SET NULL";
    if (std.ascii.eqlIgnoreCase(action, "set_default")) return "SET DEFAULT";
    if (std.ascii.eqlIgnoreCase(action, "restrict")) return "RESTRICT";
    if (std.ascii.eqlIgnoreCase(action, "no_action")) return null;
    return null;
}

pub fn referenceDeferrableSql(deferrable: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(deferrable, "deferrable")) return "DEFERRABLE";
    if (std.ascii.eqlIgnoreCase(deferrable, "initially_deferred")) return "DEFERRABLE INITIALLY DEFERRED";
    if (std.ascii.eqlIgnoreCase(deferrable, "initially_immediate")) return "DEFERRABLE INITIALLY IMMEDIATE";
    return null;
}

pub fn writeReferenceOptionsQail(
    writer: anytype,
    on_delete: ?[]const u8,
    on_update: ?[]const u8,
    deferrable: ?[]const u8,
) !void {
    if (on_delete) |action| {
        if (!std.ascii.eqlIgnoreCase(action, "no_action")) {
            try writer.print(" on_delete {s}", .{action});
        }
    }
    if (on_update) |action| {
        if (!std.ascii.eqlIgnoreCase(action, "no_action")) {
            try writer.print(" on_update {s}", .{action});
        }
    }
    if (deferrable) |mode| {
        try writer.print(" {s}", .{mode});
    }
}

pub fn writeReferenceOptionsSql(
    writer: anytype,
    on_delete: ?[]const u8,
    on_update: ?[]const u8,
    deferrable: ?[]const u8,
) !void {
    if (on_delete) |action| {
        if (referenceActionSql(action)) |sql| {
            try writer.print(" ON DELETE {s}", .{sql});
        }
    }
    if (on_update) |action| {
        if (referenceActionSql(action)) |sql| {
            try writer.print(" ON UPDATE {s}", .{sql});
        }
    }
    if (deferrable) |mode| {
        if (referenceDeferrableSql(mode)) |sql| {
            try writer.print(" {s}", .{sql});
        }
    }
}

pub const MultiColumnForeignKey = struct {
    name: ?[]const u8 = null,
    columns: []const []const u8,
    ref_table: []const u8,
    ref_columns: []const []const u8,
    on_delete: ?[]const u8 = null,
    on_update: ?[]const u8 = null,
    deferrable: ?[]const u8 = null,

    pub fn deinit(self: *const MultiColumnForeignKey, allocator: Allocator) void {
        if (self.name) |name| allocator.free(name);
        for (self.columns) |column| allocator.free(column);
        allocator.free(self.columns);
        allocator.free(self.ref_table);
        for (self.ref_columns) |column| allocator.free(column);
        allocator.free(self.ref_columns);
        if (self.on_delete) |action| allocator.free(action);
        if (self.on_update) |action| allocator.free(action);
        if (self.deferrable) |mode| allocator.free(mode);
    }
};

pub fn writeIdentifierList(writer: anytype, identifiers: []const []const u8) !void {
    for (identifiers, 0..) |identifier, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(identifier);
    }
}

pub fn writeMultiColumnForeignKeyQail(writer: anytype, fk: *const MultiColumnForeignKey) !void {
    try writer.writeAll("foreign_key (");
    try writeIdentifierList(writer, fk.columns);
    try writer.print(") references {s}(", .{fk.ref_table});
    try writeIdentifierList(writer, fk.ref_columns);
    try writer.writeByte(')');
    if (fk.name) |name| try writer.print(" constraint {s}", .{name});
    try writeReferenceOptionsQail(writer, fk.on_delete, fk.on_update, fk.deferrable);
}

pub fn writeMultiColumnForeignKeySql(writer: anytype, fk: *const MultiColumnForeignKey) !void {
    if (fk.name) |name| try writer.print("CONSTRAINT {s} ", .{name});
    try writer.writeAll("FOREIGN KEY (");
    try writeIdentifierList(writer, fk.columns);
    try writer.print(") REFERENCES {s}(", .{fk.ref_table});
    try writeIdentifierList(writer, fk.ref_columns);
    try writer.writeByte(')');
    try writeReferenceOptionsSql(writer, fk.on_delete, fk.on_update, fk.deferrable);
}

pub const TableDef = struct {
    name: []const u8,
    columns: std.ArrayList(ColumnDef),
    foreign_keys: std.ArrayList(MultiColumnForeignKey),
    enable_rls: bool = false,
    force_rls: bool = false,

    pub fn init(allocator: Allocator, name: []const u8) TableDef {
        return .{
            .name = name,
            .columns = std.ArrayList(ColumnDef).initCapacity(allocator, 0) catch unreachable,
            .foreign_keys = std.ArrayList(MultiColumnForeignKey).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *TableDef, allocator: Allocator) void {
        for (self.columns.items) |*col| {
            col.deinit(allocator);
        }
        for (self.foreign_keys.items) |*fk| {
            fk.deinit(allocator);
        }
        self.columns.deinit(allocator);
        self.foreign_keys.deinit(allocator);
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
                try writeReferenceOptionsSql(
                    writer,
                    col.reference_on_delete,
                    col.reference_on_update,
                    col.reference_deferrable,
                );
            }
            if (col.check) |check_expr| {
                if (col.check_name) |name| {
                    try writer.print(" CONSTRAINT {s} CHECK({s})", .{ name, check_expr });
                } else {
                    try writer.print(" CHECK({s})", .{check_expr});
                }
            }
            for (col.extra_checks, 0..) |check_expr, check_index| {
                if (col.checkNameAt(if (col.check != null) check_index + 1 else check_index)) |name| {
                    try writer.print(" CONSTRAINT {s} CHECK({s})", .{ name, check_expr });
                } else {
                    try writer.print(" CHECK({s})", .{check_expr});
                }
            }

            if (i < self.columns.items.len - 1 or self.foreign_keys.items.len > 0) {
                try writer.writeAll(",");
            }
            try writer.writeAll("\n");
        }

        for (self.foreign_keys.items, 0..) |fk, i| {
            try writer.writeAll("    ");
            try writeMultiColumnForeignKeySql(writer, &fk);
            if (i < self.foreign_keys.items.len - 1) try writer.writeAll(",");
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
    reference_on_delete: ?[]const u8 = null,
    reference_on_update: ?[]const u8 = null,
    reference_deferrable: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    check: ?[]const u8 = null,
    check_name: ?[]const u8 = null,
    extra_checks: []const []const u8 = &.{},
    extra_check_names: []const ?[]const u8 = &.{},

    pub fn deinit(self: *ColumnDef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.typ);
        if (self.type_params) |p| allocator.free(p);
        if (self.references) |r| allocator.free(r);
        if (self.reference_on_delete) |action| allocator.free(action);
        if (self.reference_on_update) |action| allocator.free(action);
        if (self.reference_deferrable) |mode| allocator.free(mode);
        if (self.default_value) |d| allocator.free(d);
        if (self.check) |c| allocator.free(c);
        if (self.check_name) |name| allocator.free(name);
        for (self.extra_checks) |check_expr| allocator.free(check_expr);
        if (self.extra_checks.len > 0) allocator.free(self.extra_checks);
        for (self.extra_check_names) |maybe_name| {
            if (maybe_name) |name| allocator.free(name);
        }
        if (self.extra_check_names.len > 0) allocator.free(self.extra_check_names);
    }

    pub fn checkCount(self: *const ColumnDef) usize {
        var count = self.extra_checks.len;
        if (self.check != null) count += 1;
        return count;
    }

    pub fn checkAt(self: *const ColumnDef, index: usize) []const u8 {
        if (self.check) |check_expr| {
            if (index == 0) return check_expr;
            return self.extra_checks[index - 1];
        }
        return self.extra_checks[index];
    }

    pub fn checkNameAt(self: *const ColumnDef, index: usize) ?[]const u8 {
        if (self.check != null) {
            if (index == 0) return self.check_name;
            const extra_index = index - 1;
            if (extra_index >= self.extra_check_names.len) return null;
            return self.extra_check_names[extra_index];
        }
        if (index >= self.extra_check_names.len) return null;
        return self.extra_check_names[index];
    }
};
