// QAIL CLI - Zig Edition
//
// A blazing fast CLI for parsing and transpiling QAIL queries.
//
// Usage:
//   qail <QUERY>                  Parse and transpile a query
//   qail repl                     Interactive REPL mode
//   qail explain <QUERY>          Parse and explain a query
//   qail symbols                  Show symbol reference
//   qail fmt <QUERY>              Format to canonical syntax
//   qail migrate status <URL>     Show migration status

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const QailCmd = @import("../ast/cmd.zig").QailCmd;
const schema_cli = @import("schema.zig");
const schema_tools_cli = @import("schema_tools.zig").make(@This());
const commands = @import("commands.zig").make(@This());
const migrate_support = @import("migrate_support.zig").make(@This());
const migrate = @import("migrate.zig").make(@This());
const parse_cli = @import("parse.zig").make(@This());
const lock_cli = @import("lock.zig").make(@This());
const help_cli = @import("help.zig");
const project_cli = @import("project.zig");
const branch_cli = @import("branch.zig").make(@This());
const sync_cli = @import("sync.zig").make(@This());
const vector_cli = @import("vector.zig").make(@This());
const worker_cli = @import("worker.zig").make(@This());

comptime {
    if (builtin.is_test) {
        _ = @import("tests.zig").make(@This());
    }
}

pub const ExecCmd = struct {
    query: ?[]const u8 = null,
    file: ?[]const u8 = null,
    url: ?[]const u8 = null,
    tx: bool = false,
    dry_run: bool = false,
    json: bool = false,
};

pub const SeedCmd = struct {
    file: []const u8 = "seed.qail",
    url: ?[]const u8 = null,
    tx: bool = false,
    dry_run: bool = false,
};

pub const WorkerCmd = struct {
    interval_ms: u64 = 1000,
    batch_size: u32 = 100,
};

pub const Command = union(enum) {
    // Simple transpile
    transpile: struct {
        query: []const u8,
        format: OutputFormat = .sql,
        dialect: Dialect = .postgres,
        verbose: bool = false,
    },
    // Subcommands
    init: []const u8, // target directory
    repl,
    explain: []const u8,
    symbols,
    fmt: []const u8,
    exec: ExecCmd,
    seed: SeedCmd,
    types: []const u8, // schema path
    pull: []const u8, // URL
    check: []const u8, // schema file
    diff: struct {
        old: []const u8,
        new: []const u8,
        format: OutputFormat = .sql,
    },
    lint: struct {
        schema: []const u8,
        strict: bool = false,
    },
    watch: struct {
        schema: []const u8,
        url: ?[]const u8 = null,
        auto_apply: bool = false,
    },
    branch: BranchAction,
    schema: SchemaAction,
    sync: SyncAction,
    vector: VectorAction,
    worker: WorkerCmd,
    migrate: MigrateAction,
    migrate_help,
    branch_help,
    schema_help,
    sync_help,
    vector_help,
    help,
    version,
};

pub const BranchAction = union(enum) {
    create: struct {
        name: []const u8,
        parent: ?[]const u8 = null,
        url: ?[]const u8 = null,
    },
    list: struct {
        url: ?[]const u8 = null,
    },
    delete: struct {
        name: []const u8,
        url: ?[]const u8 = null,
    },
    merge: struct {
        name: []const u8,
        url: ?[]const u8 = null,
    },
};

pub const SchemaAction = union(enum) {
    doctor: struct {
        schema: []const u8 = "schema.qail",
        strict: bool = false,
    },
    split: struct {
        input: []const u8 = "schema.qail",
        out: []const u8 = "schema",
        force: bool = false,
    },
    merge: struct {
        input: []const u8 = "schema",
        output: []const u8 = "schema.qail",
    },
};

pub const SyncAction = enum {
    generate,
    list,
};

pub const VectorAction = union(enum) {
    create: struct {
        collection: []const u8,
        size: u64,
        distance: []const u8 = "cosine",
        url: []const u8,
    },
    drop: struct {
        collection: []const u8,
        url: []const u8,
    },
    backup: struct {
        collection: []const u8,
        output: ?[]const u8 = null,
        url: []const u8,
    },
    restore: struct {
        collection: []const u8,
        snapshot: []const u8,
        url: []const u8,
    },
    snapshots: struct {
        collection: []const u8,
        url: []const u8,
    },
};

