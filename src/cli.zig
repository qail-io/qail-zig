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
const QailCmd = @import("ast/cmd.zig").QailCmd;
const Expr = @import("ast/expr.zig").Expr;
const io_compat = @import("runtime/io.zig");
const process_compat = @import("runtime/process.zig");
const schema_ops = @import("cli/schema_ops.zig");

comptime {
    if (builtin.is_test) {
        _ = @import("cli/tests.zig").make(@This());
    }
}

const print = std.debug.print;
const data_safety = @import("data_safety.zig");

const ExecCmd = struct {
    query: ?[]const u8 = null,
    file: ?[]const u8 = null,
    url: ?[]const u8 = null,
    tx: bool = false,
    dry_run: bool = false,
    json: bool = false,
};

const SeedCmd = struct {
    file: []const u8 = "seed.qail",
    url: ?[]const u8 = null,
    tx: bool = false,
    dry_run: bool = false,
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
    migrate: MigrateAction,
    migrate_help,
    help,
    version,
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

const GlobalOptions = struct {
    format: OutputFormat = .sql,
    dialect: Dialect = .postgres,
    verbose: bool = false,
};

fn parseOutputFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "sql")) return .sql;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "pretty")) return .pretty;
    return null;
}

fn parseDialect(value: []const u8) ?Dialect {
    if (std.mem.eql(u8, value, "postgres")) return .postgres;
    if (std.mem.eql(u8, value, "sqlite")) return .sqlite;
    return null;
}

/// Parse CLI arguments into a Command
pub fn parse(allocator: Allocator, args: []const []const u8) !Command {
    if (args.len < 2) {
        return .help;
    }

    var opts = GlobalOptions{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "-")) break;

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.format = parseOutputFormat(args[i]) orelse return error.InvalidArgument;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dialect") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.dialect = parseDialect(args[i]) orelse return error.InvalidArgument;
            continue;
        }

        return error.UnknownOption;
    }

    if (i >= args.len) {
        return .help;
    }

    const first = args[i];
    const rest = args[(i + 1)..];

    // Check for subcommands
    if (std.mem.eql(u8, first, "init")) {
        if (rest.len > 1) return error.UnknownOption;
        const target = if (rest.len == 1) rest[0] else ".";
        return .{ .init = target };
    } else if (std.mem.eql(u8, first, "repl")) {
        return .repl;
    } else if (std.mem.eql(u8, first, "explain")) {
        if (rest.len < 1) return error.MissingArgument;
        return .{ .explain = rest[0] };
    } else if (std.mem.eql(u8, first, "symbols")) {
        return .symbols;
    } else if (std.mem.eql(u8, first, "fmt")) {
        if (rest.len < 1) return error.MissingArgument;
        return .{ .fmt = rest[0] };
    } else if (std.mem.eql(u8, first, "exec")) {
        var query: ?[]const u8 = null;
        var file: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        var tx = false;
        var dry_run = false;
        var json = false;

        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                file = rest[j];
                continue;
            }
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                url = rest[j];
                continue;
            }
            if (std.mem.eql(u8, arg, "--tx")) {
                tx = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
            if (query == null) {
                query = arg;
                continue;
            }
            return error.UnknownOption;
        }

        if (query == null and file == null) return error.MissingArgument;
        if (query != null and file != null) return error.InvalidArgument;
        return .{ .exec = .{
            .query = query,
            .file = file,
            .url = url,
            .tx = tx,
            .dry_run = dry_run,
            .json = json,
        } };
    } else if (std.mem.eql(u8, first, "seed")) {
        var file: []const u8 = "seed.qail";
        var url: ?[]const u8 = null;
        var tx = false;
        var dry_run = false;

        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                file = rest[j];
                continue;
            }
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                url = rest[j];
                continue;
            }
            if (std.mem.eql(u8, arg, "--tx")) {
                tx = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
                continue;
            }
            return error.UnknownOption;
        }

        return .{ .seed = .{
            .file = file,
            .url = url,
            .tx = tx,
            .dry_run = dry_run,
        } };
    } else if (std.mem.eql(u8, first, "types")) {
        if (rest.len > 1) return error.UnknownOption;
        const schema_path = if (rest.len == 1) rest[0] else "schema.qail";
        return .{ .types = schema_path };
    } else if (std.mem.eql(u8, first, "pull")) {
        var url: ?[]const u8 = null;
        var j: usize = 0;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                url = rest[j];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
            if (url == null) {
                url = arg;
                continue;
            }
            return error.UnknownOption;
        }
        if (url == null) return error.MissingArgument;
        return .{ .pull = url.? };
    } else if (std.mem.eql(u8, first, "check")) {
        if (rest.len < 1) return error.MissingArgument;
        return .{ .check = rest[0] };
    } else if (std.mem.eql(u8, first, "diff")) {
        if (rest.len < 2) return error.MissingArgument;

        var diff_format = opts.format;
        var j: usize = 2;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                diff_format = parseOutputFormat(rest[j]) orelse return error.InvalidArgument;
                continue;
            }
            return error.UnknownOption;
        }

        return .{ .diff = .{ .old = rest[0], .new = rest[1], .format = diff_format } };
    } else if (std.mem.eql(u8, first, "lint")) {
        if (rest.len < 1) return error.MissingArgument;

        var strict = false;
        for (rest[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--strict")) {
                strict = true;
            } else {
                return error.UnknownOption;
            }
        }

        return .{ .lint = .{ .schema = rest[0], .strict = strict } };
    } else if (std.mem.eql(u8, first, "mig")) {
        if (rest.len < 1) return error.MissingArgument;
        var depends: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--depends")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                depends = rest[j];
                continue;
            }
            if (std.mem.eql(u8, arg, "--author")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                author = rest[j];
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .create = .{ .name = rest[0], .depends = depends, .author = author } } };
    } else if (std.mem.eql(u8, first, "watch")) {
        if (rest.len < 1) return error.MissingArgument;

        var url: ?[]const u8 = null;
        var auto_apply = false;
        var j: usize = 1;
        while (j < rest.len) : (j += 1) {
            const arg = rest[j];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                j += 1;
                if (j >= rest.len) return error.MissingArgument;
                url = rest[j];
                continue;
            }
            if (std.mem.eql(u8, arg, "--auto-apply")) {
                auto_apply = true;
                continue;
            }
            return error.UnknownOption;
        }

        return .{ .watch = .{ .schema = rest[0], .url = url, .auto_apply = auto_apply } };
    } else if (std.mem.eql(u8, first, "migrate")) {
        return parseMigrateAction(rest);
    }

    // Default: transpile query
    if (rest.len > 0) return error.UnknownOption;
    _ = allocator;
    return .{ .transpile = .{ .query = first, .format = opts.format, .dialect = opts.dialect, .verbose = opts.verbose } };
}

fn parseMigrateAction(args: []const []const u8) !Command {
    if (args.len < 1) return .migrate_help;

    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        return .migrate_help;
    }

    const action = args[0];
    if (std.mem.eql(u8, action, "help")) return .migrate_help;

    if (std.mem.eql(u8, action, "status")) {
        var url: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
            if (url == null) {
                url = arg;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .status = url orelse "" } };
    } else if (std.mem.eql(u8, action, "analyze")) {
        if (args.len < 2) return error.MissingArgument;
        var codebase: []const u8 = "./src";
        var ci = false;
        var json = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--codebase") or std.mem.eql(u8, arg, "-c")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                codebase = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--ci")) {
                ci = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                json = true;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .analyze = .{ .schema_diff = args[1], .codebase = codebase, .ci = ci, .json = json } } };
    } else if (std.mem.eql(u8, action, "plan")) {
        if (args.len < 2) return error.MissingArgument;
        var output: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                output = args[i];
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .plan = .{ .schema_diff = args[1], .output = output } } };
    } else if (std.mem.eql(u8, action, "up")) {
        if (args.len < 2) return error.MissingArgument;
        const schema_diff = args[1];
        var url: ?[]const u8 = null;
        var codebase: ?[]const u8 = null;
        var force = false;
        var allow_destructive = false;
        var allow_no_shadow_receipt = false;
        var allow_lock_risk = false;
        var wait_for_lock = false;
        var lock_timeout_secs: ?u64 = null;
        var i: usize = 2;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            url = args[i];
            i += 1;
        }
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--codebase") or std.mem.eql(u8, arg, "-c")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                codebase = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--force")) {
                force = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-destructive")) {
                allow_destructive = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-no-shadow-receipt")) {
                allow_no_shadow_receipt = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-lock-risk")) {
                allow_lock_risk = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--wait-for-lock")) {
                wait_for_lock = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--lock-timeout-secs")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                lock_timeout_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                wait_for_lock = true;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .up = .{
            .schema_diff = schema_diff,
            .url = url orelse "",
            .codebase = codebase,
            .force = force,
            .allow_destructive = allow_destructive,
            .allow_no_shadow_receipt = allow_no_shadow_receipt,
            .allow_lock_risk = allow_lock_risk,
            .wait_for_lock = wait_for_lock,
            .lock_timeout_secs = lock_timeout_secs,
        } } };
    } else if (std.mem.eql(u8, action, "down")) {
        if (args.len < 2) return error.MissingArgument;
        const schema_diff = args[1];
        var url: ?[]const u8 = null;
        var force = false;
        var wait_for_lock = false;
        var lock_timeout_secs: ?u64 = null;
        var i: usize = 2;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            url = args[i];
            i += 1;
        }
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--force")) {
                force = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--wait-for-lock")) {
                wait_for_lock = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--lock-timeout-secs")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                lock_timeout_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                wait_for_lock = true;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .down = .{
            .schema_diff = schema_diff,
            .url = url orelse "",
            .force = force,
            .wait_for_lock = wait_for_lock,
            .lock_timeout_secs = lock_timeout_secs,
        } } };
    } else if (std.mem.eql(u8, action, "apply")) {
        var url: ?[]const u8 = null;
        var direction: MigrationDirection = .up;
        var phase: ApplyPhase = .all;
        var codebase: ?[]const u8 = null;
        var allow_contract_with_references = false;
        var allow_destructive = false;
        var allow_no_shadow_receipt = false;
        var allow_lock_risk = false;
        var adopt_existing = false;
        var backfill_chunk_size: usize = 5000;
        var wait_for_lock = false;
        var lock_timeout_secs: ?u64 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--direction")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                if (std.mem.eql(u8, args[i], "up")) {
                    direction = .up;
                } else if (std.mem.eql(u8, args[i], "down")) {
                    direction = .down;
                } else {
                    return error.InvalidArgument;
                }
                continue;
            }
            if (std.mem.eql(u8, arg, "--phase")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                phase = parseApplyPhaseValue(args[i]) orelse return error.InvalidArgument;
                continue;
            }
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--codebase") or std.mem.eql(u8, arg, "-c")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                codebase = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-contract-with-references")) {
                allow_contract_with_references = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-destructive")) {
                allow_destructive = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-no-shadow-receipt")) {
                allow_no_shadow_receipt = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--allow-lock-risk")) {
                allow_lock_risk = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--adopt-existing")) {
                adopt_existing = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--backfill-chunk-size")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                backfill_chunk_size = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArgument;
                continue;
            }
            if (std.mem.eql(u8, arg, "--wait-for-lock")) {
                wait_for_lock = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--lock-timeout-secs")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                lock_timeout_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                wait_for_lock = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
            if (url == null) {
                url = arg;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .apply = .{
            .url = url orelse "",
            .direction = direction,
            .phase = phase,
            .codebase = codebase,
            .allow_contract_with_references = allow_contract_with_references,
            .allow_destructive = allow_destructive,
            .allow_no_shadow_receipt = allow_no_shadow_receipt,
            .allow_lock_risk = allow_lock_risk,
            .adopt_existing = adopt_existing,
            .backfill_chunk_size = backfill_chunk_size,
            .wait_for_lock = wait_for_lock,
            .lock_timeout_secs = lock_timeout_secs,
        } } };
    } else if (std.mem.eql(u8, action, "rollback")) {
        var schema_diff: ?[]const u8 = null;
        var to: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        var wait_for_lock = false;
        var lock_timeout_secs: ?u64 = null;
        var i: usize = 1;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            schema_diff = args[i];
            i += 1;
        }
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--to")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                to = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--wait-for-lock")) {
                wait_for_lock = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--lock-timeout-secs")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                lock_timeout_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                wait_for_lock = true;
                continue;
            }
            if (schema_diff == null and to == null and !std.mem.startsWith(u8, arg, "-")) {
                schema_diff = arg;
                continue;
            }
            if (url == null and !std.mem.startsWith(u8, arg, "-")) {
                url = arg;
                continue;
            }
            return error.UnknownOption;
        }
        if (schema_diff != null and to != null) return error.UnknownOption;
        if (schema_diff == null and to == null) return error.MissingArgument;
        return .{ .migrate = .{ .rollback = .{
            .schema_diff = schema_diff,
            .to = to,
            .url = url orelse "",
            .wait_for_lock = wait_for_lock,
            .lock_timeout_secs = lock_timeout_secs,
        } } };
    } else if (std.mem.eql(u8, action, "reset")) {
        if (args.len < 2) return error.MissingArgument;
        const schema = args[1];
        var url: ?[]const u8 = null;
        var wait_for_lock = false;
        var lock_timeout_secs: ?u64 = null;
        var i: usize = 2;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            url = args[i];
            i += 1;
        }
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--wait-for-lock")) {
                wait_for_lock = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--lock-timeout-secs")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                lock_timeout_secs = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                wait_for_lock = true;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .reset = .{
            .schema = schema,
            .url = url orelse "",
            .wait_for_lock = wait_for_lock,
            .lock_timeout_secs = lock_timeout_secs,
        } } };
    } else if (std.mem.eql(u8, action, "create")) {
        if (args.len < 2) return error.MissingArgument;
        var depends: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--depends")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                depends = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--author")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                author = args[i];
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .create = .{ .name = args[1], .depends = depends, .author = author } } };
    } else if (std.mem.eql(u8, action, "shadow")) {
        if (args.len < 2) return error.MissingArgument;
        const schema_diff = args[1];
        var url: ?[]const u8 = null;
        var live = false;
        var i: usize = 2;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            url = args[i];
            i += 1;
        }
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.eql(u8, arg, "--live")) {
                live = true;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .shadow = .{ .schema_diff = schema_diff, .url = url orelse "", .live = live } } };
    } else if (std.mem.eql(u8, action, "promote")) {
        var url: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
            if (url == null) {
                url = arg;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .promote = url orelse "" } };
    } else if (std.mem.eql(u8, action, "abort")) {
        var url: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                url = args[i];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
            if (url == null) {
                url = arg;
                continue;
            }
            return error.UnknownOption;
        }
        return .{ .migrate = .{ .abort = url orelse "" } };
    }

    return error.UnknownCommand;
}

