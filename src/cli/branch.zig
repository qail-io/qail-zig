//! Branch management CLI module.
//!
//! Provides real `branch create|list|delete|merge` behavior on PostgreSQL
//! using the existing AST-native `PgDriver` path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("../runtime/process.zig");
const io_compat = @import("../runtime/io.zig");
const ast = @import("../ast/mod.zig");
const PgDriver = @import("../driver/mod.zig").driver.PgDriver;

const QailCmd = ast.QailCmd;
const Expr = ast.Expr;
const Assignment = ast.Assignment;
const WhereClause = ast.WhereClause;
const OrderBy = ast.OrderBy;
const Value = ast.Value;
const print = std.debug.print;

const BRANCH_TABLE = "_qail_branches";
const BRANCH_ROWS_TABLE = "_qail_branch_rows";
const BRANCH_NAME_MAX = 64;

const ResolvedUrl = struct {
    value: []const u8,
    owned: bool,
};

fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io_compat.runtimeIo(),
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn connectPgUrl(allocator: Allocator, url: []const u8) !PgDriver {
    return try PgDriver.connectUrl(allocator, url);
}

fn deinitFetchedRows(allocator: Allocator, rows: []@import("../driver/row.zig").PgRow) void {
    for (rows) |*row| {
        var owned = row.*;
        owned.deinit();
    }
    allocator.free(rows);
}

fn isValidBranchName(name: []const u8) bool {
    if (name.len == 0 or name.len > BRANCH_NAME_MAX) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    }
    return true;
}

fn validateBranchName(name: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(name, "main")) return error.InvalidBranchName;
    if (!isValidBranchName(name)) return error.InvalidBranchName;
}

fn nowTextAlloc(allocator: Allocator) ![]u8 {
    const millis = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds();
    return try std.fmt.allocPrint(allocator, "{d}", .{millis});
}

fn resolveUrlFromQailToml(allocator: Allocator) ?[]u8 {
    const content = readFileAlloc(allocator, "qail.toml", 1024 * 1024) catch return null;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "url")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const rhs = std.mem.trim(u8, line[(eq + 1)..], " \t\r\n");
        const value = std.mem.trim(u8, rhs, "\"'");
        if (std.mem.startsWith(u8, value, "postgres://") or std.mem.startsWith(u8, value, "postgresql://")) {
            return allocator.dupe(u8, value) catch null;
        }
    }
    return null;
}

fn resolveDbUrl(allocator: Allocator, provided: ?[]const u8) !ResolvedUrl {
    if (provided) |url| {
        const trimmed = std.mem.trim(u8, url, " \t\r\n");
        if (trimmed.len > 0) return .{ .value = trimmed, .owned = false };
    }

    if (process.getEnvVarOwned(allocator, "QAIL_DATABASE_URL")) |url| return .{ .value = url, .owned = true } else |_| {}
    if (process.getEnvVarOwned(allocator, "DATABASE_URL")) |url| return .{ .value = url, .owned = true } else |_| {}
    if (resolveUrlFromQailToml(allocator)) |url| return .{ .value = url, .owned = true };
    return error.MissingArgument;
}

fn ensureBranchTables(allocator: Allocator, pg: *PgDriver) !void {
    const branch_cols = [_]Expr{
        .{ .column_def = .{ .name = "id", .data_type = "text", .is_primary_key = true } },
        .{ .column_def = .{ .name = "name", .data_type = "text", .is_not_null = true, .is_unique = true } },
        .{ .column_def = .{ .name = "parent_branch_id", .data_type = "text" } },
        .{ .column_def = .{ .name = "created_at", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "merged_at", .data_type = "text" } },
        .{ .column_def = .{ .name = "status", .data_type = "text", .is_not_null = true } },
    };
    const create_branch_table = QailCmd.make(BRANCH_TABLE).select(&branch_cols);
    _ = try pg.execute(&create_branch_table);

    const row_cols = [_]Expr{
        .{ .column_def = .{ .name = "id", .data_type = "text", .is_primary_key = true } },
        .{ .column_def = .{ .name = "branch_id", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "table_name", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "row_pk", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "operation", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "row_data", .data_type = "jsonb" } },
        .{ .column_def = .{ .name = "created_at", .data_type = "text", .is_not_null = true } },
    };
    const create_rows_table = QailCmd.make(BRANCH_ROWS_TABLE).select(&row_cols);
    _ = try pg.execute(&create_rows_table);

    const idx_lookup_cols = [_][]const u8{ "branch_id", "table_name", "row_pk" };
    var idx_lookup = QailCmd.createIndex(BRANCH_ROWS_TABLE);
    idx_lookup.index_def = .{
        .name = "idx_branch_rows_lookup",
        .table = BRANCH_ROWS_TABLE,
        .columns = &idx_lookup_cols,
    };
    _ = pg.execute(&idx_lookup) catch {};

    const idx_branch_cols = [_][]const u8{"branch_id"};
    var idx_branch = QailCmd.createIndex(BRANCH_ROWS_TABLE);
    idx_branch.index_def = .{
        .name = "idx_branch_rows_branch",
        .table = BRANCH_ROWS_TABLE,
        .columns = &idx_branch_cols,
    };
    _ = pg.execute(&idx_branch) catch {};

    _ = allocator;
}