pub const MigrateAction = union(enum) {
    status: []const u8, // URL
    analyze: struct {
        schema_diff: []const u8,
        codebase: []const u8 = "./src",
        ci: bool = false,
        json: bool = false,
    },
    plan: struct {
        schema_diff: []const u8,
        output: ?[]const u8 = null,
    },
    up: struct {
        schema_diff: []const u8,
        url: []const u8,
        codebase: ?[]const u8 = null,
        force: bool = false,
        allow_destructive: bool = false,
        allow_no_shadow_receipt: bool = false,
        allow_lock_risk: bool = false,
        wait_for_lock: bool = false,
        lock_timeout_secs: ?u64 = null,
    },
    down: struct {
        schema_diff: []const u8,
        url: []const u8,
        force: bool = false,
        wait_for_lock: bool = false,
        lock_timeout_secs: ?u64 = null,
    },
    apply: struct {
        url: []const u8,
        direction: MigrationDirection = .up,
        phase: ApplyPhase = .all,
        codebase: ?[]const u8 = null,
        allow_contract_with_references: bool = false,
        allow_destructive: bool = false,
        allow_no_shadow_receipt: bool = false,
        allow_lock_risk: bool = false,
        adopt_existing: bool = false,
        backfill_chunk_size: usize = 5000,
        wait_for_lock: bool = false,
        lock_timeout_secs: ?u64 = null,
    },
    rollback: struct {
        schema_diff: ?[]const u8 = null,
        to: ?[]const u8 = null,
        url: []const u8,
        wait_for_lock: bool = false,
        lock_timeout_secs: ?u64 = null,
    },
    reset: struct {
        schema: []const u8,
        url: []const u8,
        wait_for_lock: bool = false,
        lock_timeout_secs: ?u64 = null,
    },
    create: struct {
        name: []const u8,
        depends: ?[]const u8 = null,
        author: ?[]const u8 = null,
    },
    shadow: struct {
        schema_diff: []const u8,
        url: []const u8,
        live: bool = false,
    },
    promote: []const u8, // URL
    abort: []const u8, // URL
};

pub const MigrationDirection = enum {
    up,
    down,
};

pub const ApplyPhase = enum {
    all,
    expand,
    backfill,
    contract,
};

pub const OutputFormat = enum {
    sql,
    json,
    pretty,
};

pub const Dialect = enum {
    postgres,
    sqlite,
};

/// Parse CLI arguments into a Command
pub fn parse(allocator: Allocator, args: []const []const u8) !Command {
    return parse_cli.parse(allocator, args);
}

pub fn resolveDatabaseUrl(url: []const u8) ![]const u8 {
    return lock_cli.resolveDatabaseUrl(url);
}

const MIGRATION_LOCK_OBJECT_SEED: i32 = lock_cli.MIGRATION_LOCK_OBJECT_SEED;

fn scopedMigrationLockObjectId(scope: ?[]const u8) i32 {
    return lock_cli.scopedMigrationLockObjectId(scope);
}

fn migrationLockObjectIdForUrl(allocator: Allocator, url: []const u8) i32 {
    return lock_cli.migrationLockObjectIdForUrl(allocator, url);
}

pub fn acquireMigrationLock(
    allocator: Allocator,
    pg: *@import("../driver/driver.zig").PgDriver,
    operation: []const u8,
    url: []const u8,
    wait_for_lock: bool,
    lock_timeout_secs: ?u64,
) !void {
    return lock_cli.acquireMigrationLock(allocator, pg, operation, url, wait_for_lock, lock_timeout_secs);
}

// ==================== Command Handlers ====================

pub fn run(allocator: Allocator, cmd: Command) !void {
    switch (cmd) {
        .transpile => |t| try commands.transpile(allocator, t.query, t.dialect, t.format, t.verbose),
        .init => |target| try project_cli.initProject(allocator, target),
        .repl => try commands.runRepl(allocator),
        .explain => |query| try commands.explainQuery(allocator, query),
        .symbols => commands.showSymbols(),
        .fmt => |query| try commands.formatQuery(allocator, query),
        .exec => |e| try commands.runExec(allocator, e),
        .seed => |s| try commands.runSeed(allocator, s),
        .types => |schema_path| try commands.generateTypes(allocator, schema_path),
        .pull => |url| try schema_cli.pullSchema(allocator, url),
        .check => |schema| try schema_cli.checkSchema(allocator, schema),
        .diff => |d| try schema_cli.diffSchemas(allocator, d.old, d.new, @tagName(d.format)),
        .lint => |l| try schema_cli.lintSchema(allocator, l.schema, l.strict),
        .watch => |w| try schema_cli.watchSchema(allocator, w.schema, w.url, w.auto_apply),
        .branch => |b| try branch_cli.runBranch(allocator, b),
        .schema => |s| try schema_tools_cli.runSchema(allocator, s),
        .sync => |s| try sync_cli.runSync(allocator, s),
        .vector => |v| try vector_cli.runVector(allocator, v),
        .worker => |w| try worker_cli.runWorker(allocator, w),
        .migrate => |m| try migrate.runMigrate(allocator, m),
        .migrate_help => help_cli.showMigrateHelp(),
        .branch_help => help_cli.showBranchHelp(),
        .schema_help => help_cli.showSchemaHelp(),
        .sync_help => help_cli.showSyncHelp(),
        .vector_help => help_cli.showVectorHelp(),
        .help => help_cli.showHelp(),
        .version => help_cli.showVersion(),
    }
}