fn envDatabaseUrl() ?[]const u8 {
    return process_compat.getEnvVarOwned(std.heap.page_allocator, "QAIL_DATABASE_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => process_compat.getEnvVarOwned(std.heap.page_allocator, "DATABASE_URL") catch |err2| switch (err2) {
            error.EnvironmentVariableNotFound => null,
            else => null,
        },
        else => null,
    };
}

fn resolveDatabaseUrl(url: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len > 0) return trimmed;
    if (envDatabaseUrl()) |env_url| return env_url;
    print("Error: database URL required. Pass --url or set QAIL_DATABASE_URL/DATABASE_URL.\n", .{});
    return error.MissingArgument;
}

const MIGRATION_LOCK_CLASS_ID: i32 = 20_801;
const MIGRATION_LOCK_OBJECT_SEED: i32 = 19_783;
const MIGRATION_LOCK_WAIT_POLL_MS: u64 = 500;

fn scopedMigrationLockObjectId(scope: ?[]const u8) i32 {
    const raw_scope = scope orelse return MIGRATION_LOCK_OBJECT_SEED;
    const normalized = std.mem.trim(u8, raw_scope, " \t\r\n");
    if (normalized.len == 0) return MIGRATION_LOCK_OBJECT_SEED;

    // Stable FNV-1a hash with a fixed seed xor, mirroring qail.rs semantics.
    var hash: u32 = 0x811c9dc5;
    for (normalized) |byte| {
        hash ^= @as(u32, std.ascii.toLower(byte));
        hash *%= 0x01000193;
    }

    const mixed = hash ^ @as(u32, @intCast(MIGRATION_LOCK_OBJECT_SEED));
    return @as(i32, @intCast(mixed & 0x7fff_ffff));
}

fn migrationLockObjectIdForUrl(allocator: Allocator, url: []const u8) i32 {
    const driver_mod = @import("driver/mod.zig");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const parsed = driver_mod.connect_url.parseConnectionUrl(arena_state.allocator(), url) catch return MIGRATION_LOCK_OBJECT_SEED;
    return scopedMigrationLockObjectId(parsed.database);
}

fn tryAcquireMigrationLock(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    lock_object_id: i32,
) !bool {
    const lock_source = try std.fmt.allocPrint(
        allocator,
        "pg_try_advisory_lock({d}, {d})",
        .{ MIGRATION_LOCK_CLASS_ID, lock_object_id },
    );
    defer allocator.free(lock_source);

    const lock_cmd = QailCmd.get(lock_source)
        .select(&.{
            Expr.col("pg_try_advisory_lock"),
        }).limit(1);

    const rows = try pg.fetchAll(&lock_cmd);
    defer deinitFetchedRows(allocator, rows);
    if (rows.len == 0) return false;
    return rows[0].getBool(0) orelse false;
}

fn acquireMigrationLock(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    operation: []const u8,
    url: []const u8,
    wait_for_lock: bool,
    lock_timeout_secs: ?u64,
) !void {
    const should_wait = wait_for_lock or lock_timeout_secs != null;
    const lock_object_id = migrationLockObjectIdForUrl(allocator, url);

    const deadline_ms: ?u64 = if (lock_timeout_secs) |timeout_secs| blk: {
        const timeout_ms = std.math.mul(u64, timeout_secs, 1000) catch std.math.maxInt(u64);
        const now_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds()));
        break :blk std.math.add(u64, now_ms, timeout_ms) catch std.math.maxInt(u64);
    } else null;

    if (should_wait) {
        print("  ⏳ Waiting for migration lock...\n", .{});
        while (true) {
            if (try tryAcquireMigrationLock(allocator, pg, lock_object_id)) {
                print("  ✓ Acquired migration lock\n", .{});
                return;
            }

            if (deadline_ms) |limit_ms| {
                const now_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds()));
                if (now_ms >= limit_ms) {
                    print(
                        "Error: timed out waiting for migration lock for '{s}' after {d} second(s).\n",
                        .{ operation, lock_timeout_secs orelse 0 },
                    );
                    return error.MigrationLockTimeout;
                }
            }

            std.Io.sleep(
                io_compat.runtimeIo(),
                std.Io.Duration.fromMilliseconds(MIGRATION_LOCK_WAIT_POLL_MS),
                .awake,
            ) catch {};
        }
    }

    if (try tryAcquireMigrationLock(allocator, pg, lock_object_id)) {
        print("  ✓ Acquired migration lock\n", .{});
        return;
    }

    print(
        "Error: another migration operation is already running for '{s}'. Re-run with --wait-for-lock or --lock-timeout-secs.\n",
        .{operation},
    );
    return error.MigrationLockBusy;
}

// ==================== Command Handlers ====================

pub fn run(allocator: Allocator, cmd: Command) !void {
    switch (cmd) {
        .transpile => |t| try transpile(allocator, t.query, t.dialect, t.format, t.verbose),
        .init => |target| try initProject(allocator, target),
        .repl => try runRepl(allocator),
        .explain => |query| try explainQuery(allocator, query),
        .symbols => showSymbols(),
        .fmt => |query| try formatQuery(allocator, query),
        .exec => |e| try runExec(allocator, e),
        .seed => |s| try runSeed(allocator, s),
        .types => |schema_path| try generateTypes(allocator, schema_path),
        .pull => |url| try schema_ops.pullSchema(allocator, url),
        .check => |schema| try schema_ops.checkSchema(allocator, schema),
        .diff => |d| try schema_ops.diffSchemas(allocator, d.old, d.new, @tagName(d.format)),
        .lint => |l| try schema_ops.lintSchema(allocator, l.schema, l.strict),
        .watch => |w| try schema_ops.watchSchema(allocator, w.schema, w.url, w.auto_apply),
        .migrate => |m| try runMigrate(allocator, m),
        .migrate_help => showMigrateHelp(),
        .help => showHelp(),
        .version => showVersion(),
    }
}

fn initProject(allocator: Allocator, target_dir: []const u8) !void {
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

fn transpile(allocator: Allocator, query: []const u8, dialect: Dialect, format: OutputFormat, verbose: bool) !void {
    _ = dialect;
    const parser = @import("parser/mod.zig");
    const transpiler = @import("transpiler/mod.zig");

    if (verbose) {
        print("Input: {s}\n\n", .{query});
    }

    var cmd = try parser.parse(allocator, query);
    defer freeParsedCmd(allocator, &cmd);

    const sql = try transpiler.toSql(allocator, &cmd);
    defer allocator.free(sql);

    switch (format) {
        .sql => {
            print("{s}\n", .{sql});
        },
        .pretty => {
            print("Generated SQL:\n{s}\n", .{sql});
        },
        .json => {
            const payload = .{
                .action = @tagName(cmd.kind),
                .table = cmd.table,
                .sql = sql,
            };
            var writer = io_compat.AllocatingWriter.init(allocator);
            defer writer.deinit();
            try std.json.Stringify.value(payload, .{}, writer.writer());
            const encoded = try writer.toOwnedSlice();
            defer allocator.free(encoded);
            print("{s}\n", .{encoded});
        },
    }
}

fn runRepl(allocator: Allocator) !void {
    const parser = @import("parser/mod.zig");
    const transpiler = @import("transpiler/mod.zig");
    const io_iface = io_compat.runtimeIo();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io_iface, &stdin_buf);

    print("🪝 QAIL REPL (Zig Edition)\n", .{});
    print("Type 'exit' to quit, 'help' for commands\n\n", .{});

    while (true) {
        print("qail> ", .{});
        const maybe_line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => {
                const read_err = stdin_reader.err orelse error.ReadFailed;
                print("\nRead error: {}\n", .{read_err});
                return read_err;
            },
            error.StreamTooLong => {
                _ = stdin_reader.interface.discardDelimiterInclusive('\n') catch {};
                print("Input too long (max 4096 bytes per line)\n", .{});
                continue;
            },
        };

        const raw_line = maybe_line orelse {
            print("\n", .{});
            return;
        };
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) {
            print("Goodbye.\n", .{});
            return;
        }
        if (std.mem.eql(u8, line, "help")) {
            print("Commands:\n", .{});
            print("  help          Show this help\n", .{});
            print("  exit | quit   Leave REPL\n", .{});
            print("Any other input is treated as a QAIL query and transpiled to SQL.\n", .{});
            continue;
        }

        var cmd = parser.parse(allocator, line) catch |err| {
            print("Parse error: {}\n", .{err});
            continue;
        };
        defer freeParsedCmd(allocator, &cmd);

        const sql = transpiler.toSql(allocator, &cmd) catch |err| {
            print("Transpile error: {}\n", .{err});
            continue;
        };
        defer allocator.free(sql);

        print("{s}\n", .{sql});
    }
}

const ExecStatements = struct {
    items: std.ArrayList([]const u8),
    file_content: ?[]u8 = null,

    fn deinit(self: *ExecStatements, allocator: Allocator) void {
        self.items.deinit(allocator);
        if (self.file_content) |content| allocator.free(content);
        self.file_content = null;
    }
};

fn normalizeExecStatement(raw: []const u8) []const u8 {
    var stmt = std.mem.trim(u8, raw, " \t\r");
    while (stmt.len > 0 and stmt[stmt.len - 1] == ';') {
        stmt = std.mem.trim(u8, stmt[0 .. stmt.len - 1], " \t\r");
    }
    return stmt;
}

fn collectExecStatements(allocator: Allocator, query: ?[]const u8, file: ?[]const u8) !ExecStatements {
    var out = ExecStatements{
        .items = .empty,
        .file_content = null,
    };
    errdefer out.deinit(allocator);

    if (query) |inline_query| {
        const stmt = normalizeExecStatement(inline_query);
        if (stmt.len == 0) return error.MissingArgument;
        try out.items.append(allocator, stmt);
        return out;
    }

    const file_path = file orelse return error.MissingArgument;
    const content = try readFileAlloc(allocator, file_path, 16 * 1024 * 1024);
    out.file_content = content;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = normalizeExecStatement(line);
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "--")) continue;
        try out.items.append(allocator, trimmed);
    }

    if (out.items.items.len == 0) return error.MissingArgument;
    return out;
}

fn cmdReturnsRows(kind: @import("ast/cmd/types.zig").CmdKind) bool {
    return switch (kind) {
        .get, .cnt, .search, .scroll, .explain, .explain_analyze => true,
        else => false,
    };
}

