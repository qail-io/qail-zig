const std = @import("std");
pub fn make(comptime Cli: type) type {
    const parse = Cli.parse;
    const OutputFormat = Cli.OutputFormat;
    const Dialect = Cli.Dialect;
    const MigrationDirection = Cli.MigrationDirection;
    const ApplyPhase = Cli.ApplyPhase;

    return struct {
        test "parse transpile with global options" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "--format",
                "json",
                "--dialect",
                "sqlite",
                "--verbose",
                "get users",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .transpile => |t| {
                    try std.testing.expectEqualStrings("get users", t.query);
                    try std.testing.expectEqual(OutputFormat.json, t.format);
                    try std.testing.expectEqual(Dialect.sqlite, t.dialect);
                    try std.testing.expect(t.verbose);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse init default target" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "init",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .init => |target| try std.testing.expectEqualStrings(".", target),
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse init with target directory" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "init",
                "./sandbox",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .init => |target| try std.testing.expectEqualStrings("./sandbox", target),
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse pull with --url flag" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "pull",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .pull => |url| try std.testing.expectEqualStrings("postgres://localhost/mydb", url),
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate help" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "--help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .migrate_help);
        }

        test "parse top-level help command" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .help);
        }

        test "parse init help flag returns help action" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "init",
                "--help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .help);
        }

        test "parse mig help flag returns help action" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "mig",
                "--help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .help);
        }

        test "parse exec help flag returns help action" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "exec",
                "--help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .help);
        }

        test "parse migrate subcommand help flag returns migrate help action" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "up",
                "--help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .migrate_help);
        }

        test "parse branch help command" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "branch",
                "help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .branch_help);
        }

        test "parse schema help command" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "schema",
                "help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .schema_help);
        }

        test "parse sync help command" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "sync",
                "help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .sync_help);
        }

        test "parse vector help command" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "vector",
                "help",
            };

            const cmd = try parse(allocator, &args);
            try std.testing.expect(cmd == .vector_help);
        }

        test "parse branch create with parent and url" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "branch",
                "create",
                "feature_auth",
                "--parent",
                "main",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .branch => |b| switch (b) {
                    .create => |c| {
                        try std.testing.expectEqualStrings("feature_auth", c.name);
                        try std.testing.expect(c.parent != null);
                        try std.testing.expectEqualStrings("main", c.parent.?);
                        try std.testing.expect(c.url != null);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", c.url.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse schema split defaults and flags" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "schema",
                "split",
                "--out",
                "schema_modules",
                "--force",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .schema => |s| switch (s) {
                    .split => |split| {
                        try std.testing.expectEqualStrings("schema.qail", split.input);
                        try std.testing.expectEqualStrings("schema_modules", split.out);
                        try std.testing.expect(split.force);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse sync generate action" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "sync",
                "generate",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .sync => |action| try std.testing.expect(action == .generate),
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse vector create with size distance and url" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "vector",
                "create",
                "products",
                "--size",
                "1536",
                "--distance",
                "cosine",
                "http://localhost:6333",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .vector => |action| switch (action) {
                    .create => |create| {
                        try std.testing.expectEqualStrings("products", create.collection);
                        try std.testing.expectEqual(@as(u64, 1536), create.size);
                        try std.testing.expectEqualStrings("cosine", create.distance);
                        try std.testing.expectEqualStrings("http://localhost:6333", create.url);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse vector backup with output" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "vector",
                "backup",
                "products",
                "--output",
                "products.snapshot",
                "http://localhost:6333",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .vector => |action| switch (action) {
                    .backup => |backup| {
                        try std.testing.expectEqualStrings("products", backup.collection);
                        try std.testing.expect(backup.output != null);
                        try std.testing.expectEqualStrings("products.snapshot", backup.output.?);
                        try std.testing.expectEqualStrings("http://localhost:6333", backup.url);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse worker defaults" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "worker",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .worker => |worker| {
                    try std.testing.expectEqual(@as(u64, 1000), worker.interval_ms);
                    try std.testing.expectEqual(@as(u32, 100), worker.batch_size);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse worker explicit interval and batch" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "worker",
                "--interval",
                "200",
                "--batch",
                "50",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .worker => |worker| {
                    try std.testing.expectEqual(@as(u64, 200), worker.interval_ms);
                    try std.testing.expectEqual(@as(u32, 50), worker.batch_size);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate status without url uses empty sentinel" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "status",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .status => |url| try std.testing.expectEqualStrings("", url),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate plan with output" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "plan",
                "v1.qail:v2.qail",
                "--output",
                "migration.sql",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .plan => |p| {
                        try std.testing.expectEqualStrings("v1.qail:v2.qail", p.schema_diff);
                        try std.testing.expect(p.output != null);
                        try std.testing.expectEqualStrings("migration.sql", p.output.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate analyze with ci and json flags" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "analyze",
                "v1.qail:v2.qail",
                "--codebase",
                "./app",
                "--ci",
                "--json",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .analyze => |a| {
                        try std.testing.expectEqualStrings("v1.qail:v2.qail", a.schema_diff);
                        try std.testing.expectEqualStrings("./app", a.codebase);
                        try std.testing.expect(a.ci);
                        try std.testing.expect(a.json);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate up with codebase and force" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "up",
                "v1.qail:v2.qail",
                "--url",
                "postgres://localhost/mydb",
                "--codebase",
                "./src",
                "--force",
                "--allow-destructive",
                "--allow-no-shadow-receipt",
                "--allow-lock-risk",
                "--lock-timeout-secs",
                "30",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .up => |u| {
                        try std.testing.expectEqualStrings("v1.qail:v2.qail", u.schema_diff);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", u.url);
                        try std.testing.expect(u.codebase != null);
                        try std.testing.expectEqualStrings("./src", u.codebase.?);
                        try std.testing.expect(u.force);
                        try std.testing.expect(u.allow_destructive);
                        try std.testing.expect(u.allow_no_shadow_receipt);
                        try std.testing.expect(u.allow_lock_risk);
                        try std.testing.expect(u.wait_for_lock);
                        try std.testing.expect(u.lock_timeout_secs != null);
                        try std.testing.expectEqual(@as(u64, 30), u.lock_timeout_secs.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate promote with --url flag" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "promote",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .promote => |url| try std.testing.expectEqualStrings("postgres://localhost/mydb", url),
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate shadow with --live flag" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "shadow",
                "schema.qail",
                "--live",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .shadow => |s| {
                        try std.testing.expectEqualStrings("schema.qail", s.schema_diff);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", s.url);
                        try std.testing.expect(s.live);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate apply with positional url" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "apply",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .apply => |a| {
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", a.url);
                        try std.testing.expectEqual(MigrationDirection.up, a.direction);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate apply without url uses empty sentinel" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "apply",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .apply => |a| {
                        try std.testing.expectEqualStrings("", a.url);
                        try std.testing.expectEqual(MigrationDirection.up, a.direction);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate apply with direction down" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "apply",
                "--direction",
                "down",
                "--phase",
                "contract",
                "--codebase",
                "./src",
                "--allow-contract-with-references",
                "--allow-destructive",
                "--allow-no-shadow-receipt",
                "--allow-lock-risk",
                "--adopt-existing",
                "--backfill-chunk-size",
                "9000",
                "--lock-timeout-secs",
                "45",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .apply => |a| {
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", a.url);
                        try std.testing.expectEqual(MigrationDirection.down, a.direction);
                        try std.testing.expectEqual(ApplyPhase.contract, a.phase);
                        try std.testing.expect(a.codebase != null);
                        try std.testing.expectEqualStrings("./src", a.codebase.?);
                        try std.testing.expect(a.allow_contract_with_references);
                        try std.testing.expect(a.allow_destructive);
                        try std.testing.expect(a.allow_no_shadow_receipt);
                        try std.testing.expect(a.allow_lock_risk);
                        try std.testing.expect(a.adopt_existing);
                        try std.testing.expectEqual(@as(usize, 9000), a.backfill_chunk_size);
                        try std.testing.expect(a.wait_for_lock);
                        try std.testing.expect(a.lock_timeout_secs != null);
                        try std.testing.expectEqual(@as(u64, 45), a.lock_timeout_secs.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate down with force and lock options" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "down",
                "v2.qail:v1.qail",
                "--force",
                "--wait-for-lock",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .down => |d| {
                        try std.testing.expectEqualStrings("v2.qail:v1.qail", d.schema_diff);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", d.url);
                        try std.testing.expect(d.force);
                        try std.testing.expect(d.wait_for_lock);
                        try std.testing.expect(d.lock_timeout_secs == null);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate rollback with positional url" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "rollback",
                "v1.qail:v2.qail",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .rollback => |r| {
                        try std.testing.expect(r.schema_diff != null);
                        try std.testing.expect(r.to == null);
                        try std.testing.expectEqualStrings("v1.qail:v2.qail", r.schema_diff.?);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", r.url);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate rollback with --to target" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "rollback",
                "--to",
                "base",
                "--lock-timeout-secs",
                "20",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .rollback => |r| {
                        try std.testing.expect(r.schema_diff == null);
                        try std.testing.expect(r.to != null);
                        try std.testing.expectEqualStrings("base", r.to.?);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", r.url);
                        try std.testing.expect(r.wait_for_lock);
                        try std.testing.expect(r.lock_timeout_secs != null);
                        try std.testing.expectEqual(@as(u64, 20), r.lock_timeout_secs.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse migrate reset with --url flag" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "migrate",
                "reset",
                "schema.qail",
                "--lock-timeout-secs",
                "15",
                "--url",
                "postgres://localhost/mydb",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .reset => |r| {
                        try std.testing.expectEqualStrings("schema.qail", r.schema);
                        try std.testing.expectEqualStrings("postgres://localhost/mydb", r.url);
                        try std.testing.expect(r.wait_for_lock);
                        try std.testing.expect(r.lock_timeout_secs != null);
                        try std.testing.expectEqual(@as(u64, 15), r.lock_timeout_secs.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse watch with auto-apply options" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "watch",
                "schema.qail",
                "--url",
                "postgres://localhost/mydb",
                "--auto-apply",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .watch => |w| {
                    try std.testing.expectEqualStrings("schema.qail", w.schema);
                    try std.testing.expect(w.auto_apply);
                    try std.testing.expect(w.url != null);
                    try std.testing.expectEqualStrings("postgres://localhost/mydb", w.url.?);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse watch missing schema returns error" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "watch",
            };
            try std.testing.expectError(error.MissingArgument, parse(allocator, &args));
        }

        test "parse mig alias maps to migrate create" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "mig",
                "add_user_profiles",
                "--depends",
                "add_users",
                "--author",
                "orion",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .migrate => |m| switch (m) {
                    .create => |c| {
                        try std.testing.expectEqualStrings("add_user_profiles", c.name);
                        try std.testing.expect(c.depends != null);
                        try std.testing.expect(c.author != null);
                        try std.testing.expectEqualStrings("add_users", c.depends.?);
                        try std.testing.expectEqualStrings("orion", c.author.?);
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse mig alias missing name returns error" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "mig",
            };
            try std.testing.expectError(error.MissingArgument, parse(allocator, &args));
        }

        test "parse exec query with url and flags" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "exec",
                "get users fields id",
                "--url",
                "postgres://localhost/mydb",
                "--tx",
                "--json",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .exec => |e| {
                    try std.testing.expect(e.query != null);
                    try std.testing.expectEqualStrings("get users fields id", e.query.?);
                    try std.testing.expect(e.url != null);
                    try std.testing.expectEqualStrings("postgres://localhost/mydb", e.url.?);
                    try std.testing.expect(e.tx);
                    try std.testing.expect(e.json);
                    try std.testing.expect(!e.dry_run);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse exec file dry run" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "exec",
                "--file",
                "seed.qail",
                "--dry-run",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .exec => |e| {
                    try std.testing.expect(e.file != null);
                    try std.testing.expectEqualStrings("seed.qail", e.file.?);
                    try std.testing.expect(e.dry_run);
                    try std.testing.expect(e.query == null);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse seed defaults" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "seed",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .seed => |s| {
                    try std.testing.expectEqualStrings("seed.qail", s.file);
                    try std.testing.expect(s.url == null);
                    try std.testing.expect(!s.tx);
                    try std.testing.expect(!s.dry_run);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse types default schema" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "types",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .types => |schema_path| try std.testing.expectEqualStrings("schema.qail", schema_path),
                else => return error.TestUnexpectedResult,
            }
        }

        test "parse types with explicit schema path" {
            const allocator = std.testing.allocator;
            const args = [_][]const u8{
                "qail",
                "types",
                "db/schema.qail",
            };

            const cmd = try parse(allocator, &args);
            switch (cmd) {
                .types => |schema_path| try std.testing.expectEqualStrings("db/schema.qail", schema_path),
                else => return error.TestUnexpectedResult,
            }
        }
    };
}
