//! Schema tooling CLI module.
//!
//! Implements `schema doctor|split|merge` using parser + renderer primitives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io_compat = @import("../runtime/io.zig");
const parser = @import("../parser/mod.zig");
const render = @import("../transpiler/postgres/render.zig");

const print = std.debug.print;
const ORDER_FILE = "_order.qail";
const MAX_ORDER_FILE_BYTES = 512 * 1024;
const MAX_SCHEMA_FILE_BYTES = 16 * 1024 * 1024;

const SchemaSource = union(enum) {
    file: []const u8,
    directory: []const u8,
};

const OrderedModuleList = struct {
    files: std.ArrayList([]u8),

    fn init(allocator: Allocator) OrderedModuleList {
        return .{
            .files = std.ArrayList([]u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    fn deinit(self: *OrderedModuleList, allocator: Allocator) void {
        for (self.files.items) |path| allocator.free(path);
        self.files.deinit(allocator);
    }
};

const NameSet = std.StringHashMap(void);

fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io_compat.runtimeIo(),
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn writeFileAll(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io_compat.runtimeIo(), .{
        .sub_path = path,
        .data = data,
    });
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io_compat.runtimeIo(), path, .{}) catch return false;
    return true;
}

fn resolveSchemaSource(path: []const u8) !SchemaSource {
    const stat = std.Io.Dir.cwd().statFile(io_compat.runtimeIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    return switch (stat.kind) {
        .directory => .{ .directory = path },
        .file => .{ .file = path },
        else => error.InvalidSchemaSource,
    };
}

fn isSchemaModuleFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".qail")) return false;
    return !std.mem.eql(u8, name, ORDER_FILE);
}

fn appendPath(allocator: Allocator, dir_path: []const u8, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
}

fn filenameComponent(allocator: Allocator, raw: []const u8) ![]u8 {
    var safe = std.ArrayList(u8).initCapacity(allocator, raw.len) catch unreachable;
    errdefer safe.deinit(allocator);

    var last_was_separator = false;
    for (raw) |ch| {
        const is_safe = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.';
        if (is_safe) {
            try safe.append(allocator, ch);
            last_was_separator = false;
        } else if (!last_was_separator) {
            try safe.append(allocator, '_');
            last_was_separator = true;
        }
    }

    const trimmed = std.mem.trim(u8, safe.items, "_-.");
    if (trimmed.len == 0) {
        safe.deinit(allocator);
        return allocator.dupe(u8, "unnamed");
    }

    const out = try allocator.dupe(u8, trimmed);
    safe.deinit(allocator);
    return out;
}

fn schemaModuleFilename(allocator: Allocator, table_name: []const u8) ![]u8 {
    const safe_name = try filenameComponent(allocator, table_name);
    defer allocator.free(safe_name);

    if (std.mem.eql(u8, safe_name, table_name)) {
        return std.fmt.allocPrint(allocator, "{s}.qail", .{safe_name});
    }

    const digest = std.hash.Fnv1a_64.hash(table_name);
    return std.fmt.allocPrint(allocator, "{s}_{x:0>16}.qail", .{ safe_name, digest });
}

fn addUniqueName(allocator: Allocator, set: *NameSet, value: []const u8) !bool {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    const gop = try set.getOrPut(owned);
    if (gop.found_existing) {
        allocator.free(owned);
        return false;
    }
    gop.value_ptr.* = {};
    return true;
}

fn freeNameSet(allocator: Allocator, set: *NameSet) void {
    var it = set.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
}

fn collectModuleFiles(
    allocator: Allocator,
    dir_path: []const u8,
    out: *OrderedModuleList,
    names_set: *NameSet,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io_compat.runtimeIo(), dir_path, .{ .iterate = true });
    defer dir.close(io_compat.runtimeIo());

    var iter = dir.iterate();
    while (try iter.next(io_compat.runtimeIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!isSchemaModuleFile(entry.name)) continue;
        const full = try appendPath(allocator, dir_path, entry.name);
        if (try addUniqueName(allocator, names_set, entry.name)) {
            try out.files.append(allocator, full);
        } else {
            allocator.free(full);
        }
    }
}