fn branchExists(allocator: Allocator, pg: *PgDriver, name: []const u8) !bool {
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "name", .op = .eq, .value = .{ .string = name } } },
    };
    const rows = try pg.fetchAll(&QailCmd.get(BRANCH_TABLE).select(&.{Expr.col("id")}).where(&where).limit(1));
    defer deinitFetchedRows(allocator, rows);
    return rows.len > 0;
}

fn findActiveBranchId(allocator: Allocator, pg: *PgDriver, name: []const u8) !?[]u8 {
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "name", .op = .eq, .value = .{ .string = name } } },
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } } },
    };
    const rows = try pg.fetchAll(&QailCmd.get(BRANCH_TABLE).select(&.{Expr.col("id")}).where(&where).limit(1));
    defer deinitFetchedRows(allocator, rows);
    if (rows.len == 0) return null;
    const id = rows[0].getByName("id") orelse return null;
    const owned = try allocator.dupe(u8, id);
    return owned;
}

fn branchCreate(allocator: Allocator, name: []const u8, parent: ?[]const u8, url: ?[]const u8) !void {
    try validateBranchName(name);
    if (parent) |p| {
        if (!std.ascii.eqlIgnoreCase(p, "main")) {
            try validateBranchName(p);
            if (std.mem.eql(u8, p, name)) return error.InvalidBranchParent;
        }
    }

    const resolved = try resolveDbUrl(allocator, url);
    defer if (resolved.owned) allocator.free(resolved.value);

    var pg = try connectPgUrl(allocator, resolved.value);
    defer pg.deinit();
    try ensureBranchTables(allocator, &pg);

    if (try branchExists(allocator, &pg, name)) return error.BranchAlreadyExists;

    var parent_id: ?[]u8 = null;
    defer if (parent_id) |id| allocator.free(id);
    if (parent) |p| {
        if (!std.ascii.eqlIgnoreCase(p, "main")) {
            parent_id = try findActiveBranchId(allocator, &pg, p);
            if (parent_id == null) return error.ParentBranchNotFound;
        }
    }

    const ts = try nowTextAlloc(allocator);
    defer allocator.free(ts);
    const id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, ts });
    defer allocator.free(id);

    const assigns = [_]Assignment{
        .{ .column = "id", .value = .{ .string = id } },
        .{ .column = "name", .value = .{ .string = name } },
        .{ .column = "parent_branch_id", .value = if (parent_id) |pid| Value{ .string = pid } else Value.null },
        .{ .column = "created_at", .value = .{ .string = ts } },
        .{ .column = "status", .value = .{ .string = "active" } },
    };
    const cmd = QailCmd.add(BRANCH_TABLE).values(&assigns);
    _ = try pg.execute(&cmd);

    print("✅ Branch '{s}' created\n", .{name});
    if (parent) |p| if (!std.ascii.eqlIgnoreCase(p, "main")) print("   Parent: {s}\n", .{p});
}

fn branchList(allocator: Allocator, url: ?[]const u8) !void {
    const resolved = try resolveDbUrl(allocator, url);
    defer if (resolved.owned) allocator.free(resolved.value);

    var pg = try connectPgUrl(allocator, resolved.value);
    defer pg.deinit();
    try ensureBranchTables(allocator, &pg);

    const cols = [_]Expr{
        Expr.col("id"),
        Expr.col("name"),
        Expr.col("status"),
        Expr.col("created_at"),
    };
    const order = [_]OrderBy{
        .{ .column = "created_at", .order = .desc },
    };
    const rows = try pg.fetchAll(&QailCmd.get(BRANCH_TABLE).select(&cols).orderBy(&order));
    defer deinitFetchedRows(allocator, rows);

    if (rows.len == 0) {
        print("No branches found. Create one with: qail branch create <name>\n", .{});
        return;
    }

    print("{s:<36}  {s:<20}  {s:<10}  CREATED\n", .{ "ID", "NAME", "STATUS" });
    print("{s}\n", .{"--------------------------------------------------------------------------------"});
    for (rows) |row| {
        print("{s:<36}  {s:<20}  {s:<10}  {s}\n", .{
            row.getByName("id") orelse "",
            row.getByName("name") orelse "",
            row.getByName("status") orelse "",
            row.getByName("created_at") orelse "",
        });
    }
}

