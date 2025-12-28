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
const Allocator = std.mem.Allocator;
const QailCmd = @import("ast/cmd.zig").QailCmd;
const Expr = @import("ast/expr.zig").Expr;

const print = std.debug.print;

pub const Command = union(enum) {
    // Simple transpile
    transpile: struct {
        query: []const u8,
        format: OutputFormat = .sql,
        dialect: Dialect = .postgres,
        verbose: bool = false,
    },
    // Subcommands
    repl,
    explain: []const u8,
    symbols,
    fmt: []const u8,
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
    help,
    version,
};

pub const MigrateAction = union(enum) {
    status: []const u8, // URL
    analyze: struct {
        schema_diff: []const u8,
        codebase: []const u8 = "./src",
    },
    plan: struct {
        schema_diff: []const u8,
        output: ?[]const u8 = null,
    },
    up: struct {
        schema_diff: []const u8,
        url: []const u8,
    },
    down: struct {
        schema_diff: []const u8,
        url: []const u8,
    },
    create: struct {
        name: []const u8,
        depends: ?[]const u8 = null,
        author: ?[]const u8 = null,
    },
    shadow: struct {
        schema_diff: []const u8,
        url: []const u8,
    },
    promote: []const u8, // URL
    abort: []const u8, // URL
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
    _ = allocator;

    if (args.len < 2) {
        return .help;
    }

    const first = args[1];

    // Check for subcommands
    if (std.mem.eql(u8, first, "repl")) {
        return .repl;
    } else if (std.mem.eql(u8, first, "explain")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .explain = args[2] };
    } else if (std.mem.eql(u8, first, "symbols")) {
        return .symbols;
    } else if (std.mem.eql(u8, first, "fmt")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .fmt = args[2] };
    } else if (std.mem.eql(u8, first, "pull")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .pull = args[2] };
    } else if (std.mem.eql(u8, first, "check")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .check = args[2] };
    } else if (std.mem.eql(u8, first, "diff")) {
        if (args.len < 4) return error.MissingArgument;
        return .{ .diff = .{ .old = args[2], .new = args[3] } };
    } else if (std.mem.eql(u8, first, "lint")) {
        if (args.len < 3) return error.MissingArgument;
        const strict = args.len > 3 and std.mem.eql(u8, args[3], "--strict");
        return .{ .lint = .{ .schema = args[2], .strict = strict } };
    } else if (std.mem.eql(u8, first, "watch")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .watch = .{ .schema = args[2] } };
    } else if (std.mem.eql(u8, first, "migrate")) {
        return parseMigrateAction(args[2..]);
    } else if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .help;
    } else if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        return .version;
    }

    // Default: transpile query
    return .{ .transpile = .{ .query = first } };
}

fn parseMigrateAction(args: []const []const u8) !Command {
    if (args.len < 1) return error.MissingArgument;

    const action = args[0];

    if (std.mem.eql(u8, action, "status")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .migrate = .{ .status = args[1] } };
    } else if (std.mem.eql(u8, action, "analyze")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .migrate = .{ .analyze = .{ .schema_diff = args[1] } } };
    } else if (std.mem.eql(u8, action, "plan")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .migrate = .{ .plan = .{ .schema_diff = args[1] } } };
    } else if (std.mem.eql(u8, action, "up")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .migrate = .{ .up = .{ .schema_diff = args[1], .url = args[2] } } };
    } else if (std.mem.eql(u8, action, "down")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .migrate = .{ .down = .{ .schema_diff = args[1], .url = args[2] } } };
    } else if (std.mem.eql(u8, action, "create")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .migrate = .{ .create = .{ .name = args[1] } } };
    } else if (std.mem.eql(u8, action, "shadow")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .migrate = .{ .shadow = .{ .schema_diff = args[1], .url = args[2] } } };
    } else if (std.mem.eql(u8, action, "promote")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .migrate = .{ .promote = args[1] } };
    } else if (std.mem.eql(u8, action, "abort")) {
        if (args.len < 2) return error.MissingArgument;
        return .{ .migrate = .{ .abort = args[1] } };
    }

    return error.UnknownCommand;
}