fn sortModulePaths(list: *OrderedModuleList) void {
    std.sort.block([]u8, list.files.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

fn readOrderedModules(
    allocator: Allocator,
    dir_path: []const u8,
    out: *OrderedModuleList,
    names_set: *NameSet,
) !void {
    const order_path = try appendPath(allocator, dir_path, ORDER_FILE);
    defer allocator.free(order_path);
    if (!pathExists(order_path)) return;

    const content = try readFileAlloc(allocator, order_path, MAX_ORDER_FILE_BYTES);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = trimLine(line_raw);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "--")) continue;

        if (!isSchemaModuleFile(line)) continue;
        const full = try appendPath(allocator, dir_path, line);
        if (!pathExists(full)) {
            allocator.free(full);
            return error.UnresolvedSchemaModule;
        }
        if (try addUniqueName(allocator, names_set, line)) {
            try out.files.append(allocator, full);
        } else {
            allocator.free(full);
        }
    }
}

fn orderedModuleFiles(allocator: Allocator, dir_path: []const u8) !OrderedModuleList {
    var out = OrderedModuleList.init(allocator);
    errdefer out.deinit(allocator);

    var names_set = NameSet.init(allocator);
    defer freeNameSet(allocator, &names_set);

    try readOrderedModules(allocator, dir_path, &out, &names_set);
    try collectModuleFiles(allocator, dir_path, &out, &names_set);
    sortModulePaths(&out);
    return out;
}

fn writePolicyExpr(writer: anytype, expr: anytype) !void {
    var owned = expr;
    try render.writeExpr(writer, &owned);
}