fn printJsonStringEscaped(allocator: Allocator, value: []const u8) !void {
    var encoded = io_compat.AllocatingWriter.init(allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(value, .{}, encoded.writer());
    const bytes = try encoded.toOwnedSlice();
    defer allocator.free(bytes);
    print("{s}", .{bytes});
}

fn printRowsAsJson(allocator: Allocator, rows: []const @import("driver/row.zig").PgRow) !void {
    print("[", .{});
    for (rows, 0..) |row, row_idx| {
        if (row_idx > 0) print(",", .{});
        print("{{", .{});
        for (row.field_names, 0..) |name, col_idx| {
            if (col_idx > 0) print(",", .{});
            try printJsonStringEscaped(allocator, name);
            print(":", .{});
            if (row.getString(col_idx)) |value| {
                try printJsonStringEscaped(allocator, value);
            } else {
                print("null", .{});
            }
        }
        print("}}", .{});
    }
    print("]\n", .{});
}

fn printRowsAsTable(rows: []const @import("driver/row.zig").PgRow) void {
    if (rows.len == 0) {
        print("(0 rows)\n", .{});
        return;
    }

    const headers = rows[0].field_names;
    for (headers, 0..) |name, idx| {
        if (idx > 0) print(" | ", .{});
        print("{s}", .{name});
    }
    print("\n", .{});

    for (rows) |row| {
        for (row.columns, 0..) |maybe_value, idx| {
            if (idx > 0) print(" | ", .{});
            if (maybe_value) |value| {
                print("{s}", .{value});
            } else {
                print("NULL", .{});
            }
        }
        print("\n", .{});
    }
    print("({d} row(s))\n", .{rows.len});
}

fn runExec(
    allocator: Allocator,
    exec: ExecCmd,
) !void {
    const parser = @import("parser/mod.zig");
    const transpiler = @import("transpiler/mod.zig");

    var statements = try collectExecStatements(allocator, exec.query, exec.file);
    defer statements.deinit(allocator);

    if (exec.dry_run) {
        print("📋 Exec Dry-Run ({d} statement(s))\n\n", .{statements.items.items.len});
        for (statements.items.items, 0..) |stmt, idx| {
            var cmd = parser.parse(allocator, stmt) catch |err| {
                print("Parse error at statement {d}: {}\n", .{ idx + 1, err });
                return err;
            };
            defer freeParsedCmd(allocator, &cmd);

            const sql = transpiler.toSql(allocator, &cmd) catch |err| {
                print("Transpile error at statement {d}: {}\n", .{ idx + 1, err });
                return err;
            };
            defer allocator.free(sql);
            print("-- statement {d}\n{s};\n\n", .{ idx + 1, sql });
        }
        return;
    }

    const provided_url = exec.url orelse "";
    const url = try resolveDatabaseUrl(provided_url);

    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();

    var tx_active = false;
    defer if (tx_active) pg.rollback() catch {};

    if (exec.tx) {
        pg.begin() catch |err| {
            print("Error starting transaction: {}\n", .{err});
            return err;
        };
        tx_active = true;
    }

    for (statements.items.items, 0..) |stmt, idx| {
        var cmd = parser.parse(allocator, stmt) catch |err| {
            print("Parse error at statement {d}: {}\n", .{ idx + 1, err });
            return err;
        };
        defer freeParsedCmd(allocator, &cmd);

        if (cmdReturnsRows(cmd.kind)) {
            const rows = pg.fetchAll(&cmd) catch |err| {
                print("Execution error at statement {d}: {}\n", .{ idx + 1, err });
                return err;
            };
            defer deinitFetchedRows(allocator, rows);
            if (exec.json) {
                try printRowsAsJson(allocator, rows);
            } else {
                printRowsAsTable(rows);
            }
        } else {
            const affected = pg.execute(&cmd) catch |err| {
                print("Execution error at statement {d}: {}\n", .{ idx + 1, err });
                return err;
            };
            print("✓ statement {d}: {d} row(s) affected\n", .{ idx + 1, affected });
        }
    }

    if (tx_active) {
        pg.commit() catch |err| {
            print("Error committing transaction: {}\n", .{err});
            return err;
        };
        tx_active = false;
        print("✅ Transaction committed\n", .{});
    }
}

fn runSeed(
    allocator: Allocator,
    seed: SeedCmd,
) !void {
    print("🌱 Seeding from: {s}\n", .{seed.file});
    try runExec(allocator, .{
        .query = null,
        .file = seed.file,
        .url = seed.url,
        .tx = seed.tx,
        .dry_run = seed.dry_run,
        .json = false,
    });
}

fn isRustKeyword(name: []const u8) bool {
    return std.mem.eql(u8, name, "type") or
        std.mem.eql(u8, name, "match") or
        std.mem.eql(u8, name, "struct") or
        std.mem.eql(u8, name, "enum") or
        std.mem.eql(u8, name, "mod") or
        std.mem.eql(u8, name, "self") or
        std.mem.eql(u8, name, "crate");
}

fn toRustFieldIdent(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, std.ascii.toLower(ch));
        } else {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '_') {
                try out.append(allocator, '_');
            }
        }
    }

    if (out.items.len == 0) {
        return allocator.dupe(u8, "field");
    }
    if (std.ascii.isDigit(out.items[0])) {
        try out.insert(allocator, 0, '_');
    }
    if (isRustKeyword(out.items)) {
        try out.append(allocator, '_');
    }
    return out.toOwnedSlice(allocator);
}

fn toRustStructName(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var capitalize = true;

    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (capitalize) {
                try out.append(allocator, std.ascii.toUpper(ch));
                capitalize = false;
            } else {
                try out.append(allocator, ch);
            }
        } else {
            capitalize = true;
        }
    }

    if (out.items.len == 0) return allocator.dupe(u8, "Table");
    if (std.ascii.isDigit(out.items[0])) {
        try out.insert(allocator, 0, 'T');
    }
    return out.toOwnedSlice(allocator);
}

fn mapSchemaTypeToRust(col_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(col_type, "serial") or std.ascii.eqlIgnoreCase(col_type, "i32") or std.ascii.eqlIgnoreCase(col_type, "int") or std.ascii.eqlIgnoreCase(col_type, "integer")) return "i32";
    if (std.ascii.eqlIgnoreCase(col_type, "bigserial") or std.ascii.eqlIgnoreCase(col_type, "i64") or std.ascii.eqlIgnoreCase(col_type, "bigint")) return "i64";
    if (std.ascii.eqlIgnoreCase(col_type, "smallint") or std.ascii.eqlIgnoreCase(col_type, "i16")) return "i16";
    if (std.ascii.eqlIgnoreCase(col_type, "f32") or std.ascii.eqlIgnoreCase(col_type, "real")) return "f32";
    if (std.ascii.eqlIgnoreCase(col_type, "f64") or std.ascii.eqlIgnoreCase(col_type, "double") or std.ascii.eqlIgnoreCase(col_type, "numeric") or std.ascii.eqlIgnoreCase(col_type, "decimal")) return "f64";
    if (std.ascii.eqlIgnoreCase(col_type, "bool") or std.ascii.eqlIgnoreCase(col_type, "boolean")) return "bool";
    if (std.ascii.eqlIgnoreCase(col_type, "bytea")) return "Vec<u8>";
    if (std.ascii.eqlIgnoreCase(col_type, "uuid") or
        std.ascii.eqlIgnoreCase(col_type, "text") or
        std.ascii.eqlIgnoreCase(col_type, "varchar") or
        std.ascii.eqlIgnoreCase(col_type, "char") or
        std.ascii.eqlIgnoreCase(col_type, "timestamp") or
        std.ascii.eqlIgnoreCase(col_type, "timestamptz") or
        std.ascii.eqlIgnoreCase(col_type, "date") or
        std.ascii.eqlIgnoreCase(col_type, "time") or
        std.ascii.eqlIgnoreCase(col_type, "timetz") or
        std.ascii.eqlIgnoreCase(col_type, "json") or
        std.ascii.eqlIgnoreCase(col_type, "jsonb"))
    {
        return "String";
    }
    return "String";
}

fn generateTypes(allocator: Allocator, schema_path: []const u8) !void {
    const parser = @import("parser/mod.zig");

    const schema_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(schema_content);

    var schema = parser.Schema.parse(allocator, schema_content) catch |err| {
        print("Error parsing schema: {}\n", .{err});
        return err;
    };
    defer schema.deinit();

    print("// Generated by qail-zig from {s}\n", .{schema_path});
    print("// rust structs\n\n", .{});

    if (schema.tables.items.len == 0) {
        print("// No tables found\n", .{});
        return;
    }

    for (schema.tables.items) |table| {
        const struct_name = try toRustStructName(allocator, table.name);
        defer allocator.free(struct_name);

        print("#[derive(Debug, Clone)]\n", .{});
        print("pub struct {s} {{\n", .{struct_name});
        for (table.columns.items) |col| {
            const field_name = try toRustFieldIdent(allocator, col.name);
            defer allocator.free(field_name);

            const rust_base = mapSchemaTypeToRust(col.typ);
            if (col.nullable and !col.primary_key) {
                if (col.is_array) {
                    print("    pub {s}: Option<Vec<{s}>>,\n", .{ field_name, rust_base });
                } else {
                    print("    pub {s}: Option<{s}>,\n", .{ field_name, rust_base });
                }
            } else {
                if (col.is_array) {
                    print("    pub {s}: Vec<{s}>,\n", .{ field_name, rust_base });
                } else {
                    print("    pub {s}: {s},\n", .{ field_name, rust_base });
                }
            }
        }
        print("}}\n\n", .{});
    }
}

fn explainQuery(allocator: Allocator, query: []const u8) !void {
    const parser = @import("parser/mod.zig");
    const transpiler = @import("transpiler/mod.zig");

    print("🔍 Query Analysis\n\n", .{});
    print("  Query: {s}\n\n", .{query});

    var cmd = try parser.parse(allocator, query);
    defer freeParsedCmd(allocator, &cmd);

    const sql = try transpiler.toSql(allocator, &cmd);
    defer allocator.free(sql);

    print("  Action: {s}\n", .{@tagName(cmd.kind)});
    print("  Table: {s}\n", .{cmd.table});
    if (cmd.columns.len > 0) {
        print("  Columns: {d}\n", .{cmd.columns.len});
    }
    print("\n", .{});
    print("  SQL: {s}\n", .{sql});
}

fn showSymbols() void {
    print("🪝 QAIL Symbol Reference (v2.0)\n\n", .{});

    print("{s:10} {s:15} {s:30} {s}\n", .{ "Symbol", "Name", "Function", "SQL Equivalent" });
    print("────────────────────────────────────────────────────────────────────────────────\n", .{});
    print("{s:10} {s:15} {s:30} {s}\n", .{ "::", "separator", "Table delimiter", "FROM" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "'", "field", "Column selector", "SELECT col" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "'_", "all", "All columns", "SELECT *" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "[", "filter", "WHERE condition", "WHERE ..." });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "]", "close", "End filter/modifier", "" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "[]", "values", "Insert values", "VALUES (...)" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "$", "param", "Placeholder", "$1, $2" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "<-", "left", "LEFT JOIN", "LEFT JOIN" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "->", "inner", "INNER JOIN", "JOIN" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "<>", "full", "FULL OUTER JOIN", "FULL JOIN" });
    print("{s:10} {s:15} {s:30} {s}\n", .{ "!", "distinct", "DISTINCT modifier", "SELECT DISTINCT" });
    print("\n", .{});
}

fn formatQuery(allocator: Allocator, query: []const u8) !void {
    const parser = @import("parser/mod.zig");
    const fmt_mod = @import("fmt.zig");

    var cmd = try parser.parse(allocator, query);
    defer freeParsedCmd(allocator, &cmd);

    var formatter = fmt_mod.Formatter.init(allocator);
    defer formatter.deinit();

    _ = try formatter.format(&cmd);
    print("{s}", .{formatter.buffer.items});
    if (formatter.buffer.items.len == 0 or formatter.buffer.items[formatter.buffer.items.len - 1] != '\n') {
        print("\n", .{});
    }
}

fn freeParsedCmd(allocator: Allocator, cmd: *const QailCmd) void {
    if (cmd.columns.len > 0) allocator.free(cmd.columns);
    if (cmd.where_clauses.len > 0) allocator.free(cmd.where_clauses);
    if (cmd.joins.len > 0) allocator.free(cmd.joins);
    if (cmd.order_by.len > 0) allocator.free(cmd.order_by);
}

fn deinitMigrationCmds(allocator: Allocator, cmds: *std.ArrayList(@import("parser/mod.zig").MigrationCmd)) void {
    for (cmds.items) |cmd| {
        if (cmd.table_columns.len > 0) allocator.free(cmd.table_columns);
    }
    cmds.deinit(allocator);
}

fn deinitFetchedRows(allocator: Allocator, rows: []@import("driver/row.zig").PgRow) void {
    for (rows) |*row| {
        var owned = row.*;
        owned.deinit();
    }
    allocator.free(rows);
}

fn putOwnedStringSetKey(allocator: Allocator, set: *std.StringHashMap(void), key: []u8) !void {
    const gop = try set.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        return;
    }
    gop.value_ptr.* = {};
}

fn putStringSetKey(allocator: Allocator, set: *std.StringHashMap(void), key: []const u8) !void {
    const owned = try allocator.dupe(u8, key);
    try putOwnedStringSetKey(allocator, set, owned);
}

fn deinitStringSet(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    set.deinit();
}

const ShadowStateReceipt = struct {
    shadow_name: []u8,
    primary_url: []u8,
    schema_diff: []u8,

    fn deinit(self: *ShadowStateReceipt, allocator: Allocator) void {
        allocator.free(self.shadow_name);
        allocator.free(self.primary_url);
        allocator.free(self.schema_diff);
    }
};

fn freeGeneratedCmdColumns(allocator: Allocator, cmd: *const QailCmd) void {
    if (cmd.columns.len == 0) return;
    const cols_ptr: [*]const Expr = cmd.columns.ptr;
    const cols_many: [*]Expr = @constCast(cols_ptr);
    allocator.free(cols_many[0..cmd.columns.len]);
}

fn executeMigrationCmds(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    cmds: []const @import("parser/mod.zig").MigrationCmd,
    label: []const u8,
) !void {
    for (cmds, 0..) |migration_cmd, i| {
        const stmt_sql = migration_cmd.toSql(allocator) catch |err| {
            print("Error rendering SQL for {s} step {d}: {}\n", .{ label, i + 1, err });
            return err;
        };
        defer allocator.free(stmt_sql);

        const qail_cmd = migration_cmd.toQailCmd(allocator) catch |err| {
            print("Error converting {s} step {d} to AST command: {}\n", .{ label, i + 1, err });
            return err;
        };
        defer freeGeneratedCmdColumns(allocator, &qail_cmd);

        print("  [{s} {d}] {s};\n", .{ label, i + 1, stmt_sql });
        _ = pg.execute(&qail_cmd) catch |err| {
            print("Error executing {s} step {d}: {}\n", .{ label, i + 1, err });
            return err;
        };
    }
}

fn connectPgUrl(
    allocator: Allocator,
    url: []const u8,
) !@import("driver/driver.zig").PgDriver {
    const driver_mod = @import("driver/mod.zig");
    return try driver_mod.driver.PgDriver.connectUrl(allocator, url);
}

fn deriveShadowDatabaseName(allocator: Allocator, primary_url: []const u8) ![]u8 {
    const driver_mod = @import("driver/mod.zig");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const parsed = try driver_mod.connect_url.parseConnectionUrl(arena_state.allocator(), primary_url);
    return try std.fmt.allocPrint(allocator, "{s}_shadow", .{parsed.database});
}