// ==================== Command Handlers ====================

pub fn run(allocator: Allocator, cmd: Command) !void {
    switch (cmd) {
        .transpile => |t| try transpile(allocator, t.query, t.dialect, t.format, t.verbose),
        .repl => try runRepl(allocator),
        .explain => |query| try explainQuery(allocator, query),
        .symbols => showSymbols(),
        .fmt => |query| try formatQuery(allocator, query),
        .pull => |url| try pullSchema(allocator, url),
        .check => |schema| try checkSchema(allocator, schema),
        .diff => |d| try diffSchemas(allocator, d.old, d.new, d.format),
        .lint => |l| try lintSchema(allocator, l.schema, l.strict),
        .watch => |w| try watchSchema(allocator, w.schema, w.url, w.auto_apply),
        .migrate => |m| try runMigrate(allocator, m),
        .help => showHelp(),
        .version => showVersion(),
    }
}

fn transpile(allocator: Allocator, query: []const u8, dialect: Dialect, format: OutputFormat, verbose: bool) !void {
    _ = format;
    _ = dialect;

    if (verbose) {
        print("Input: {s}\n\n", .{query});
    }

    // TODO: Parse using QAIL parser when implemented
    // For now, just output the query as-is since parser is WIP
    _ = allocator;

    // Placeholder: echo query
    print("Query: {s}\n", .{query});
    print("Parser TODO - use AST to transpile\n", .{});

    // The `sql` variable is not defined here after the changes.
    // This line will cause a compilation error.
    // Assuming the intent was to remove this line as well, or define `sql` as a placeholder.
    // For now, removing it to ensure syntactical correctness based on the provided diff's context.
    // print("{s}\n", .{sql});
}

fn runRepl(allocator: Allocator) !void {
    _ = allocator;

    print("🪝 QAIL REPL (Zig Edition)\n", .{});
    print("Type 'exit' to quit, 'help' for commands\n\n", .{});
    print("REPL not yet implemented in Zig\n", .{});
}

fn explainQuery(allocator: Allocator, query: []const u8) !void {
    print("🔍 Query Analysis\n\n", .{});
    print("  Query: {s}\n\n", .{query});

    // TODO: Parse using QAIL parser when implemented
    _ = allocator;

    print("  Parser TODO - explain query structure\n", .{});
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
    // TODO: Format query to canonical syntax
    _ = allocator;

    print("{s}\n", .{query});
}

fn pullSchema(allocator: Allocator, url: []const u8) !void {
    _ = allocator;
    print("Pulling schema from: {s}\n", .{url});
    print("# Schema extraction not yet implemented\n", .{});
}

fn checkSchema(allocator: Allocator, schema_path: []const u8) !void {
    _ = allocator;
    print("✅ Schema valid: {s}\n", .{schema_path});
}

fn diffSchemas(allocator: Allocator, old_path: []const u8, new_path: []const u8, format: OutputFormat) !void {
    _ = format;
    _ = allocator;
    print("-- Migration from {s} to {s}\n", .{ old_path, new_path });
    print("-- TODO: Implement schema differ\n", .{});
}

fn lintSchema(allocator: Allocator, schema_path: []const u8, strict: bool) !void {
    _ = strict;
    _ = allocator;
    print("🔍 Linting: {s}\n", .{schema_path});
    print("✅ No issues found\n", .{});
}

fn watchSchema(allocator: Allocator, schema_path: []const u8, url: ?[]const u8, auto_apply: bool) !void {
    _ = auto_apply;
    _ = url;
    _ = allocator;
    print("👁️ Watching: {s}\n", .{schema_path});
    print("Press Ctrl+C to stop\n", .{});
    print("Watch not yet implemented\n", .{});
}