fn renderTable(writer: anytype, table: *const parser.TableDef) !void {
    try writer.print("table {s} (\n", .{table.name});
    for (table.columns.items) |col| {
        try writer.print("  {s} {s}", .{ col.name, col.typ });
        if (col.type_params) |params| {
            try writer.print("({s})", .{params});
        }
        if (col.is_array) try writer.writeAll("[]");
        if (col.primary_key) try writer.writeAll(" primary_key");
        if (!col.nullable and !col.primary_key and !col.is_serial) try writer.writeAll(" not null");
        if (col.unique and !col.primary_key) try writer.writeAll(" unique");
        if (col.default_value) |default_value| {
            try writer.print(" default {s}", .{default_value});
        }
        if (col.references) |refs| {
            try writer.print(" references {s}", .{refs});
        }
        if (col.check) |check_expr| {
            try writer.print(" check ({s})", .{check_expr});
        }
        for (col.extra_checks) |check_expr| {
            try writer.print(" check ({s})", .{check_expr});
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll(")\n\n");
}

fn renderPolicy(writer: anytype, policy: *const parser.PolicyDef) !void {
    try writer.print("policy {s} on {s}", .{ policy.name, policy.table });
    if (policy.permissiveness == .restrictive) try writer.writeAll(" restrictive");
    try writer.writeAll(" for ");
    // Policy target keyword
    switch (policy.target) {
        .all => try writer.writeAll("all"),
        .select => try writer.writeAll("select"),
        .insert => try writer.writeAll("insert"),
        .update => try writer.writeAll("update"),
        .delete => try writer.writeAll("delete"),
    }
    if (policy.role) |role| try writer.print(" to {s}", .{role});
    if (policy.using_expr) |using_expr| {
        try writer.writeAll(" using (");
        try writePolicyExpr(writer, using_expr);
        try writer.writeAll(")");
    }
    if (policy.with_check_expr) |with_check_expr| {
        try writer.writeAll(" with_check (");
        try writePolicyExpr(writer, with_check_expr);
        try writer.writeAll(")");
    }
    try writer.writeAll("\n");
}

fn renderGrant(writer: anytype, grant: *const parser.GrantDef) !void {
    switch (grant.action) {
        .grant => try writer.writeAll("grant "),
        .revoke => try writer.writeAll("revoke "),
    }
    for (grant.privileges, 0..) |privilege, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(privilege);
    }
    switch (grant.action) {
        .grant => try writer.print(" on {s} to {s}\n", .{ grant.on_object, grant.role }),
        .revoke => try writer.print(" on {s} from {s}\n", .{ grant.on_object, grant.role }),
    }
}

fn renderSchemaText(allocator: Allocator, schema: *const parser.Schema) ![]u8 {
    var buf = io_compat.AllocatingWriter.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    for (schema.tables.items) |*table| {
        try renderTable(writer, table);
    }

    for (schema.policies.items) |*policy| {
        try renderPolicy(writer, policy);
    }
    if (schema.policies.items.len > 0) try writer.writeAll("\n");

    for (schema.grants.items) |*grant| {
        try renderGrant(writer, grant);
    }

    return try buf.toOwnedSlice();
}

fn parseSchemaFile(allocator: Allocator, path: []const u8) !parser.Schema {
    const content = try readFileAlloc(allocator, path, MAX_SCHEMA_FILE_BYTES);
    defer allocator.free(content);
    return parser.Schema.parse(allocator, content);
}

fn schemaContainsTable(schema: *const parser.Schema, table_name: []const u8) bool {
    for (schema.tables.items) |table| {
        if (std.mem.eql(u8, table.name, table_name)) return true;
    }
    return false;
}

pub fn doctorSchema(allocator: Allocator, schema_source: []const u8, strict: bool) !void {
    const source = try resolveSchemaSource(schema_source);

    var warnings: usize = 0;
    var errors: usize = 0;
    var module_count: usize = 0;

    print("Schema Doctor\n", .{});
    print("  Source: {s}\n", .{schema_source});

    switch (source) {
        .file => |file_path| {
            var schema = parseSchemaFile(allocator, file_path) catch |err| {
                print("  [error] Failed to parse schema: {}\n", .{err});
                return err;
            };
            defer schema.deinit();
            module_count = 1;

            if (schema.tables.items.len == 0) {
                warnings += 1;
                print("  [warn] Schema has no tables\n", .{});
            }
        },
        .directory => |dir_path| {
            var modules = try orderedModuleFiles(allocator, dir_path);
            defer modules.deinit(allocator);
            module_count = modules.files.items.len;
            if (module_count == 0) {
                errors += 1;
                print("  [error] No .qail modules found\n", .{});
            }

            var table_to_module = std.StringHashMap([]const u8).init(allocator);
            defer {
                var it = table_to_module.iterator();
                while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                table_to_module.deinit();
            }

            for (modules.files.items) |module_path| {
                var schema = parseSchemaFile(allocator, module_path) catch |err| {
                    errors += 1;
                    print("  [error] Failed to parse {s}: {}\n", .{ module_path, err });
                    continue;
                };
                defer schema.deinit();

                if (schema.tables.items.len == 0 and schema.policies.items.len == 0 and schema.grants.items.len == 0) {
                    warnings += 1;
                    print("  [warn] Empty module: {s}\n", .{module_path});
                }

                for (schema.tables.items) |table| {
                    const table_name = try allocator.dupe(u8, table.name);
                    errdefer allocator.free(table_name);
                    const gop = try table_to_module.getOrPut(table_name);
                    if (gop.found_existing) {
                        allocator.free(table_name);
                        errors += 1;
                        print("  [error] Duplicate table '{s}' in {s} and {s}\n", .{
                            table.name,
                            gop.value_ptr.*,
                            module_path,
                        });
                    } else {
                        gop.value_ptr.* = module_path;
                    }
                }
            }
        },
    }

    print("  Modules: {d}\n", .{module_count});
    if (errors == 0 and warnings == 0) {
        print("  ✓ No issues found\n", .{});
        return;
    }
    print("  Summary: {d} error(s), {d} warning(s)\n", .{ errors, warnings });
    if (errors > 0) return error.SchemaDoctorFailed;
    if (strict and warnings > 0) return error.SchemaDoctorWarnings;
}

fn ensureDirReady(path: []const u8, force: bool) !void {
    const io_iface = io_compat.runtimeIo();
    const stat = std.Io.Dir.cwd().statFile(io_iface, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.cwd().createDirPath(io_iface, path);
            return;
        },
        else => return err,
    };

    if (stat.kind != .directory) return error.OutputPathNotDirectory;

    var dir = try std.Io.Dir.cwd().openDir(io_iface, path, .{ .iterate = true });
    defer dir.close(io_iface);
    var iter = dir.iterate();
    const maybe_entry = try iter.next(io_iface);
    if (maybe_entry != null and !force) return error.OutputDirNotEmpty;
}