fn rewriteDatabaseInUrl(
    allocator: Allocator,
    url: []const u8,
    database_name: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const query_idx = std.mem.indexOfScalar(u8, trimmed, '?');
    const authority_and_path = if (query_idx) |idx| trimmed[0..idx] else trimmed;
    const query = if (query_idx) |idx| trimmed[idx + 1 ..] else "";

    const at_idx = std.mem.lastIndexOfScalar(u8, authority_and_path, '@') orelse return error.InvalidDatabaseUrlMissingUser;
    const slash_rel = std.mem.indexOfScalar(u8, authority_and_path[at_idx + 1 ..], '/') orelse return error.InvalidDatabaseUrlMissingDatabase;
    const slash_idx = at_idx + 1 + slash_rel;
    const prefix = authority_and_path[0 .. slash_idx + 1];

    if (query.len > 0) {
        return try std.fmt.allocPrint(allocator, "{s}{s}?{s}", .{ prefix, database_name, query });
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, database_name });
}

fn slugifyMigrationName(allocator: Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try out.append(allocator, std.ascii.toLower(c));
        } else if (c == ' ' or c == '-' or c == '.') {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '_') {
                try out.append(allocator, '_');
            }
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "migration");
    }

    return try out.toOwnedSlice(allocator);
}

fn shadowStateCreateCmd() QailCmd {
    const columns = [_]Expr{
        .{ .column_def = .{ .name = "id", .data_type = "serial", .is_primary_key = true } },
        .{ .column_def = .{ .name = "shadow_name", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "primary_url", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "schema_diff", .data_type = "text", .is_not_null = true } },
        .{ .column_def = .{ .name = "status", .data_type = "text", .is_not_null = true, .default_value = "'pending'" } },
        .{ .column_def = .{ .name = "created_at", .data_type = "timestamptz", .default_value = "NOW()" } },
    };

    return .{
        .kind = .make,
        .table = "_qail_shadow_state",
        .columns = &columns,
    };
}

fn ensureShadowStateTable(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
) !void {
    const exists_cmd = QailCmd.get("information_schema.tables")
        .select(&.{
            Expr.col("table_name"),
        }).where(&.{
            .{ .condition = .{ .column = "table_schema", .op = .eq, .value = .{ .string = "public" } } },
            .{ .condition = .{ .column = "table_name", .op = .eq, .value = .{ .string = "_qail_shadow_state" } } },
        }).limit(1);
    const exists_rows = try pg.fetchAll(&exists_cmd);
    defer deinitFetchedRows(allocator, exists_rows);

    if (exists_rows.len == 0) {
        const create_cmd = shadowStateCreateCmd();
        _ = try pg.execute(&create_cmd);
    }
}

fn saveShadowState(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    primary_url: []const u8,
    schema_diff: []const u8,
    shadow_name: []const u8,
) !void {
    const Value = @import("ast/cmd.zig").Value;

    try ensureShadowStateTable(allocator, pg);

    const clear_pending = QailCmd.del("_qail_shadow_state").where(&.{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "pending" } } },
    });
    _ = pg.execute(&clear_pending) catch {};
    const clear_verified = QailCmd.del("_qail_shadow_state").where(&.{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "verified" } } },
    });
    _ = pg.execute(&clear_verified) catch {};

    const insert_cmd = QailCmd{
        .kind = .add,
        .table = "_qail_shadow_state",
        .columns = &[_]Expr{
            Expr.col("shadow_name"),
            Expr.col("primary_url"),
            Expr.col("schema_diff"),
            Expr.col("status"),
        },
        .insert_values = &[_]Value{
            Value.fromString(shadow_name),
            Value.fromString(primary_url),
            Value.fromString(schema_diff),
            Value.fromString("pending"),
        },
    };
    _ = try pg.execute(&insert_cmd);
}

fn fetchShadowStateByStatus(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    status: []const u8,
) !?ShadowStateReceipt {
    const cmd = QailCmd.get("_qail_shadow_state")
        .select(&.{
            Expr.col("shadow_name"),
            Expr.col("primary_url"),
            Expr.col("schema_diff"),
        }).where(&.{
            .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = status } } },
        }).limit(1);
    const rows = try pg.fetchAll(&cmd);
    defer deinitFetchedRows(allocator, rows);

    if (rows.len == 0) return null;

    const shadow_name = rows[0].getByName("shadow_name") orelse return error.InvalidShadowStateRow;
    const primary_url = rows[0].getByName("primary_url") orelse return error.InvalidShadowStateRow;
    const schema_diff = rows[0].getByName("schema_diff") orelse return error.InvalidShadowStateRow;

    var receipt = ShadowStateReceipt{
        .shadow_name = try allocator.dupe(u8, shadow_name),
        .primary_url = try allocator.dupe(u8, primary_url),
        .schema_diff = try allocator.dupe(u8, schema_diff),
    };
    errdefer receipt.deinit(allocator);

    return receipt;
}

fn loadActiveShadowState(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
) !?ShadowStateReceipt {
    try ensureShadowStateTable(allocator, pg);
    if (try fetchShadowStateByStatus(allocator, pg, "pending")) |state| return state;
    if (try fetchShadowStateByStatus(allocator, pg, "verified")) |state| return state;
    return null;
}

fn updateShadowStateStatus(
    pg: *@import("driver/driver.zig").PgDriver,
    status: []const u8,
) !void {
    const update_pending = QailCmd.set("_qail_shadow_state")
        .values(&.{
            .{ .column = "status", .value = .{ .string = status } },
        }).where(&.{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "pending" } } },
    });
    _ = try pg.execute(&update_pending);

    const update_verified = QailCmd.set("_qail_shadow_state")
        .values(&.{
            .{ .column = "status", .value = .{ .string = status } },
        }).where(&.{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "verified" } } },
    });
    _ = pg.execute(&update_verified) catch {};
}

fn runMigrateStatus(allocator: Allocator, url: []const u8) !void {
    const parser = @import("parser/mod.zig");

    print("📊 Migration Status\n\n", .{});

    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();

    const mig_cmd = parser.getMigrationTableCmd();
    _ = pg.execute(&mig_cmd) catch |err| {
        print("Error creating migration table: {}\n", .{err});
        return err;
    };

    const status_cmd = QailCmd.get("_qail_migrations")
        .select(&.{
            Expr.col("version"),
            Expr.col("name"),
            Expr.col("applied_at"),
            Expr.col("checksum"),
        }).orderBy(&.{
        .{ .column = "applied_at", .order = .asc },
    });
    const status_rows = pg.fetchAll(&status_cmd) catch |err| {
        print("Error querying migrations: {}\n", .{err});
        return err;
    };
    defer deinitFetchedRows(allocator, status_rows);
    const row_count = status_rows.len;

    print("  URL: {s}\n", .{url});
    print("  Migration table: _qail_migrations\n\n", .{});

    if (row_count > 0) {
        print("  ✓ Found {} migration(s) applied\n\n", .{row_count});
        print("  Version           Name              Applied At                Checksum\n", .{});
        print("  ---------------------------------------------------------------------------\n", .{});
        for (status_rows) |row| {
            const version = row.getByName("version") orelse "-";
            const name = row.getByName("name") orelse "-";
            const applied_at = row.getByName("applied_at") orelse "-";
            const checksum = row.getByName("checksum") orelse "-";
            print("  {s:16}  {s:16}  {s:24}  {s}\n", .{ version, name, applied_at, checksum });
        }
        print("\n", .{});
        print("  Run 'qail migrate up' to apply new migrations\n", .{});
    } else {
        print("  No migrations applied yet\n\n", .{});
        print("  Run 'qail migrate up old.qail:new.qail <URL>' to apply\n", .{});
    }
}

fn writeShadowLiveBaseSnapshot(allocator: Allocator, schema_content: []const u8) ![]u8 {
    const io_iface = io_compat.runtimeIo();
    try std.Io.Dir.cwd().createDirPath(io_iface, "migrations");
    const ts_ms = std.Io.Clock.now(.real, io_iface).toMilliseconds();
    const path = try std.fmt.allocPrint(allocator, "migrations/.shadow_live_{d}.qail", .{ts_ms});
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io_iface, .{
        .sub_path = path,
        .data = schema_content,
        .flags = .{
            .truncate = true,
        },
    });
    return path;
}