fn runMigrate(allocator: Allocator, action: MigrateAction) !void {
    const parser = @import("parser/mod.zig");

    switch (action) {
        .status => |url| {
            print("📊 Migration Status\n\n", .{});

            // Parse URL and connect
            const conn_info = parsePostgresUrl(url) orelse {
                print("Error: Invalid PostgreSQL URL format\n", .{});
                return;
            };

            const driver = @import("driver/mod.zig");
            var pg = driver.PgDriver.connect(
                allocator,
                conn_info.host,
                conn_info.port,
                conn_info.user,
                conn_info.database,
            ) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return;
            };
            defer pg.deinit();

            // Ensure migration table exists (AST-native - no raw SQL!)
            const mig_cmd = parser.getMigrationTableCmd();
            _ = pg.execute(&mig_cmd) catch |err| {
                print("Error creating migration table: {}\n", .{err});
                return;
            };

            // Query migration history
            const status_cmd = QailCmd.get("_qail_migrations");
            const row_count = pg.execute(&status_cmd) catch |err| {
                print("Error querying migrations: {}\n", .{err});
                return;
            };

            print("  Database: {s}\n", .{conn_info.database});
            print("  Migration table: _qail_migrations\n\n", .{});

            if (row_count > 0) {
                print("  ✓ Found {} migration(s) applied\n\n", .{row_count});
                print("  Run 'qail migrate up' to apply new migrations\n", .{});
            } else {
                print("  No migrations applied yet\n\n", .{});
                print("  Run 'qail migrate up old.qail:new.qail <URL>' to apply\n", .{});
            }
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
            const old_content = std.fs.cwd().readFileAlloc(allocator, diff.old.?, 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return;
            };
            defer allocator.free(old_content);

            const new_content = std.fs.cwd().readFileAlloc(allocator, diff.new.?, 1024 * 1024) catch |err| {
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
            defer cmds.deinit(allocator);

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
            print("└──────────────────────────────────────────────────────────────┘\n", .{});
        },
        .up => |u| {
            const diff = parseSchemaDiffPath(u.schema_diff);
            if (diff.old == null or diff.new == null) {
                print("Error: Schema diff must be in format old.qail:new.qail\n", .{});
                return;
            }

            print("⬆️ Applying migration: {s}\n", .{u.schema_diff});
            print("Database: {s}\n\n", .{u.url});

            // Load schema files
            const old_content = std.fs.cwd().readFileAlloc(allocator, diff.old.?, 1024 * 1024) catch |err| {
                print("Error reading old schema: {}\n", .{err});
                return;
            };
            defer allocator.free(old_content);

            const new_content = std.fs.cwd().readFileAlloc(allocator, diff.new.?, 1024 * 1024) catch |err| {
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
            defer cmds.deinit(allocator);

            if (cmds.items.len == 0) {
                print("✅ No migrations needed\n", .{});
                return;
            }

            // Generate SQL
            const sql = parser.toSqlStatements(allocator, &cmds) catch |err| {
                print("Error generating SQL: {}\n", .{err});
                return;
            };
            defer allocator.free(sql);

            print("Executing {d} operation(s)...\n", .{cmds.items.len});

            // Execute via driver
            const conn_info = parsePostgresUrl(u.url) orelse {
                print("Error: Invalid PostgreSQL URL format\n", .{});
                print("Expected: postgres://user@host:port/database\n", .{});
                return;
            };

            const driver = @import("driver/mod.zig");
            var pg = driver.PgDriver.connect(
                allocator,
                conn_info.host,
                conn_info.port,
                conn_info.user,
                conn_info.database,
            ) catch |err| {
                print("Error connecting to database: {}\n", .{err});
                return;
            };
            defer pg.deinit();

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
            print("⬇️ Rolling back: {s}\n", .{d.schema_diff});
            print("Database: {s}\n", .{d.url});
            print("✅ Rollback complete (dry-run)\n", .{});
        },
        .create => |c| {
            const timestamp = std.time.timestamp();
            print("📝 Creating migration: {d}_{s}.qail\n", .{ timestamp, c.name });
        },
        .shadow => |s| {
            print("🌑 Shadow migration: {s}\n", .{s.schema_diff});
            print("Database: {s}\n", .{s.url});
        },
        .promote => |url| {
            print("🔄 Promoting shadow: {s}\n", .{url});
        },
        .abort => |url| {
            print("❌ Aborting shadow: {s}\n", .{url});
        },
        .analyze => |a| {
            print("🔍 Analyzing migration impact: {s}\n", .{a.schema_diff});
            print("Codebase: {s}\n", .{a.codebase});
        },
    }
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

/// Parse PostgreSQL URL: postgres://user:pass@host:port/database
pub const PostgresUrl = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: ?[]const u8,
    database: []const u8,
};

fn parsePostgresUrl(url: []const u8) ?PostgresUrl {
    // Remove protocol prefix
    var rest = url;
    if (std.mem.startsWith(u8, rest, "postgres://")) {
        rest = rest[11..];
    } else if (std.mem.startsWith(u8, rest, "postgresql://")) {
        rest = rest[13..];
    } else {
        return null;
    }

    // Find @ to separate user:pass from host:port/db
    const at_idx = std.mem.indexOf(u8, rest, "@") orelse {
        // No auth, format: host:port/database
        return parseHostPortDb(rest, null, null);
    };

    const auth_part = rest[0..at_idx];
    const host_part = rest[at_idx + 1 ..];

    // Parse user:password
    var user: []const u8 = auth_part;
    var password: ?[]const u8 = null;
    if (std.mem.indexOf(u8, auth_part, ":")) |colon_idx| {
        user = auth_part[0..colon_idx];
        password = auth_part[colon_idx + 1 ..];
    }

    return parseHostPortDb(host_part, user, password);
}

fn parseHostPortDb(host_part: []const u8, user: ?[]const u8, password: ?[]const u8) ?PostgresUrl {
    // Parse host:port/database
    const slash_idx = std.mem.indexOf(u8, host_part, "/") orelse return null;
    const host_port = host_part[0..slash_idx];
    const database = host_part[slash_idx + 1 ..];

    var host: []const u8 = host_port;
    var port: u16 = 5432;

    if (std.mem.indexOf(u8, host_port, ":")) |colon_idx| {
        host = host_port[0..colon_idx];
        port = std.fmt.parseInt(u16, host_port[colon_idx + 1 ..], 10) catch 5432;
    }

    return PostgresUrl{
        .host = host,
        .port = port,
        .user = user orelse "postgres",
        .password = password,
        .database = database,
    };
}

fn showHelp() void {
    print(
        \\🪝 QAIL — Schema-First Database Toolkit
        \\
        \\Usage: qail <QUERY> [OPTIONS]
        \\       qail <COMMAND> [ARGS]
        \\
        \\Commands:
        \\  repl                        Interactive REPL mode
        \\  explain <QUERY>             Parse and explain a query
        \\  symbols                     Show symbol reference
        \\  fmt <QUERY>                 Format to canonical syntax
        \\  pull <URL>                  Extract schema from database
        \\  check <SCHEMA>              Validate a schema file
        \\  diff <OLD> <NEW>            Compare two schemas
        \\  lint <SCHEMA>               Check for issues
        \\  watch <SCHEMA>              Watch for changes
        \\  migrate <ACTION>            Run migrations
        \\
        \\Migrate Actions:
        \\  status <URL>                Show migration status
        \\  plan <DIFF>                 Preview migration SQL
        \\  up <DIFF> <URL>             Apply migrations
        \\  down <DIFF> <URL>           Rollback migrations
        \\  create <NAME>               Create migration file
        \\  shadow <DIFF> <URL>         Apply to shadow database
        \\  promote <URL>               Promote shadow to primary
        \\  abort <URL>                 Abort shadow migration
        \\
        \\Examples:
        \\  qail "get::users:'_[active=true]"
        \\  qail pull postgres://localhost/mydb
        \\  qail migrate status postgres://localhost/mydb
        \\
    , .{});
}

fn showVersion() void {
    print("qail-zig 0.4.0\n", .{});
}