fn writeModuleOrder(allocator: Allocator, out_dir: []const u8, module_names: []const []const u8) !void {
    var buf = io_compat.AllocatingWriter.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try writer.writeAll("# QAIL module order\n");
    for (module_names) |name| {
        try writer.writeAll(name);
        try writer.writeAll("\n");
    }
    const order_text = try buf.toOwnedSlice();
    defer allocator.free(order_text);
    const order_path = try appendPath(allocator, out_dir, ORDER_FILE);
    defer allocator.free(order_path);
    try writeFileAll(order_path, order_text);
}

pub fn splitSchema(allocator: Allocator, input: []const u8, out_dir: []const u8, force: bool) !void {
    var schema = try parseSchemaFile(allocator, input);
    defer schema.deinit();

    try ensureDirReady(out_dir, force);

    var module_names = std.ArrayList([]const u8).initCapacity(allocator, schema.tables.items.len + 1) catch unreachable;
    defer {
        for (module_names.items) |name| allocator.free(name);
        module_names.deinit(allocator);
    }

    for (schema.tables.items) |*table| {
        const file_name = try schemaModuleFilename(allocator, table.name);
        defer allocator.free(file_name);
        const file_path = try appendPath(allocator, out_dir, file_name);
        defer allocator.free(file_path);

        // Render one table + attached policies/grants without mutating original schema.
        var buf = io_compat.AllocatingWriter.init(allocator);
        defer buf.deinit();
        const writer = buf.writer();
        try renderTable(writer, table);
        for (schema.policies.items) |*policy| {
            if (std.mem.eql(u8, policy.table, table.name)) try renderPolicy(writer, policy);
        }
        for (schema.grants.items) |*grant| {
            if (std.mem.eql(u8, grant.on_object, table.name)) try renderGrant(writer, grant);
        }
        const text = try buf.toOwnedSlice();
        defer allocator.free(text);
        try writeFileAll(file_path, text);
        try module_names.append(allocator, try allocator.dupe(u8, file_name));
    }

    // Write non-table grants/policies to globals.qail.
    var globals_buf = io_compat.AllocatingWriter.init(allocator);
    defer globals_buf.deinit();
    const globals_writer = globals_buf.writer();
    var wrote_globals = false;
    for (schema.policies.items) |*policy| {
        if (!schemaContainsTable(&schema, policy.table)) {
            try renderPolicy(globals_writer, policy);
            wrote_globals = true;
        }
    }
    for (schema.grants.items) |*grant| {
        if (!schemaContainsTable(&schema, grant.on_object)) {
            try renderGrant(globals_writer, grant);
            wrote_globals = true;
        }
    }
    if (wrote_globals) {
        const globals_text = try globals_buf.toOwnedSlice();
        defer allocator.free(globals_text);
        const globals_name = "globals.qail";
        const globals_path = try appendPath(allocator, out_dir, globals_name);
        defer allocator.free(globals_path);
        try writeFileAll(globals_path, globals_text);
        try module_names.append(allocator, try allocator.dupe(u8, globals_name));
    }

    try writeModuleOrder(allocator, out_dir, module_names.items);
    print("✓ split '{s}' -> '{s}' ({d} module(s))\n", .{ input, out_dir, module_names.items.len });
}