pub fn freeParsedCmd(allocator: Allocator, cmd: *const QailCmd) void {
    @import("../parser/mod.zig").deinitParsedCommand(allocator, cmd);
}

pub fn deinitFetchedRows(allocator: Allocator, rows: []@import("../driver/row.zig").PgRow) void {
    for (rows) |*row| {
        var owned = row.*;
        owned.deinit();
    }
    allocator.free(rows);
}

pub fn connectPgUrl(
    allocator: Allocator,
    url: []const u8,
) !@import("../driver/driver.zig").PgDriver {
    const driver_mod = @import("../driver/mod.zig");
    return try driver_mod.driver.PgDriver.connectUrl(allocator, url);
}

test "normalizePostgresType maps serial defaults" {
    const normalized = schema_cli.normalizePostgresType("int4", "integer", "nextval('users_id_seq'::regclass)");
    try std.testing.expectEqualStrings("serial", normalized.typ);
    try std.testing.expect(!normalized.is_array);
    try std.testing.expect(normalized.suppress_default);
}

test "normalizePostgresType maps arrays and preserves base type" {
    const normalized = schema_cli.normalizePostgresType("_text", "ARRAY", null);
    try std.testing.expectEqualStrings("text", normalized.typ);
    try std.testing.expect(normalized.is_array);
    try std.testing.expect(!normalized.suppress_default);
}

test "normalizePostgresType maps primitive aliases" {
    const normalized = schema_cli.normalizePostgresType("float8", "double precision", null);
    try std.testing.expectEqualStrings("f64", normalized.typ);
    try std.testing.expect(!normalized.is_array);
    try std.testing.expect(!normalized.suppress_default);
}

test "rewriteDatabaseInUrl replaces path database" {
    const allocator = std.testing.allocator;
    const rewritten = try migrate_support.rewriteDatabaseInUrl(allocator, "postgres://alice@localhost:5432/main", "postgres");
    defer allocator.free(rewritten);
    try std.testing.expectEqualStrings("postgres://alice@localhost:5432/postgres", rewritten);
}

test "rewriteDatabaseInUrl preserves query string" {
    const allocator = std.testing.allocator;
    const rewritten = try migrate_support.rewriteDatabaseInUrl(
        allocator,
        "postgres://alice@localhost:5432/main?sslmode=require&connect_timeout=5",
        "shadow_db",
    );
    defer allocator.free(rewritten);
    try std.testing.expectEqualStrings(
        "postgres://alice@localhost:5432/shadow_db?sslmode=require&connect_timeout=5",
        rewritten,
    );
}

test "scopedMigrationLockObjectId is stable and scoped" {
    const users_db = scopedMigrationLockObjectId("users_db");
    const inventory_db = scopedMigrationLockObjectId("inventory_db");
    try std.testing.expectEqual(users_db, scopedMigrationLockObjectId("users_db"));
    try std.testing.expectEqual(users_db, scopedMigrationLockObjectId("USERS_DB"));
    try std.testing.expect(users_db != inventory_db);
    try std.testing.expectEqual(MIGRATION_LOCK_OBJECT_SEED, scopedMigrationLockObjectId(""));
    try std.testing.expectEqual(MIGRATION_LOCK_OBJECT_SEED, scopedMigrationLockObjectId(null));
}

test "migrationLockObjectIdForUrl uses parsed database scope" {
    const allocator = std.testing.allocator;
    const main_id = migrationLockObjectIdForUrl(allocator, "postgres://alice@localhost:5432/main");
    const main_again = migrationLockObjectIdForUrl(allocator, "postgres://alice@localhost:5432/main?sslmode=require");
    const shadow_id = migrationLockObjectIdForUrl(allocator, "postgres://alice@localhost:5432/main_shadow");
    try std.testing.expectEqual(main_id, main_again);
    try std.testing.expect(main_id != shadow_id);
}

test "slugifyMigrationName normalizes separators" {
    const allocator = std.testing.allocator;
    const slug = try migrate_support.slugifyMigrationName(allocator, "Add Users.Table-1");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("add_users_table_1", slug);
}

test "slugifyMigrationName falls back when empty" {
    const allocator = std.testing.allocator;
    const slug = try migrate_support.slugifyMigrationName(allocator, " - . ");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("migration", slug);
}