fn branchDelete(allocator: Allocator, name: []const u8, url: ?[]const u8) !void {
    try validateBranchName(name);
    const resolved = try resolveDbUrl(allocator, url);
    defer if (resolved.owned) allocator.free(resolved.value);

    var pg = try connectPgUrl(allocator, resolved.value);
    defer pg.deinit();
    try ensureBranchTables(allocator, &pg);

    const assigns = [_]Assignment{
        .{ .column = "status", .value = .{ .string = "deleted" } },
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "name", .op = .eq, .value = .{ .string = name } } },
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } } },
    };
    const cmd = QailCmd.set(BRANCH_TABLE).values(&assigns).where(&where);
    const affected = try pg.execute(&cmd);
    if (affected == 0) return error.BranchNotFound;
    print("🗑  Branch '{s}' deleted\n", .{name});
}

fn printBranchOverlayStats(
    allocator: Allocator,
    pg: *PgDriver,
    branch_name: []const u8,
    branch_id: []const u8,
) !void {
    const cols = [_]Expr{
        Expr.col("table_name"),
        Expr.col("operation"),
        Expr.count().withAlias("count"),
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "branch_id", .op = .eq, .value = .{ .string = branch_id } } },
    };
    const group = [_][]const u8{ "table_name", "operation" };
    const order = [_]OrderBy{
        .{ .column = "table_name", .order = .asc },
        .{ .column = "operation", .order = .asc },
    };

    const rows = try pg.fetchAll(&QailCmd.get(BRANCH_ROWS_TABLE)
        .select(&cols)
        .where(&where)
        .groupBy(&group)
        .orderBy(&order));
    defer deinitFetchedRows(allocator, rows);

    if (rows.len == 0) return;
    print("📊 Overlay stats for '{s}':\n", .{branch_name});
    for (rows) |row| {
        print("   {s} {s} -> {s} rows\n", .{
            row.getByName("table_name") orelse "",
            row.getByName("operation") orelse "",
            row.getByName("count") orelse row.getString(2) orelse "0",
        });
    }
}

fn branchMerge(allocator: Allocator, name: []const u8, url: ?[]const u8) !void {
    try validateBranchName(name);
    const resolved = try resolveDbUrl(allocator, url);
    defer if (resolved.owned) allocator.free(resolved.value);

    var pg = try connectPgUrl(allocator, resolved.value);
    defer pg.deinit();
    try ensureBranchTables(allocator, &pg);

    const branch_id = (try findActiveBranchId(allocator, &pg, name)) orelse return error.BranchNotFound;
    defer allocator.free(branch_id);
    _ = printBranchOverlayStats(allocator, &pg, name, branch_id) catch {};

    const merged_at = try nowTextAlloc(allocator);
    defer allocator.free(merged_at);
    const assigns = [_]Assignment{
        .{ .column = "status", .value = .{ .string = "merged" } },
        .{ .column = "merged_at", .value = .{ .string = merged_at } },
    };
    const where = [_]WhereClause{
        .{ .condition = .{ .column = "name", .op = .eq, .value = .{ .string = name } } },
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } } },
    };
    const cmd = QailCmd.set(BRANCH_TABLE).values(&assigns).where(&where);
    const affected = try pg.execute(&cmd);
    if (affected == 0) return error.BranchNotFound;
    print("✅ Branch '{s}' merged\n", .{name});
}

pub fn make(comptime Cli: type) type {
    const BranchAction = Cli.BranchAction;

    return struct {
        pub fn runBranch(allocator: Allocator, action: BranchAction) !void {
            switch (action) {
                .create => |c| try branchCreate(allocator, c.name, c.parent, c.url),
                .list => |l| try branchList(allocator, l.url),
                .delete => |d| try branchDelete(allocator, d.name, d.url),
                .merge => |m| try branchMerge(allocator, m.name, m.url),
            }
        }
    };
}

test "branch name validation" {
    try std.testing.expect(isValidBranchName("feature-auth"));
    try std.testing.expect(isValidBranchName("release_1.2"));
    try std.testing.expect(!isValidBranchName(""));
    try std.testing.expect(!isValidBranchName(".hidden"));
    try std.testing.expect(!isValidBranchName("-bad"));
    try std.testing.expect(!isValidBranchName("bad name"));
}