fn runMigrateShadow(allocator: Allocator, schema_diff: []const u8, url: []const u8, live: bool) !void {
    const parser = @import("parser/mod.zig");
    const parsed_diff = parseSchemaDiffPath(schema_diff);

    var old_schema: parser.Schema = undefined;
    var old_loaded = false;
    defer if (old_loaded) old_schema.deinit();

    var new_schema: parser.Schema = undefined;
    var new_loaded = false;
    defer if (new_loaded) new_schema.deinit();

    var old_label: []const u8 = undefined;
    var new_label: []const u8 = undefined;

    var effective_schema_diff: ?[]u8 = null;
    defer if (effective_schema_diff) |owned| allocator.free(owned);

    if (live) {
        var target_schema_path = schema_diff;
        if (parsed_diff.old != null and parsed_diff.new != null) {
            target_schema_path = parsed_diff.new.?;
            print("  Note: --live ignores provided old schema path and uses live database snapshot.\n", .{});
        }

        const new_content = readFileAlloc(allocator, target_schema_path, 8 * 1024 * 1024) catch |err| {
            print("Error reading target schema: {}\n", .{err});
            return err;
        };
        defer allocator.free(new_content);

        new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
            print("Error parsing target schema: {}\n", .{err});
            return err;
        };
        new_loaded = true;

        var primary_live_pg = connectPgUrl(allocator, url) catch |err| {
            print("Error connecting to primary database for live shadow baseline: {}\n", .{err});
            return err;
        };
        defer primary_live_pg.deinit();

        const live_snapshot = schema_ops.renderLiveSchemaSnapshot(allocator, &primary_live_pg) catch |err| {
            print("Error introspecting live schema: {}\n", .{err});
            return err;
        };
        defer allocator.free(live_snapshot.schema);

        old_schema = parser.Schema.parse(allocator, live_snapshot.schema) catch |err| {
            print("Error parsing live schema snapshot: {}\n", .{err});
            return err;
        };
        old_loaded = true;

        const live_snapshot_path = writeShadowLiveBaseSnapshot(allocator, live_snapshot.schema) catch |err| {
            print("Error saving live schema snapshot for promote parity: {}\n", .{err});
            return err;
        };
        defer allocator.free(live_snapshot_path);

        effective_schema_diff = try std.fmt.allocPrint(allocator, "{s}:{s}", .{
            live_snapshot_path,
            target_schema_path,
        });

        old_label = "live://primary";
        new_label = target_schema_path;
        print("  Live baseline snapshot: {s}\n", .{live_snapshot_path});
    } else {
        if (parsed_diff.old == null or parsed_diff.new == null) {
            print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
            return;
        }

        old_label = parsed_diff.old.?;
        new_label = parsed_diff.new.?;

        const old_content = readFileAlloc(allocator, old_label, 8 * 1024 * 1024) catch |err| {
            print("Error reading old schema: {}\n", .{err});
            return err;
        };
        defer allocator.free(old_content);

        const new_content = readFileAlloc(allocator, new_label, 8 * 1024 * 1024) catch |err| {
            print("Error reading new schema: {}\n", .{err});
            return err;
        };
        defer allocator.free(new_content);

        old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
            print("Error parsing old schema: {}\n", .{err});
            return err;
        };
        old_loaded = true;

        new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
            print("Error parsing new schema: {}\n", .{err});
            return err;
        };
        new_loaded = true;
    }

    print("🌑 Shadow Migration\n\n", .{});
    if (live) {
        print("  Mode: live baseline from primary\n", .{});
    }
    print("  Diff: {s} → {s}\n", .{ old_label, new_label });
    print("  Primary URL: {s}\n\n", .{url});

    const shadow_name = try deriveShadowDatabaseName(allocator, url);
    defer allocator.free(shadow_name);

    const admin_url = try rewriteDatabaseInUrl(allocator, url, "postgres");
    defer allocator.free(admin_url);
    var admin_pg = connectPgUrl(allocator, admin_url) catch |err| {
        print("Error connecting to admin database: {}\n", .{err});
        return err;
    };
    defer admin_pg.deinit();

    const check_shadow = QailCmd.get("pg_catalog.pg_database")
        .select(&.{
            Expr.col("datname"),
        }).where(&.{
            .{ .condition = .{ .column = "datname", .op = .eq, .value = .{ .string = shadow_name } } },
        }).limit(1);
    const shadow_rows = try admin_pg.fetchAll(&check_shadow);
    defer deinitFetchedRows(allocator, shadow_rows);

    if (shadow_rows.len > 0) {
        print("  [1/4] Recreating existing shadow database: {s}\n", .{shadow_name});
        const drop_cmd = QailCmd.dropDatabase(shadow_name);
        _ = try admin_pg.execute(&drop_cmd);
    } else {
        print("  [1/4] Creating shadow database: {s}\n", .{shadow_name});
    }
    const create_cmd = QailCmd.createDatabase(shadow_name);
    _ = try admin_pg.execute(&create_cmd);

    const shadow_url = try rewriteDatabaseInUrl(allocator, url, shadow_name);
    defer allocator.free(shadow_url);
    var shadow_pg = connectPgUrl(allocator, shadow_url) catch |err| {
        print("Error connecting to shadow database: {}\n", .{err});
        return err;
    };
    defer shadow_pg.deinit();

    var empty_schema = parser.Schema.init(allocator);
    defer empty_schema.deinit();

    var base_cmds = parser.diffSchemas(allocator, &empty_schema, &old_schema) catch |err| {
        print("Error building shadow base schema commands: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &base_cmds);

    var diff_cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
        print("Error building shadow migration commands: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &diff_cmds);

    print("  [2/4] Applying base schema to shadow ({d} command(s))\n", .{base_cmds.items.len});
    try executeMigrationCmds(allocator, &shadow_pg, base_cmds.items, "base");

    print("  [3/4] Applying migration diff to shadow ({d} command(s))\n", .{diff_cmds.items.len});
    try executeMigrationCmds(allocator, &shadow_pg, diff_cmds.items, "diff");

    var primary_pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to primary database: {}\n", .{err});
        return err;
    };
    defer primary_pg.deinit();

    const state_schema_diff = if (effective_schema_diff) |owned| owned else schema_diff;

    print("  [4/4] Saving shadow migration receipt\n", .{});
    try saveShadowState(allocator, &primary_pg, url, state_schema_diff, shadow_name);

    print("\n✅ Shadow migration prepared\n", .{});
    print("  Shadow DB: {s}\n", .{shadow_name});
    print("  Promote: qail migrate promote {s}\n", .{url});
    print("  Abort:   qail migrate abort {s}\n", .{url});
}

fn runMigratePromote(allocator: Allocator, url: []const u8) !void {
    const parser = @import("parser/mod.zig");

    print("🔄 Shadow Promotion\n\n", .{});
    print("  URL: {s}\n\n", .{url});

    var primary_pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to primary database: {}\n", .{err});
        return err;
    };
    defer primary_pg.deinit();

    var state = (try loadActiveShadowState(allocator, &primary_pg)) orelse {
        print("No pending shadow migration found. Run 'qail migrate shadow' first.\n", .{});
        return error.MissingShadowState;
    };
    defer state.deinit(allocator);

    const diff = parseSchemaDiffPath(state.schema_diff);
    if (diff.old == null or diff.new == null) {
        print("Error: Saved shadow state has invalid schema diff path: {s}\n", .{state.schema_diff});
        return error.InvalidShadowStateRow;
    }

    const old_content = readFileAlloc(allocator, diff.old.?, 8 * 1024 * 1024) catch |err| {
        print("Error reading old schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(old_content);

    const new_content = readFileAlloc(allocator, diff.new.?, 8 * 1024 * 1024) catch |err| {
        print("Error reading new schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(new_content);

    var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
        print("Error parsing old schema: {}\n", .{err});
        return err;
    };
    defer old_schema.deinit();

    var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
        print("Error parsing new schema: {}\n", .{err});
        return err;
    };
    defer new_schema.deinit();

    var diff_cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
        print("Error computing promotion diff: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &diff_cmds);

    print("  [1/3] Applying {d} migration command(s) on primary\n", .{diff_cmds.items.len});
    try primary_pg.begin();
    executeMigrationCmds(allocator, &primary_pg, diff_cmds.items, "promote") catch |err| {
        primary_pg.rollback() catch {};
        return err;
    };
    try primary_pg.commit();

    print("  [2/3] Dropping shadow database: {s}\n", .{state.shadow_name});
    const admin_url = try rewriteDatabaseInUrl(allocator, url, "postgres");
    defer allocator.free(admin_url);
    var admin_pg = connectPgUrl(allocator, admin_url) catch |err| {
        print("Error connecting to admin database: {}\n", .{err});
        return err;
    };
    defer admin_pg.deinit();
    const drop_cmd = QailCmd.dropDatabase(state.shadow_name);
    _ = try admin_pg.execute(&drop_cmd);

    print("  [3/3] Marking shadow state as promoted\n", .{});
    try updateShadowStateStatus(&primary_pg, "promoted");
    print("\n✅ Shadow promoted successfully\n", .{});
}

fn runMigrateAbort(allocator: Allocator, url: []const u8) !void {
    print("❌ Shadow Abort\n\n", .{});
    print("  URL: {s}\n\n", .{url});

    var primary_pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to primary database: {}\n", .{err});
        return err;
    };
    defer primary_pg.deinit();

    var state = (try loadActiveShadowState(allocator, &primary_pg)) orelse {
        print("No pending shadow migration found.\n", .{});
        return error.MissingShadowState;
    };
    defer state.deinit(allocator);

    print("  [1/2] Dropping shadow database: {s}\n", .{state.shadow_name});
    const admin_url = try rewriteDatabaseInUrl(allocator, url, "postgres");
    defer allocator.free(admin_url);
    var admin_pg = connectPgUrl(allocator, admin_url) catch |err| {
        print("Error connecting to admin database: {}\n", .{err});
        return err;
    };
    defer admin_pg.deinit();
    const drop_cmd = QailCmd.dropDatabase(state.shadow_name);
    _ = try admin_pg.execute(&drop_cmd);

    print("  [2/2] Marking shadow state as aborted\n", .{});
    try updateShadowStateStatus(&primary_pg, "aborted");
    print("\n✅ Shadow migration aborted\n", .{});
}

fn ensureMigrationTable(
    pg: *@import("driver/driver.zig").PgDriver,
) !void {
    const parser = @import("parser/mod.zig");
    const mig_cmd = parser.getMigrationTableCmd();
    _ = try pg.execute(&mig_cmd);
}

fn recordMigrationReceiptWithVersion(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    version: []const u8,
    name: []const u8,
    sql_up: []const u8,
) !void {
    const parser = @import("parser/mod.zig");
    const Value = @import("ast/cmd.zig").Value;

    try ensureMigrationTable(pg);

    const checksum = parser.computeChecksum(sql_up);
    const checksum_str = try std.fmt.allocPrint(allocator, "{x:0>16}", .{checksum});
    defer allocator.free(checksum_str);

    const record_cmd = QailCmd{
        .kind = .add,
        .table = "_qail_migrations",
        .columns = &[_]Expr{
            Expr.col("version"),
            Expr.col("name"),
            Expr.col("checksum"),
            Expr.col("sql_up"),
        },
        .insert_values = &[_]Value{
            Value.fromString(version),
            Value.fromString(name),
            Value.fromString(checksum_str),
            Value.fromString(sql_up),
        },
    };
    _ = try pg.execute(&record_cmd);
}

fn recordMigrationReceipt(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
    name: []const u8,
    sql_up: []const u8,
) ![14]u8 {
    const parser = @import("parser/mod.zig");
    const version = parser.generateVersion();
    try recordMigrationReceiptWithVersion(allocator, pg, &version, name, sql_up);
    return version;
}

fn runMigrateRollback(
    allocator: Allocator,
    schema_diff: []const u8,
    url: []const u8,
    operation: []const u8,
    wait_for_lock: bool,
    lock_timeout_secs: ?u64,
) !void {
    const parser = @import("parser/mod.zig");
    const diff = parseSchemaDiffPath(schema_diff);
    if (diff.old == null or diff.new == null) {
        print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
        return;
    }

    print("⏪ Applying rollback: {s}\n", .{schema_diff});
    print("Database: {s}\n\n", .{url});

    const old_content = readFileAlloc(allocator, diff.old.?, 8 * 1024 * 1024) catch |err| {
        print("Error reading old schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(old_content);

    const new_content = readFileAlloc(allocator, diff.new.?, 8 * 1024 * 1024) catch |err| {
        print("Error reading new schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(new_content);

    var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
        print("Error parsing old schema: {}\n", .{err});
        return err;
    };
    defer old_schema.deinit();

    var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
        print("Error parsing new schema: {}\n", .{err});
        return err;
    };
    defer new_schema.deinit();

    // Reverse the diff direction to roll schema back from `new` to `old`.
    var rollback_cmds = parser.diffSchemas(allocator, &new_schema, &old_schema) catch |err| {
        print("Error computing rollback diff: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &rollback_cmds);

    if (rollback_cmds.items.len == 0) {
        print("✅ No rollback needed\n", .{});
        return;
    }

    const rollback_sql = parser.toSqlStatements(allocator, &rollback_cmds) catch |err| {
        print("Error generating rollback SQL: {}\n", .{err});
        return err;
    };
    defer allocator.free(rollback_sql);

    print("Executing {d} rollback operation(s)...\n", .{rollback_cmds.items.len});
    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();
    try acquireMigrationLock(
        allocator,
        &pg,
        operation,
        url,
        wait_for_lock,
        lock_timeout_secs,
    );

    try pg.begin();
    executeMigrationCmds(allocator, &pg, rollback_cmds.items, "rollback") catch |err| {
        pg.rollback() catch {};
        return err;
    };

    var receipt_version: ?[14]u8 = null;
    receipt_version = recordMigrationReceipt(allocator, &pg, "rollback_migration", rollback_sql) catch |err| blk: {
        print("Warning: failed to record rollback receipt: {}\n", .{err});
        break :blk null;
    };

    try pg.commit();
    print("\n✅ Rollback applied successfully!\n", .{});
    if (receipt_version) |version| {
        print("  Recorded as migration: {s}\n", .{&version});
    }
}

fn runMigrateReset(
    allocator: Allocator,
    schema_path: []const u8,
    url: []const u8,
    wait_for_lock: bool,
    lock_timeout_secs: ?u64,
) !void {
    const parser = @import("parser/mod.zig");

    print("🔄 Resetting database to schema: {s}\n", .{schema_path});
    print("Database: {s}\n\n", .{url});

    const target_content = readFileAlloc(allocator, schema_path, 8 * 1024 * 1024) catch |err| {
        print("Error reading target schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(target_content);

    var target_schema = parser.Schema.parse(allocator, target_content) catch |err| {
        print("Error parsing target schema: {}\n", .{err});
        return err;
    };
    defer target_schema.deinit();

    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();
    try acquireMigrationLock(
        allocator,
        &pg,
        "migrate reset",
        url,
        wait_for_lock,
        lock_timeout_secs,
    );

    const live_snapshot = schema_ops.renderLiveSchemaSnapshot(allocator, &pg) catch |err| {
        print("Error introspecting live schema: {}\n", .{err});
        return err;
    };
    defer allocator.free(live_snapshot.schema);

    var live_schema = parser.Schema.parse(allocator, live_snapshot.schema) catch |err| {
        print("Error parsing live schema snapshot: {}\n", .{err});
        return err;
    };
    defer live_schema.deinit();

    var empty_schema = parser.Schema.init(allocator);
    defer empty_schema.deinit();

    var drop_cmds = parser.diffSchemas(allocator, &live_schema, &empty_schema) catch |err| {
        print("Error computing reset drop plan: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &drop_cmds);

    var create_cmds = parser.diffSchemas(allocator, &empty_schema, &target_schema) catch |err| {
        print("Error computing reset create plan: {}\n", .{err});
        return err;
    };
    defer deinitMigrationCmds(allocator, &create_cmds);

    print("  Live schema: {d} table(s), {d} column(s)\n", .{ live_snapshot.table_count, live_snapshot.column_count });
    print("  Drop commands: {d}\n", .{drop_cmds.items.len});
    print("  Create commands: {d}\n\n", .{create_cmds.items.len});

    try pg.begin();

    if (drop_cmds.items.len > 0) {
        executeMigrationCmds(allocator, &pg, drop_cmds.items, "reset-drop") catch |err| {
            pg.rollback() catch {};
            return err;
        };
    }

    const clear_history = QailCmd.del("_qail_migrations");
    _ = pg.execute(&clear_history) catch |err| {
        print("Warning: failed to clear migration history (continuing): {}\n", .{err});
    };

    if (create_cmds.items.len > 0) {
        executeMigrationCmds(allocator, &pg, create_cmds.items, "reset-create") catch |err| {
            pg.rollback() catch {};
            return err;
        };
    }

    const reset_summary = try std.fmt.allocPrint(
        allocator,
        "source=reset;drop_cmds={d};create_cmds={d}",
        .{ drop_cmds.items.len, create_cmds.items.len },
    );
    defer allocator.free(reset_summary);

    var receipt_version: ?[14]u8 = null;
    receipt_version = recordMigrationReceipt(allocator, &pg, "reset_migration", reset_summary) catch |err| blk: {
        print("Warning: failed to record reset receipt: {}\n", .{err});
        break :blk null;
    };

    try pg.commit();
    print("✅ Reset applied successfully\n", .{});
    if (receipt_version) |version| {
        print("  Recorded as migration: {s}\n", .{&version});
    }
}

const MigrationFileEntry = struct {
    version: []u8,
    name: []u8,
    path: []u8,

    fn deinit(self: *MigrationFileEntry, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

fn deinitMigrationFileEntries(
    allocator: Allocator,
    entries: *std.ArrayList(MigrationFileEntry),
) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn lessThanMigrationFileEntry(_: void, a: MigrationFileEntry, b: MigrationFileEntry) bool {
    return std.mem.lessThan(u8, a.version, b.version);
}

fn parseApplyPhaseValue(value: []const u8) ?ApplyPhase {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "expand")) return .expand;
    if (std.mem.eql(u8, value, "backfill")) return .backfill;
    if (std.mem.eql(u8, value, "contract")) return .contract;
    return null;
}

fn applyPhaseToken(phase: ApplyPhase) []const u8 {
    return switch (phase) {
        .all => "all",
        .expand => "expand",
        .backfill => "backfill",
        .contract => "contract",
    };
}

fn detectMigrationPhaseFromContent(content: []const u8) ?ApplyPhase {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var scanned: usize = 0;
    while (lines.next()) |line| {
        if (scanned >= 64) break;
        scanned += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var payload: ?[]const u8 = null;
        if (std.mem.startsWith(u8, trimmed, "-- @phase:")) {
            payload = std.mem.trim(u8, trimmed["-- @phase:".len..], " \t");
        } else if (std.mem.startsWith(u8, trimmed, "# @phase:")) {
            payload = std.mem.trim(u8, trimmed["# @phase:".len..], " \t");
        } else if (std.mem.startsWith(u8, trimmed, "--")) {
            continue;
        } else {
            break;
        }

        if (payload) |value| {
            return parseApplyPhaseValue(value);
        }
    }
    return null;
}

fn migrationFileMatchesPhase(
    allocator: Allocator,
    path: []const u8,
    phase: ApplyPhase,
) !bool {
    if (phase == .all) return true;

    const content = readFileAlloc(allocator, path, 512 * 1024) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer allocator.free(content);

    if (detectMigrationPhaseFromContent(content)) |phase_tag| {
        return phase_tag == phase;
    }

    const token = applyPhaseToken(phase);
    const dot_pat = try std.fmt.allocPrint(allocator, ".{s}.", .{token});
    defer allocator.free(dot_pat);
    const underscore_pat = try std.fmt.allocPrint(allocator, "_{s}_", .{token});
    defer allocator.free(underscore_pat);

    return std.mem.indexOf(u8, path, dot_pat) != null or std.mem.indexOf(u8, path, underscore_pat) != null;
}

fn collectUpMigrationFiles(allocator: Allocator) !std.ArrayList(MigrationFileEntry) {
    var entries: std.ArrayList(MigrationFileEntry) = .empty;
    errdefer deinitMigrationFileEntries(allocator, &entries);

    const io_iface = io_compat.runtimeIo();
    var dir = std.Io.Dir.cwd().openDir(io_iface, "migrations", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return entries;
        return err;
    };
    defer dir.close(io_iface);

    var iter = dir.iterate();
    while (try iter.next(io_iface)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".up.qail")) continue;

        const stem = entry.name[0 .. entry.name.len - ".up.qail".len];
        const split_idx = std.mem.indexOfScalar(u8, stem, '_');
        const name_slice = if (split_idx) |idx|
            stem[idx + 1 ..]
        else
            stem;

        try entries.append(allocator, .{
            .version = try allocator.dupe(u8, stem),
            .name = try allocator.dupe(u8, name_slice),
            .path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{entry.name}),
        });
    }

    std.mem.sort(MigrationFileEntry, entries.items, {}, lessThanMigrationFileEntry);
    return entries;
}

fn loadAppliedMigrationVersions(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
) !std.StringHashMap(void) {
    var applied = std.StringHashMap(void).init(allocator);
    errdefer deinitStringSet(allocator, &applied);

    try ensureMigrationTable(pg);

    const applied_cmd = QailCmd.get("_qail_migrations")
        .select(&.{
            Expr.col("version"),
        }).orderBy(&.{
        .{ .column = "version", .order = .asc },
    });
    const rows = try pg.fetchAll(&applied_cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const version = row.getByName("version") orelse continue;
        try putStringSetKey(allocator, &applied, version);
    }

    return applied;
}

fn runMigrateApply(
    allocator: Allocator,
    url: []const u8,
    direction: MigrationDirection,
    phase: ApplyPhase,
    wait_for_lock: bool,
    lock_timeout_secs: ?u64,
) !void {
    const parser = @import("parser/mod.zig");

    print("📦 Applying folder migrations\n\n", .{});
    print("  URL: {s}\n", .{url});
    print("  Directory: migrations/\n\n", .{});
    if (phase != .all) {
        print("  Phase filter: {s}\n\n", .{applyPhaseToken(phase)});
    }

    if (direction == .down) {
        if (phase != .all) {
            var preview_pg = connectPgUrl(allocator, url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return err;
            };
            defer preview_pg.deinit();

            var applied = try loadAppliedMigrationHistory(allocator, &preview_pg);
            defer deinitAppliedMigrationEntries(allocator, &applied);

            if (applied.items.len == 0) {
                print("No applied migrations found.\n", .{});
                return;
            }

            var rollback_count: usize = 0;
            var target_version: []const u8 = "base";
            var idx = applied.items.len;
            while (idx > 0) {
                idx -= 1;
                const entry = applied.items[idx];

                const matches_phase = blk: {
                    const down_path = try std.fmt.allocPrint(allocator, "migrations/{s}.down.qail", .{entry.version});
                    defer allocator.free(down_path);
                    break :blk try migrationFileMatchesPhase(allocator, down_path, phase);
                };
                if (!matches_phase) break;

                rollback_count += 1;
                target_version = if (idx == 0) "base" else applied.items[idx - 1].version;
            }

            if (rollback_count == 0) {
                print("✅ No rollback tail migrations for phase '{s}'\n", .{applyPhaseToken(phase)});
                return;
            }

            print(
                "↩ Rolling back {d} migration(s) for phase '{s}'\n",
                .{ rollback_count, applyPhaseToken(phase) },
            );
            try runMigrateRollbackToVersion(
                allocator,
                target_version,
                url,
                "migrate apply",
                wait_for_lock,
                lock_timeout_secs,
            );
            return;
        }

        try runMigrateRollbackToVersion(
            allocator,
            "base",
            url,
            "migrate apply",
            wait_for_lock,
            lock_timeout_secs,
        );
        return;
    }

    var migration_files = try collectUpMigrationFiles(allocator);
    defer deinitMigrationFileEntries(allocator, &migration_files);

    if (migration_files.items.len == 0) {
        print("No migration files found in migrations/\n", .{});
        return;
    }

    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();
    try acquireMigrationLock(
        allocator,
        &pg,
        "migrate apply",
        url,
        wait_for_lock,
        lock_timeout_secs,
    );

    var applied_versions = try loadAppliedMigrationVersions(allocator, &pg);
    defer deinitStringSet(allocator, &applied_versions);

    var pending_count: usize = 0;
    for (migration_files.items) |entry| {
        if (!try migrationFileMatchesPhase(allocator, entry.path, phase)) continue;
        if (!applied_versions.contains(entry.version)) pending_count += 1;
    }

    if (pending_count == 0) {
        print("✅ No pending migrations\n", .{});
        return;
    }

    var applied_count: usize = 0;
    for (migration_files.items) |entry| {
        if (!try migrationFileMatchesPhase(allocator, entry.path, phase)) continue;
        if (applied_versions.contains(entry.version)) continue;

        print("  [{d}/{d}] {s}\n", .{ applied_count + 1, pending_count, entry.path });

        const migration_content = readFileAlloc(allocator, entry.path, 16 * 1024 * 1024) catch |err| {
            print("Error reading migration file {s}: {}\n", .{ entry.path, err });
            return err;
        };
        defer allocator.free(migration_content);

        var statements = collectExecStatements(allocator, null, entry.path) catch |err| {
            print("Error collecting migration statements from {s}: {}\n", .{ entry.path, err });
            return err;
        };
        defer statements.deinit(allocator);

        try pg.begin();

        var success = true;
        for (statements.items.items, 0..) |stmt, stmt_idx| {
            var cmd = parser.parse(allocator, stmt) catch |err| {
                print("Parse error in {s} statement {d}: {}\n", .{ entry.path, stmt_idx + 1, err });
                success = false;
                break;
            };
            defer freeParsedCmd(allocator, &cmd);

            if (cmdReturnsRows(cmd.kind)) {
                const rows = pg.fetchAll(&cmd) catch |err| {
                    print("Execution error in {s} statement {d}: {}\n", .{ entry.path, stmt_idx + 1, err });
                    success = false;
                    break;
                };
                defer deinitFetchedRows(allocator, rows);
            } else {
                _ = pg.execute(&cmd) catch |err| {
                    print("Execution error in {s} statement {d}: {}\n", .{ entry.path, stmt_idx + 1, err });
                    success = false;
                    break;
                };
            }
        }

        if (!success) {
            pg.rollback() catch {};
            return error.MigrationApplyFailed;
        }

        recordMigrationReceiptWithVersion(
            allocator,
            &pg,
            entry.version,
            entry.name,
            migration_content,
        ) catch |err| {
            pg.rollback() catch {};
            print("Failed to record migration receipt for {s}: {}\n", .{ entry.version, err });
            return err;
        };

        try pg.commit();
        applied_count += 1;
        try putStringSetKey(allocator, &applied_versions, entry.version);

        print("    ✓ Applied {s}\n", .{entry.version});
    }

    print("\n✅ Applied {d} migration(s)\n", .{applied_count});
}

const AppliedMigrationEntry = struct {
    version: []u8,
    name: []u8,

    fn deinit(self: *AppliedMigrationEntry, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.name);
    }
};

fn deinitAppliedMigrationEntries(
    allocator: Allocator,
    entries: *std.ArrayList(AppliedMigrationEntry),
) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn loadAppliedMigrationHistory(
    allocator: Allocator,
    pg: *@import("driver/driver.zig").PgDriver,
) !std.ArrayList(AppliedMigrationEntry) {
    var entries: std.ArrayList(AppliedMigrationEntry) = .empty;
    errdefer deinitAppliedMigrationEntries(allocator, &entries);

    try ensureMigrationTable(pg);

    const status_cmd = QailCmd.get("_qail_migrations")
        .select(&.{
            Expr.col("version"),
            Expr.col("name"),
        }).orderBy(&.{
        .{ .column = "version", .order = .asc },
    });
    const rows = try pg.fetchAll(&status_cmd);
    defer deinitFetchedRows(allocator, rows);

    for (rows) |row| {
        const version = row.getByName("version") orelse continue;
        const name = row.getByName("name") orelse "";
        try entries.append(allocator, .{
            .version = try allocator.dupe(u8, version),
            .name = try allocator.dupe(u8, name),
        });
    }

    return entries;
}

fn runMigrateRollbackToVersion(
    allocator: Allocator,
    to: []const u8,
    url: []const u8,
    operation: []const u8,
    wait_for_lock: bool,
    lock_timeout_secs: ?u64,
) !void {
    const parser = @import("parser/mod.zig");

    print("⏮️ Rollback to target version\n\n", .{});
    print("  URL: {s}\n", .{url});
    print("  Target: {s}\n\n", .{to});

    var pg = connectPgUrl(allocator, url) catch |err| {
        print("Error connecting to database: {}\n", .{err});
        return err;
    };
    defer pg.deinit();
    try acquireMigrationLock(
        allocator,
        &pg,
        operation,
        url,
        wait_for_lock,
        lock_timeout_secs,
    );

    var applied = try loadAppliedMigrationHistory(allocator, &pg);
    defer deinitAppliedMigrationEntries(allocator, &applied);

    if (applied.items.len == 0) {
        print("No applied migrations found.\n", .{});
        return;
    }

    var start_idx: usize = 0;
    if (!std.mem.eql(u8, to, "base")) {
        const target_idx = for (applied.items, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.version, to)) break idx;
        } else {
            print("Target version not found in _qail_migrations: {s}\n", .{to});
            return error.MigrationTargetNotFound;
        };
        start_idx = target_idx + 1;
    }

    if (start_idx >= applied.items.len) {
        print("✅ Already at requested version\n", .{});
        return;
    }

    const rollback_count = applied.items.len - start_idx;
    print("Rolling back {d} migration(s)...\n", .{rollback_count});

    try pg.begin();

    var idx = applied.items.len;
    while (idx > start_idx) {
        idx -= 1;
        const entry = applied.items[idx];

        const down_path = try std.fmt.allocPrint(allocator, "migrations/{s}.down.qail", .{entry.version});
        defer allocator.free(down_path);

        print("  ↩ {s}\n", .{entry.version});

        var statements = collectExecStatements(allocator, null, down_path) catch |err| {
            pg.rollback() catch {};
            print("Failed to load rollback migration {s}: {}\n", .{ down_path, err });
            return err;
        };
        defer statements.deinit(allocator);

        for (statements.items.items, 0..) |stmt, stmt_idx| {
            var cmd = parser.parse(allocator, stmt) catch |err| {
                pg.rollback() catch {};
                print("Parse error in {s} statement {d}: {}\n", .{ down_path, stmt_idx + 1, err });
                return err;
            };
            defer freeParsedCmd(allocator, &cmd);

            if (cmdReturnsRows(cmd.kind)) {
                const rows = pg.fetchAll(&cmd) catch |err| {
                    pg.rollback() catch {};
                    print("Execution error in {s} statement {d}: {}\n", .{ down_path, stmt_idx + 1, err });
                    return err;
                };
                defer deinitFetchedRows(allocator, rows);
            } else {
                _ = pg.execute(&cmd) catch |err| {
                    pg.rollback() catch {};
                    print("Execution error in {s} statement {d}: {}\n", .{ down_path, stmt_idx + 1, err });
                    return err;
                };
            }
        }

        const delete_cmd = QailCmd.del("_qail_migrations").where(&.{
            .{ .condition = .{ .column = "version", .op = .eq, .value = .{ .string = entry.version } } },
        });
        _ = pg.execute(&delete_cmd) catch |err| {
            pg.rollback() catch {};
            print("Failed to delete migration receipt {s}: {}\n", .{ entry.version, err });
            return err;
        };
    }

    const rollback_summary = try std.fmt.allocPrint(
        allocator,
        "source=rollback_to;to={s};rolled_back={d}",
        .{ to, rollback_count },
    );
    defer allocator.free(rollback_summary);

    _ = recordMigrationReceipt(allocator, &pg, "rollback_to", rollback_summary) catch |err| {
        pg.rollback() catch {};
        print("Failed to record rollback receipt: {}\n", .{err});
        return err;
    };

    try pg.commit();
    print("✅ Rolled back {d} migration(s)\n", .{rollback_count});
}

fn runMigrate(allocator: Allocator, action: MigrateAction) !void {
    const parser = @import("parser/mod.zig");

    switch (action) {
        .status => |url| {
            const resolved_url = try resolveDatabaseUrl(url);
            try runMigrateStatus(allocator, resolved_url);
        },
        .plan => |p| {
            // Parse schema_diff as old.qail:new.qail
            const diff = parseSchemaDiffPath(p.schema_diff);
            if (diff.old == null or diff.new == null) {
                print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                return;
            }

            print("📋 Migration Plan (dry-run)\n\n", .{});
            print("  {s} → {s}\n\n", .{ diff.old.?, diff.new.? });

            // Load schema files
            const old_content = readFileAlloc(allocator, diff.old.?, 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return;
            };
            defer allocator.free(old_content);

            const new_content = readFileAlloc(allocator, diff.new.?, 1024 * 1024) catch |err| {
                print("Error reading new schema: {}\n", .{err});
                return;
            };
            defer allocator.free(new_content);

            // Parse schemas
            var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
                print("Error parsing old schema: {}\n", .{err});
                return;
            };
            defer old_schema.deinit();

            var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                print("Error parsing new schema: {}\n", .{err});
                return;
            };
            defer new_schema.deinit();

            // Compute diff
            var cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                print("Error computing diff: {}\n", .{err});
                return;
            };
            defer deinitMigrationCmds(allocator, &cmds);

            if (cmds.items.len == 0) {
                print("✅ No migrations needed - schemas are identical\n", .{});
                return;
            }

            // Generate SQL
            const sql = parser.toSqlStatements(allocator, &cmds) catch |err| {
                print("Error generating SQL: {}\n", .{err});
                return;
            };
            defer allocator.free(sql);

            print("┌─ UP ({d} operations) ─────────────────────────────────┐\n", .{cmds.items.len});
            print("{s}", .{sql});
            print("└──────────────────────────────────────────────────────────────┘\n\n", .{});

            // Generate and show DOWN migrations
            print("┌─ DOWN ({d} operations) ──────────────────────────────┐\n", .{cmds.items.len});
            for (cmds.items) |*migration_cmd| {
                const down_sql = migration_cmd.toDownSql(allocator) catch continue;
                defer allocator.free(down_sql);
                print("│ {s}\n", .{down_sql});
            }
            print("└──────────────────────────────────────────────────────────────┘\n", .{});

            if (p.output) |output_path| {
                var out = io_compat.AllocatingWriter.init(allocator);
                defer out.deinit();
                const writer = out.writer();
                try writer.print("-- Migration UP ({d} operations)\n", .{cmds.items.len});
                try writer.writeAll(sql);
                if (sql.len == 0 or sql[sql.len - 1] != '\n') {
                    try writer.writeAll("\n");
                }
                try writer.print("\n-- Migration DOWN ({d} operations)\n", .{cmds.items.len});
                for (cmds.items) |*migration_cmd| {
                    const down_sql = migration_cmd.toDownSql(allocator) catch continue;
                    defer allocator.free(down_sql);
                    try writer.print("{s};\n", .{down_sql});
                }

                const output_content = try out.toOwnedSlice();
                defer allocator.free(output_content);

                std.Io.Dir.cwd().writeFile(io_compat.runtimeIo(), .{
                    .sub_path = output_path,
                    .data = output_content,
                    .flags = .{
                        .truncate = true,
                    },
                }) catch |err| {
                    print("Error writing plan output {s}: {}\n", .{ output_path, err });
                    return err;
                };
                print("✅ Plan saved to {s}\n", .{output_path});
            }
        },
        .up => |u| {
            const resolved_url = try resolveDatabaseUrl(u.url);
            if (u.allow_destructive or u.allow_no_shadow_receipt or u.allow_lock_risk) {
                print("⚠️ migrate up: allow-* guard flags are parsed; zig CLI guardrails are currently limited\n", .{});
            }
            const diff = parseSchemaDiffPath(u.schema_diff);
            if (diff.old == null or diff.new == null) {
                print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                return;
            }

            print("⬆️ Applying migration: {s}\n", .{u.schema_diff});
            print("Database: {s}\n\n", .{resolved_url});

            // Load schema files
            const old_content = readFileAlloc(allocator, diff.old.?, 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return;
            };
            defer allocator.free(old_content);

            const new_content = readFileAlloc(allocator, diff.new.?, 1024 * 1024) catch |err| {
                print("Error reading new schema: {}\n", .{err});
                return;
            };
            defer allocator.free(new_content);

            // Parse schemas
            var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
                print("Error parsing old schema: {}\n", .{err});
                return;
            };
            defer old_schema.deinit();

            var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                print("Error parsing new schema: {}\n", .{err});
                return;
            };
            defer new_schema.deinit();

            // Compute diff
            var cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                print("Error computing diff: {}\n", .{err});
                return;
            };
            defer {
                // Free table_columns allocations first
                for (cmds.items) |cmd| {
                    if (cmd.table_columns.len > 0) {
                        allocator.free(cmd.table_columns);
                    }
                }
                cmds.deinit(allocator);
            }

            if (cmds.items.len == 0) {
                print("✅ No migrations needed\n", .{});
                return;
            }

            if (u.codebase) |codebase| {
                const scanner_mod = @import("analyzer/scanner.zig");
                const impact_mod = @import("analyzer/impact.zig");

                print("🔎 Codebase impact scan: {s}\n", .{codebase});
                var scanner = scanner_mod.CodebaseScanner.init(allocator);
                defer scanner.deinit();

                scanner.scan(codebase) catch |err| {
                    print("Error scanning codebase: {}\n", .{err});
                    return err;
                };

                var impact = impact_mod.MigrationImpact.analyze(
                    allocator,
                    cmds.items,
                    scanner.refs.items,
                ) catch |err| {
                    print("Error analyzing migration impact: {}\n", .{err});
                    return err;
                };
                defer impact.deinit();

                const impact_report = impact.report(allocator) catch |err| {
                    print("Error rendering impact report: {}\n", .{err});
                    return err;
                };
                defer allocator.free(impact_report);

                print("  Operations: {d}\n", .{cmds.items.len});
                print("  Query references scanned: {d}\n", .{scanner.refs.items.len});
                print("{s}\n", .{impact_report});

                if (!impact.safe_to_run and !u.force) {
                    print("❌ Unsafe migration impact detected. Re-run with --force to proceed.\n", .{});
                    return error.MigrationUnsafe;
                }
                if (!impact.safe_to_run and u.force) {
                    print("⚠️ Unsafe migration impact ignored due to --force\n", .{});
                }
            }

            // Generate SQL
            const sql = parser.toSqlStatements(allocator, &cmds) catch |err| {
                print("Error generating SQL: {}\n", .{err});
                return;
            };
            defer allocator.free(sql);

            print("Executing {d} operation(s)...\n", .{cmds.items.len});

            var pg = connectPgUrl(allocator, resolved_url) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return;
            };
            defer pg.deinit();
            try acquireMigrationLock(
                allocator,
                &pg,
                "migrate up",
                resolved_url,
                u.wait_for_lock,
                u.lock_timeout_secs,
            );

            // === PHASE 1: Impact Analysis ===
            var analysis = data_safety.ImpactAnalysis.init(allocator);
            data_safety.analyzeImpact(allocator, cmds.items, &pg, &analysis) catch |err| {
                print("Warning: Could not analyze impact: {}\n", .{err});
                // Continue anyway - analysis is advisory
            };
            defer analysis.deinit();

            var migration_version: []const u8 = "";

            if (analysis.hasDestructive()) {
                data_safety.displayImpact(&analysis);

                const choice = data_safety.promptBackupOptions();
                switch (choice) {
                    .proceed => {
                        print("Proceeding without backup...\n", .{});
                    },
                    .backup_to_file => {
                        print("File backup not yet implemented. Proceeding...\n", .{});
                    },
                    .backup_to_db => {
                        // Generate version for this migration
                        const version_buf = parser.generateVersion();
                        migration_version = &version_buf;
                        _ = data_safety.createDbSnapshots(allocator, &pg, migration_version, &analysis) catch |err| {
                            print("Warning: Backup failed: {}. Aborting.\n", .{err});
                            return;
                        };
                    },
                    .cancel => {
                        print("Migration cancelled.\n", .{});
                        return;
                    },
                }
            }

            // Begin transaction
            pg.begin() catch |err| {
                print("Error starting transaction: {}\n", .{err});
                return;
            };

            // Execute each migration command using AST-native execution
            var success = true;
            for (cmds.items) |migration_cmd| {
                // Convert to AST command (no raw SQL!)
                const qail_cmd = migration_cmd.toQailCmd(allocator) catch |err| {
                    print("Error converting migration: {}\n", .{err});
                    success = false;
                    break;
                };
                // Free heap-allocated columns after this iteration
                defer if (qail_cmd.columns.len > 0) {
                    // Cast away const for deallocation (columns were heap-allocated by toQailCmd)
                    const cols_ptr: [*]const Expr = qail_cmd.columns.ptr;
                    const cols_many: [*]Expr = @constCast(cols_ptr);
                    allocator.free(cols_many[0..qail_cmd.columns.len]);
                };

                // Show what we're executing
                const stmt_sql = migration_cmd.toSql(allocator) catch continue;
                defer allocator.free(stmt_sql);
                print("  {s};\n", .{stmt_sql});

                // Execute via AST-native path
                _ = pg.execute(&qail_cmd) catch |err| {
                    print("Error executing: {}\n", .{err});
                    success = false;
                    break;
                };
            }

            if (success) {
                // Record migration in history (AST-native - no raw SQL!)
                const version = parser.generateVersion();
                const checksum = parser.computeChecksum(sql);
                const checksum_str = std.fmt.allocPrint(allocator, "{x:0>16}", .{checksum}) catch "0";
                defer allocator.free(checksum_str);

                const Value = @import("ast/cmd.zig").Value;

                // Build INSERT using AST-native columns + insert_values (like qail.rs)
                const record_cmd = QailCmd{
                    .kind = .add,
                    .table = "_qail_migrations",
                    .columns = &[_]Expr{
                        Expr.col("version"),
                        Expr.col("name"),
                        Expr.col("checksum"),
                        Expr.col("sql_up"),
                    },
                    .insert_values = &[_]Value{
                        Value.fromString(&version),
                        Value.fromString("auto_migration"),
                        Value.fromString(checksum_str),
                        Value.fromString("migrated"),
                    },
                };
                _ = pg.execute(&record_cmd) catch {}; // Best effort recording

                pg.commit() catch |err| {
                    print("Error committing: {}\n", .{err});
                    return;
                };
                print("\n✅ Migration applied successfully!\n", .{});
                print("  Recorded as migration: {s}\n", .{&version});
            } else {
                pg.rollback() catch {};
                print("\n❌ Migration failed, rolled back\n", .{});
            }
        },
        .down => |d| {
            const resolved_url = try resolveDatabaseUrl(d.url);
            try runMigrateRollback(
                allocator,
                d.schema_diff,
                resolved_url,
                "migrate down",
                d.wait_for_lock,
                d.lock_timeout_secs,
            );
        },
        .apply => |a| {
            const resolved_url = try resolveDatabaseUrl(a.url);
            if (a.codebase != null or a.allow_contract_with_references or a.allow_destructive or a.allow_no_shadow_receipt or a.allow_lock_risk or a.adopt_existing or a.backfill_chunk_size != 5000) {
                print("⚠️ migrate apply: advanced safety/backfill flags are parsed; execution currently uses base folder apply flow\n", .{});
            }
            try runMigrateApply(
                allocator,
                resolved_url,
                a.direction,
                a.phase,
                a.wait_for_lock,
                a.lock_timeout_secs,
            );
        },
        .rollback => |r| {
            const resolved_url = try resolveDatabaseUrl(r.url);
            if (r.to) |target| {
                try runMigrateRollbackToVersion(
                    allocator,
                    target,
                    resolved_url,
                    "migrate rollback",
                    r.wait_for_lock,
                    r.lock_timeout_secs,
                );
            } else if (r.schema_diff) |schema_diff| {
                try runMigrateRollback(
                    allocator,
                    schema_diff,
                    resolved_url,
                    "migrate rollback",
                    r.wait_for_lock,
                    r.lock_timeout_secs,
                );
            } else {
                return error.MissingArgument;
            }
        },
        .reset => |r| {
            const resolved_url = try resolveDatabaseUrl(r.url);
            try runMigrateReset(
                allocator,
                r.schema,
                resolved_url,
                r.wait_for_lock,
                r.lock_timeout_secs,
            );
        },
        .create => |c| {
            const timestamp_ms = std.Io.Clock.now(.real, io_compat.runtimeIo()).toMilliseconds();
            const io_iface = io_compat.runtimeIo();

            try std.Io.Dir.cwd().createDirPath(io_iface, "migrations");

            const safe_name = try slugifyMigrationName(allocator, c.name);
            defer allocator.free(safe_name);

            const migration_id = try std.fmt.allocPrint(allocator, "{d}_{s}", .{ timestamp_ms, safe_name });
            defer allocator.free(migration_id);

            const up_filename = try std.fmt.allocPrint(allocator, "{s}.up.qail", .{migration_id});
            defer allocator.free(up_filename);
            const down_filename = try std.fmt.allocPrint(allocator, "{s}.down.qail", .{migration_id});
            defer allocator.free(down_filename);

            const up_path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{up_filename});
            defer allocator.free(up_path);
            const down_path = try std.fmt.allocPrint(allocator, "migrations/{s}", .{down_filename});
            defer allocator.free(down_path);

            var header = io_compat.AllocatingWriter.init(allocator);
            defer header.deinit();
            const header_writer = header.writer();
            try header_writer.print("-- @name: {s}\n", .{migration_id});
            try header_writer.print("-- @created_unix_ms: {d}\n", .{timestamp_ms});
            if (c.author) |author| {
                try header_writer.print("-- @author: {s}\n", .{author});
            }
            if (c.depends) |depends| {
                try header_writer.print("-- @depends: {s}\n", .{depends});
            }
            const meta_header = try header.toOwnedSlice();
            defer allocator.free(meta_header);

            var up_body = io_compat.AllocatingWriter.init(allocator);
            defer up_body.deinit();
            const up_writer = up_body.writer();
            try up_writer.print("{s}\n\n", .{meta_header});
            try up_writer.writeAll(
                \\
                \\-- Add your UP migration below:
                \\-- Example: table users (id uuid primary_key)
                \\
            );
            const up_content = try up_body.toOwnedSlice();
            defer allocator.free(up_content);

            var down_body = io_compat.AllocatingWriter.init(allocator);
            defer down_body.deinit();
            const down_writer = down_body.writer();
            try down_writer.print("{s}\n\n", .{meta_header});
            try down_writer.writeAll(
                \\
                \\-- Add your DOWN (rollback) migration below:
                \\-- Example: drop users
                \\
            );
            const down_content = try down_body.toOwnedSlice();
            defer allocator.free(down_content);

            var created_up = false;
            errdefer if (created_up) {
                std.Io.Dir.cwd().deleteFile(io_iface, up_path) catch {};
            };

            std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = up_path,
                .data = up_content,
                .flags = .{
                    .truncate = false,
                    .exclusive = true,
                },
            }) catch |err| {
                if (err == error.PathAlreadyExists) {
                    print("Migration file already exists: {s}\n", .{up_path});
                    return error.PathAlreadyExists;
                }
                return err;
            };
            created_up = true;

            std.Io.Dir.cwd().writeFile(io_iface, .{
                .sub_path = down_path,
                .data = down_content,
                .flags = .{
                    .truncate = false,
                    .exclusive = true,
                },
            }) catch |err| {
                if (err == error.PathAlreadyExists) {
                    print("Migration file already exists: {s}\n", .{down_path});
                    return error.PathAlreadyExists;
                }
                return err;
            };
            created_up = false;

            print("📝 Created migration files:\n", .{});
            print("  ✓ {s}\n", .{up_path});
            print("  ✓ {s}\n", .{down_path});
        },
        .shadow => |s| {
            const resolved_url = try resolveDatabaseUrl(s.url);
            try runMigrateShadow(allocator, s.schema_diff, resolved_url, s.live);
        },
        .promote => |url| {
            const resolved_url = try resolveDatabaseUrl(url);
            try runMigratePromote(allocator, resolved_url);
        },
        .abort => |url| {
            const resolved_url = try resolveDatabaseUrl(url);
            try runMigrateAbort(allocator, resolved_url);
        },
        .analyze => |a| {
            const scanner_mod = @import("analyzer/scanner.zig");
            const impact_mod = @import("analyzer/impact.zig");

            const diff = parseSchemaDiffPath(a.schema_diff);
            if (diff.old == null or diff.new == null) {
                print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                return;
            }

            if (!a.json) {
                print("🔍 Migration Impact Analysis\n\n", .{});
                print("  Diff: {s} → {s}\n", .{ diff.old.?, diff.new.? });
                print("  Codebase: {s}\n\n", .{a.codebase});
            }

            const old_content = readFileAlloc(allocator, diff.old.?, 8 * 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return err;
            };
            defer allocator.free(old_content);

            const new_content = readFileAlloc(allocator, diff.new.?, 8 * 1024 * 1024) catch |err| {
                print("Error reading new schema: {}\n", .{err});
                return err;
            };
            defer allocator.free(new_content);

            var old_schema = parser.Schema.parse(allocator, old_content) catch |err| {
                print("Error parsing old schema: {}\n", .{err});
                return err;
            };
            defer old_schema.deinit();

            var new_schema = parser.Schema.parse(allocator, new_content) catch |err| {
                print("Error parsing new schema: {}\n", .{err});
                return err;
            };
            defer new_schema.deinit();

            var cmds = parser.diffSchemas(allocator, &old_schema, &new_schema) catch |err| {
                print("Error computing diff: {}\n", .{err});
                return err;
            };
            defer deinitMigrationCmds(allocator, &cmds);

            if (cmds.items.len == 0) {
                print("✅ No schema changes detected\n", .{});
                return;
            }

            var scanner = scanner_mod.CodebaseScanner.init(allocator);
            defer scanner.deinit();

            scanner.scan(a.codebase) catch |err| {
                print("Error scanning codebase: {}\n", .{err});
                return err;
            };

            var impact = impact_mod.MigrationImpact.analyze(
                allocator,
                cmds.items,
                scanner.refs.items,
            ) catch |err| {
                print("Error analyzing migration impact: {}\n", .{err});
                return err;
            };
            defer impact.deinit();

            const report = impact.report(allocator) catch |err| {
                print("Error rendering report: {}\n", .{err});
                return err;
            };
            defer allocator.free(report);

            if (a.json) {
                const payload = .{
                    .schema_diff = a.schema_diff,
                    .codebase = a.codebase,
                    .operations = cmds.items.len,
                    .query_references_scanned = scanner.refs.items.len,
                    .safe_to_run = impact.safe_to_run,
                    .report = report,
                };
                var encoded = io_compat.AllocatingWriter.init(allocator);
                defer encoded.deinit();
                try std.json.Stringify.value(payload, .{}, encoded.writer());
                const json_payload = try encoded.toOwnedSlice();
                defer allocator.free(json_payload);
                print("{s}\n", .{json_payload});
            } else {
                print("  Operations: {d}\n", .{cmds.items.len});
                print("  Query references scanned: {d}\n\n", .{scanner.refs.items.len});
                print("{s}", .{report});
            }

            if (a.ci and !impact.safe_to_run) {
                print("::error::Migration impact check failed for {s}\n", .{a.schema_diff});
            }

            if (!impact.safe_to_run) {
                return error.MigrationUnsafe;
            }
        },
    }
}

fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io_compat.runtimeIo(),
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

/// Parse schema diff path (old.qail:new.qail)
fn parseSchemaDiffPath(path: []const u8) struct { old: ?[]const u8, new: ?[]const u8 } {
    if (std.mem.indexOf(u8, path, ":")) |idx| {
        return .{
            .old = path[0..idx],
            .new = path[idx + 1 ..],
        };
    }
    return .{ .old = null, .new = null };
}

fn showHelp() void {
    print(
        \\🪝 QAIL — Schema-First Database Toolkit
        \\
        \\Usage: qail <QUERY> [OPTIONS]
        \\       qail <COMMAND> [ARGS]
        \\
        \\Commands:
        \\  init [DIR]                  Initialize schema + migrations scaffold
        \\  repl                        Interactive REPL mode
        \\  explain <QUERY>             Parse and explain a query
        \\  symbols                     Show symbol reference
        \\  fmt <QUERY>                 Format to canonical syntax
        \\  exec [QUERY] [--file PATH] [--url URL] [--tx] [--dry-run] [--json]
        \\  seed [--file PATH] [--url URL] [--tx] [--dry-run]
        \\  types [SCHEMA]              Generate Rust structs from schema
        \\  pull <URL>                  Extract schema from database
        \\  check <SCHEMA>              Validate a schema file
        \\  diff <OLD> <NEW>            Compare two schemas
        \\  lint <SCHEMA>               Check for issues
        \\  mig <NAME> [--depends X] [--author Y]
        \\  watch <SCHEMA> [--url <URL>] [--auto-apply]
        \\  migrate <ACTION>            Run migrations
        \\
        \\Options:
        \\  -f, --format <sql|json|pretty>   Output format for direct query mode
        \\  -d, --dialect <postgres|sqlite>  Target SQL dialect for direct query mode
        \\  -v, --verbose                     Show input query before output
        \\  -h, --help                        Show help
        \\  -V, --version                     Show version
        \\
        \\Database URL Resolution:
        \\  --url value, positional URL, or env QAIL_DATABASE_URL / DATABASE_URL
        \\
        \\Migrate Actions:
        \\  status <URL>                Show migration status
        \\  plan <DIFF>                 Preview migration SQL
        \\  up <DIFF> <URL> [-c <PATH>] [--force] [--wait-for-lock] [--lock-timeout-secs N]
        \\  down <DIFF> <URL> [--force] [--wait-for-lock] [--lock-timeout-secs N]
        \\  apply <URL> [--direction up|down] [--phase P] [--wait-for-lock]
        \\  rollback --to <VER|base> <URL> [--wait-for-lock] [--lock-timeout-secs N]
        \\  reset <SCHEMA> <URL> [--wait-for-lock] [--lock-timeout-secs N]
        \\  create <NAME>               Create migration up/down file pair
        \\  shadow <DIFF|SCHEMA> <URL> [--live] Apply to shadow database
        \\  promote <URL>               Promote shadow to primary
        \\  abort <URL>                 Abort shadow migration
        \\
        \\Examples:
        \\  qail init
        \\  qail --format json "get users fields id"
        \\  qail exec "get users fields id" --dry-run
        \\  qail seed --file seed.qail --dry-run
        \\  qail types schema.qail > src/types.rs
        \\  qail pull postgres://localhost/mydb
        \\  qail mig add_user_avatars --author orion
        \\  qail watch schema.qail --url postgres://localhost/mydb --auto-apply
        \\  qail migrate --help
        \\  qail migrate status postgres://localhost/mydb
        \\
    , .{});
}