pub fn mergeSchema(allocator: Allocator, input: []const u8, output: []const u8) !void {
    const source = try resolveSchemaSource(input);

    var out_buf = io_compat.AllocatingWriter.init(allocator);
    defer out_buf.deinit();
    const writer = out_buf.writer();

    switch (source) {
        .file => |file_path| {
            var schema = try parseSchemaFile(allocator, file_path);
            defer schema.deinit();
            const rendered = try renderSchemaText(allocator, &schema);
            defer allocator.free(rendered);
            try writer.writeAll(rendered);
        },
        .directory => |dir_path| {
            var modules = try orderedModuleFiles(allocator, dir_path);
            defer modules.deinit(allocator);
            for (modules.files.items, 0..) |module_path, i| {
                var schema = try parseSchemaFile(allocator, module_path);
                defer schema.deinit();
                const rendered = try renderSchemaText(allocator, &schema);
                defer allocator.free(rendered);
                if (i > 0 and rendered.len > 0) try writer.writeAll("\n");
                try writer.writeAll(rendered);
            }
        },
    }

    const merged = try out_buf.toOwnedSlice();
    defer allocator.free(merged);
    try writeFileAll(output, merged);
    print("✓ merged '{s}' -> '{s}'\n", .{ input, output });
}

pub fn make(comptime Cli: type) type {
    const SchemaAction = Cli.SchemaAction;

    return struct {
        pub fn runSchema(allocator: Allocator, action: SchemaAction) !void {
            switch (action) {
                .doctor => |d| try doctorSchema(allocator, d.schema, d.strict),
                .split => |s| try splitSchema(allocator, s.input, s.out, s.force),
                .merge => |m| try mergeSchema(allocator, m.input, m.output),
            }
        }
    };
}

test "schema module filenames preserve common table names" {
    const allocator = std.testing.allocator;

    const users = try schemaModuleFilename(allocator, "users");
    defer allocator.free(users);
    try std.testing.expectEqualStrings("users.qail", users);

    const qualified = try schemaModuleFilename(allocator, "public.users");
    defer allocator.free(qualified);
    try std.testing.expectEqualStrings("public.users.qail", qualified);

    const tenant_users = try schemaModuleFilename(allocator, "tenant_users");
    defer allocator.free(tenant_users);
    try std.testing.expectEqualStrings("tenant_users.qail", tenant_users);
}

test "schema module filenames sanitize path-like names" {
    const allocator = std.testing.allocator;

    const filename = try schemaModuleFilename(allocator, "../../tenant/users\n");
    defer allocator.free(filename);

    try std.testing.expect(std.mem.startsWith(u8, filename, "tenant_users_"));
    try std.testing.expect(std.mem.endsWith(u8, filename, ".qail"));
    try std.testing.expect(std.mem.indexOfScalar(u8, filename, '/') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, filename, '\\') == null);
    try std.testing.expect(std.mem.indexOf(u8, filename, "..") == null);
}

test "schema module filenames hash sanitized collisions" {
    const allocator = std.testing.allocator;

    const slash_name = try schemaModuleFilename(allocator, "tenant/users");
    defer allocator.free(slash_name);
    const question_name = try schemaModuleFilename(allocator, "tenant?users");
    defer allocator.free(question_name);

    try std.testing.expect(!std.mem.eql(u8, slash_name, question_name));
    try std.testing.expect(std.mem.startsWith(u8, slash_name, "tenant_users_"));
    try std.testing.expect(std.mem.startsWith(u8, question_name, "tenant_users_"));
}

test "schema filename component fails closed for empty names" {
    const allocator = std.testing.allocator;

    const dots = try filenameComponent(allocator, "...");
    defer allocator.free(dots);
    try std.testing.expectEqualStrings("unnamed", dots);

    const whitespace = try filenameComponent(allocator, " \n\t ");
    defer allocator.free(whitespace);
    try std.testing.expectEqualStrings("unnamed", whitespace);
}
