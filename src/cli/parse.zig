const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn make(comptime Cli: type) type {
    const Command = Cli.Command;
    const OutputFormat = Cli.OutputFormat;
    const Dialect = Cli.Dialect;
    const MigrationDirection = Cli.MigrationDirection;
    const ApplyPhase = Cli.ApplyPhase;
    const BranchAction = Cli.BranchAction;
    const SchemaAction = Cli.SchemaAction;
    const SyncAction = Cli.SyncAction;
    const VectorAction = Cli.VectorAction;

    return struct {
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

        fn isHelpToken(value: []const u8) bool {
            return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
        }

        fn hasHelpToken(values: []const []const u8) bool {
            for (values) |value| {
                if (isHelpToken(value)) return true;
            }
            return false;
        }

        fn isKnownTopLevelCommand(value: []const u8) bool {
            return std.mem.eql(u8, value, "init") or
                std.mem.eql(u8, value, "repl") or
                std.mem.eql(u8, value, "explain") or
                std.mem.eql(u8, value, "symbols") or
                std.mem.eql(u8, value, "fmt") or
                std.mem.eql(u8, value, "exec") or
                std.mem.eql(u8, value, "seed") or
                std.mem.eql(u8, value, "types") or
                std.mem.eql(u8, value, "pull") or
                std.mem.eql(u8, value, "check") or
                std.mem.eql(u8, value, "diff") or
                std.mem.eql(u8, value, "lint") or
                std.mem.eql(u8, value, "mig") or
                std.mem.eql(u8, value, "watch") or
                std.mem.eql(u8, value, "migrate") or
                std.mem.eql(u8, value, "branch") or
                std.mem.eql(u8, value, "schema") or
                std.mem.eql(u8, value, "sync") or
                std.mem.eql(u8, value, "vector") or
                std.mem.eql(u8, value, "worker");
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

            if (std.mem.eql(u8, first, "help")) {
                if (rest.len >= 1 and std.mem.eql(u8, rest[0], "migrate")) return .migrate_help;
                if (rest.len >= 1 and std.mem.eql(u8, rest[0], "branch")) return .branch_help;
                if (rest.len >= 1 and std.mem.eql(u8, rest[0], "schema")) return .schema_help;
                if (rest.len >= 1 and std.mem.eql(u8, rest[0], "sync")) return .sync_help;
                if (rest.len >= 1 and std.mem.eql(u8, rest[0], "vector")) return .vector_help;
                return .help;
            }

            if (std.mem.eql(u8, first, "migrate")) {
                if (hasHelpToken(rest)) return .migrate_help;
                return parseMigrateAction(rest);
            }
            if (std.mem.eql(u8, first, "branch")) {
                if (rest.len == 0) return .branch_help;
                if (rest.len > 0 and std.mem.eql(u8, rest[0], "help")) return .branch_help;
                if (hasHelpToken(rest)) return .branch_help;
                return .{ .branch = try parseBranchAction(rest) };
            }
            if (std.mem.eql(u8, first, "schema")) {
                if (rest.len == 0) return .schema_help;
                if (rest.len > 0 and std.mem.eql(u8, rest[0], "help")) return .schema_help;
                if (hasHelpToken(rest)) return .schema_help;
                return .{ .schema = try parseSchemaAction(rest) };
            }
            if (std.mem.eql(u8, first, "sync")) {
                if (rest.len == 0) return .sync_help;
                if (rest.len > 0 and std.mem.eql(u8, rest[0], "help")) return .sync_help;
                if (hasHelpToken(rest)) return .sync_help;
                return .{ .sync = try parseSyncAction(rest) };
            }
            if (std.mem.eql(u8, first, "vector")) {
                if (rest.len == 0) return .vector_help;
                if (rest.len > 0 and std.mem.eql(u8, rest[0], "help")) return .vector_help;
                if (hasHelpToken(rest)) return .vector_help;
                return .{ .vector = try parseVectorAction(rest) };
            }
            if (std.mem.eql(u8, first, "worker")) {
                if (hasHelpToken(rest)) return .help;
                return .{ .worker = try parseWorkerCommand(rest) };
            }

            if (isKnownTopLevelCommand(first) and hasHelpToken(rest)) {
                return .help;
            }

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

        fn parseBranchAction(args: []const []const u8) !BranchAction {
            if (args.len == 0) return error.MissingArgument;
            const action = args[0];

            if (std.mem.eql(u8, action, "help")) return error.UnknownOption;
            if (std.mem.eql(u8, action, "create")) {
                if (args.len < 2) return error.MissingArgument;
                var parent: ?[]const u8 = null;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--parent")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        parent = args[i];
                        continue;
                    }
                    if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        url = args[i];
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .create = .{
                    .name = args[1],
                    .parent = parent,
                    .url = url,
                } };
            }
            if (std.mem.eql(u8, action, "list")) {
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
                    return error.UnknownOption;
                }
                return .{ .list = .{ .url = url } };
            }
            if (std.mem.eql(u8, action, "delete")) {
                if (args.len < 2) return error.MissingArgument;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        url = args[i];
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .delete = .{
                    .name = args[1],
                    .url = url,
                } };
            }
            if (std.mem.eql(u8, action, "merge")) {
                if (args.len < 2) return error.MissingArgument;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        url = args[i];
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .merge = .{
                    .name = args[1],
                    .url = url,
                } };
            }

            return error.UnknownCommand;
        }

        fn parseSchemaAction(args: []const []const u8) !SchemaAction {
            if (args.len == 0) return .{ .doctor = .{} };
            const action = args[0];

            if (std.mem.eql(u8, action, "doctor")) {
                var schema: []const u8 = "schema.qail";
                var strict = false;
                var i: usize = 1;
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    schema = args[i];
                    i += 1;
                }
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--strict")) {
                        strict = true;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .doctor = .{ .schema = schema, .strict = strict } };
            }
            if (std.mem.eql(u8, action, "split")) {
                var input: []const u8 = "schema.qail";
                var out: []const u8 = "schema";
                var force = false;
                var i: usize = 1;
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    input = args[i];
                    i += 1;
                }
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "-o")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        out = args[i];
                        continue;
                    }
                    if (std.mem.eql(u8, arg, "--force")) {
                        force = true;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .split = .{
                    .input = input,
                    .out = out,
                    .force = force,
                } };
            }
            if (std.mem.eql(u8, action, "merge")) {
                var input: []const u8 = "schema";
                var output: []const u8 = "schema.qail";
                var i: usize = 1;
                if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                    input = args[i];
                    i += 1;
                }
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
                return .{ .merge = .{ .input = input, .output = output } };
            }
            if (std.mem.eql(u8, action, "help")) return error.UnknownOption;

            return error.UnknownCommand;
        }

        fn parseSyncAction(args: []const []const u8) !SyncAction {
            if (args.len == 0) return error.MissingArgument;
            if (std.mem.eql(u8, args[0], "generate")) {
                if (args.len != 1) return error.UnknownOption;
                return .generate;
            }
            if (std.mem.eql(u8, args[0], "list")) {
                if (args.len != 1) return error.UnknownOption;
                return .list;
            }
            if (std.mem.eql(u8, args[0], "help")) return error.UnknownOption;
            return error.UnknownCommand;
        }

        fn parseVectorAction(args: []const []const u8) !VectorAction {
            if (args.len == 0) return error.MissingArgument;
            const action = args[0];

            if (std.mem.eql(u8, action, "create")) {
                if (args.len < 2) return error.MissingArgument;
                var size: ?u64 = null;
                var distance: []const u8 = "cosine";
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        size = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                        continue;
                    }
                    if (std.mem.eql(u8, arg, "--distance") or std.mem.eql(u8, arg, "-d")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        distance = args[i];
                        continue;
                    }
                    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
                    if (url == null) {
                        url = arg;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{
                    .create = .{
                        .collection = args[1],
                        .size = size orelse return error.MissingArgument,
                        .distance = distance,
                        .url = url orelse return error.MissingArgument,
                    },
                };
            }

            if (std.mem.eql(u8, action, "drop")) {
                if (args.len < 2) return error.MissingArgument;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
                    if (url == null) {
                        url = arg;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .drop = .{ .collection = args[1], .url = url orelse return error.MissingArgument } };
            }

            if (std.mem.eql(u8, action, "backup")) {
                if (args.len < 2) return error.MissingArgument;
                var output: ?[]const u8 = null;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        output = args[i];
                        continue;
                    }
                    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
                    if (url == null) {
                        url = arg;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{
                    .backup = .{
                        .collection = args[1],
                        .output = output,
                        .url = url orelse return error.MissingArgument,
                    },
                };
            }

            if (std.mem.eql(u8, action, "restore")) {
                if (args.len < 2) return error.MissingArgument;
                var snapshot: ?[]const u8 = null;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.eql(u8, arg, "--snapshot") or std.mem.eql(u8, arg, "-s")) {
                        i += 1;
                        if (i >= args.len) return error.MissingArgument;
                        snapshot = args[i];
                        continue;
                    }
                    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
                    if (url == null) {
                        url = arg;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{
                    .restore = .{
                        .collection = args[1],
                        .snapshot = snapshot orelse return error.MissingArgument,
                        .url = url orelse return error.MissingArgument,
                    },
                };
            }

            if (std.mem.eql(u8, action, "snapshots")) {
                if (args.len < 2) return error.MissingArgument;
                var url: ?[]const u8 = null;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    const arg = args[i];
                    if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
                    if (url == null) {
                        url = arg;
                        continue;
                    }
                    return error.UnknownOption;
                }
                return .{ .snapshots = .{
                    .collection = args[1],
                    .url = url orelse return error.MissingArgument,
                } };
            }

            if (std.mem.eql(u8, action, "help")) return error.UnknownOption;
            return error.UnknownCommand;
        }

        fn parseWorkerCommand(args: []const []const u8) !Cli.WorkerCmd {
            var interval_ms: u64 = 1000;
            var batch_size: u32 = 100;

            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--interval") or std.mem.eql(u8, arg, "-i")) {
                    i += 1;
                    if (i >= args.len) return error.MissingArgument;
                    interval_ms = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--batch") or std.mem.eql(u8, arg, "-b")) {
                    i += 1;
                    if (i >= args.len) return error.MissingArgument;
                    batch_size = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArgument;
                    continue;
                }
                return error.UnknownOption;
            }

            return .{
                .interval_ms = interval_ms,
                .batch_size = batch_size,
            };
        }

        fn parseApplyPhaseValue(value: []const u8) ?ApplyPhase {
            if (std.mem.eql(u8, value, "all")) return .all;
            if (std.mem.eql(u8, value, "expand")) return .expand;
            if (std.mem.eql(u8, value, "backfill")) return .backfill;
            if (std.mem.eql(u8, value, "contract")) return .contract;
            return null;
        }
    };
}