fn showMigrateHelp() void {
    print(
        \\Apply migrations from schema diff
        \\
        \\Usage: qail migrate <ACTION> [ARGS]
        \\(URL may come from --url, positional arg, or QAIL_DATABASE_URL / DATABASE_URL)
        \\
        \\Actions:
        \\  status <URL>                     Show migration status
        \\  analyze <DIFF> [-c <PATH>] [--ci] [--json]
        \\                                   Analyze migration impact vs codebase refs
        \\  plan <DIFF> [-o <FILE>]          Preview migration SQL
        \\  up <DIFF> <URL> [-c <PATH>] [--force] [--wait-for-lock] [--lock-timeout-secs N]
        \\                                   Apply migrations
        \\  down <DIFF> <URL> [--force] [--wait-for-lock] [--lock-timeout-secs N]
        \\                                   Execute schema-diff rollback
        \\  apply <URL> [--direction up|down] [--phase all|expand|backfill|contract]
        \\                                   [--codebase PATH] [--adopt-existing]
        \\  rollback <DIFF> <URL> [--wait-for-lock] [--lock-timeout-secs N]
        \\                                   Execute schema-diff rollback
        \\  rollback --to <VER|base> <URL> [--wait-for-lock] [--lock-timeout-secs N]
        \\                                   Roll back applied folder migrations
        \\  reset <SCHEMA> <URL> [--wait-for-lock] [--lock-timeout-secs N]
        \\                                   Reset DB to target schema (drop + recreate)
        \\  create <NAME> [--depends X] [--author Y]
        \\                                  Create migrations/<timestamp>_<name>.{{up,down}}.qail
        \\  shadow <DIFF|SCHEMA> <URL> [--live] Prepare shadow database and save receipt
        \\  promote <URL>                    Apply shadow diff to primary and drop shadow DB
        \\  abort <URL>                      Drop shadow DB and mark receipt aborted
        \\
        \\Examples:
        \\  qail migrate plan v1.qail:v2.qail
        \\  qail migrate up v1.qail:v2.qail postgres://localhost/mydb
        \\  qail migrate analyze v1.qail:v2.qail -c ./src
        \\
    , .{});
}

