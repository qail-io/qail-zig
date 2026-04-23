const std = @import("std");

const print = std.debug.print;

pub fn showHelp() void {
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

pub fn showMigrateHelp() void {
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

pub fn showVersion() void {
    print("qail-zig 0.8.1\n", .{});
}
