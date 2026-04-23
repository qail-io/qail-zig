const std = @import("std");
const Allocator = std.mem.Allocator;
const QailCmd = @import("../ast/cmd.zig").QailCmd;
const io_compat = @import("../runtime/io.zig");

pub fn make(comptime Cli: type) type {
    return struct {
        const print = std.debug.print;

        const ExecStatements = struct {
            items: std.ArrayList([]const u8),
            file_content: ?[]u8 = null,

            pub fn deinit(self: *ExecStatements, allocator: Allocator) void {
                self.items.deinit(allocator);
                if (self.file_content) |content| allocator.free(content);
                self.file_content = null;
            }
        };

        fn freeParsedCmd(allocator: Allocator, cmd: *const QailCmd) void {
            if (cmd.columns.len > 0) allocator.free(cmd.columns);
            if (cmd.where_clauses.len > 0) allocator.free(cmd.where_clauses);
            if (cmd.joins.len > 0) allocator.free(cmd.joins);
            if (cmd.order_by.len > 0) allocator.free(cmd.order_by);
        }

        fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
            return std.Io.Dir.cwd().readFileAlloc(
                io_compat.runtimeIo(),
                path,
                allocator,
                std.Io.Limit.limited(max_bytes),
            );
        }

        fn normalizeExecStatement(raw: []const u8) []const u8 {
            var stmt = std.mem.trim(u8, raw, " \t\r");
            while (stmt.len > 0 and stmt[stmt.len - 1] == ';') {
                stmt = std.mem.trim(u8, stmt[0 .. stmt.len - 1], " \t\r");
            }
            return stmt;
        }

        pub fn collectExecStatements(
            allocator: Allocator,
            query: ?[]const u8,
            file: ?[]const u8,
        ) !ExecStatements {
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

        pub fn cmdReturnsRows(kind: @import("../ast/cmd/types.zig").CmdKind) bool {
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

        fn printRowsAsJson(allocator: Allocator, rows: []const @import("../driver/row.zig").PgRow) !void {
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

        fn printRowsAsTable(rows: []const @import("../driver/row.zig").PgRow) void {
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

        pub fn transpile(
            allocator: Allocator,
            query: []const u8,
            dialect: Cli.Dialect,
            format: Cli.OutputFormat,
            verbose: bool,
        ) !void {
            _ = dialect;
            const parser = @import("../parser/mod.zig");
            const transpiler = @import("../transpiler/mod.zig");

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

        pub fn runRepl(allocator: Allocator) !void {
            const parser = @import("../parser/mod.zig");
            const transpiler = @import("../transpiler/mod.zig");
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

        pub fn runExec(allocator: Allocator, exec: Cli.ExecCmd) !void {
            const parser = @import("../parser/mod.zig");
            const transpiler = @import("../transpiler/mod.zig");

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
            const url = try Cli.resolveDatabaseUrl(provided_url);

            var pg = Cli.connectPgUrl(allocator, url) catch |err| {
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
                    defer Cli.deinitFetchedRows(allocator, rows);
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

        pub fn runSeed(allocator: Allocator, seed: Cli.SeedCmd) !void {
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

        pub fn generateTypes(allocator: Allocator, schema_path: []const u8) !void {
            const parser = @import("../parser/mod.zig");

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

        pub fn explainQuery(allocator: Allocator, query: []const u8) !void {
            const parser = @import("../parser/mod.zig");
            const transpiler = @import("../transpiler/mod.zig");

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

        pub fn showSymbols() void {
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

        pub fn formatQuery(allocator: Allocator, query: []const u8) !void {
            const parser = @import("../parser/mod.zig");
            const fmt_mod = @import("../fmt.zig");

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
    };
}