fn showVersion() void {
    print("qail-zig 0.8.1\n", .{});
}

test "normalizePostgresType maps serial defaults" {
    const normalized = schema_ops.normalizePostgresType("int4", "integer", "nextval('users_id_seq'::regclass)");
    try std.testing.expectEqualStrings("serial", normalized.typ);
    try std.testing.expect(!normalized.is_array);
    try std.testing.expect(normalized.suppress_default);
}

test "normalizePostgresType maps arrays and preserves base type" {
    const normalized = schema_ops.normalizePostgresType("_text", "ARRAY", null);
    try std.testing.expectEqualStrings("text", normalized.typ);
    try std.testing.expect(normalized.is_array);
    try std.testing.expect(!normalized.suppress_default);
}

test "normalizePostgresType maps primitive aliases" {
    const normalized = schema_ops.normalizePostgresType("float8", "double precision", null);
    try std.testing.expectEqualStrings("f64", normalized.typ);
    try std.testing.expect(!normalized.is_array);
    try std.testing.expect(!normalized.suppress_default);
}

test "rewriteDatabaseInUrl replaces path database" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteDatabaseInUrl(allocator, "postgres://alice@localhost:5432/main", "postgres");
    defer allocator.free(rewritten);
    try std.testing.expectEqualStrings("postgres://alice@localhost:5432/postgres", rewritten);
}

test "rewriteDatabaseInUrl preserves query string" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteDatabaseInUrl(
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
    const slug = try slugifyMigrationName(allocator, "Add Users.Table-1");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("add_users_table_1", slug);
}

test "slugifyMigrationName falls back when empty" {
    const allocator = std.testing.allocator;
    const slug = try slugifyMigrationName(allocator, " - . ");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("migration", slug);
}
