# QAIL Zig

**Zig-first PostgreSQL driver with AST-native query building, codegen, CLI, and optional Linux Kerberos/GSSENC integration.**

[![Zig](https://img.shields.io/badge/Zig-0.16+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.9.0-green.svg?style=flat-square)](https://github.com/qail-io/qail-zig/releases/tag/v0.9.0)

> **Status: Active** — The PostgreSQL driver, pooling, TLS, COPY, CLI, hardening suites, and benchmark harness are live, tracking wire-protocol parity against qail.rs.
>
> **Scope:** 56,749 tracked text lines overall, including 53,426 lines of Zig across 172 tracked `.zig` files covering the wire protocol, connection pool, TLS, pipeline, COPY, AST encoder, parser, CLI, builders, benchmarks, and optional Linux GSSAPI/libc integration for Kerberos/GSSENC.
>
> **[qail.rs](https://github.com/qail-io/qail)** remains the generalized production platform; qail-zig is the dedicated Zig driver implementation, with enterprise-auth on Linux using the platform GSSAPI stack rather than a self-contained Zig Kerberos implementation.

> Core driver/runtime path is Zig-native and zero-GC. The Linux Kerberos/GSSENC path uses optional runtime GSSAPI loading and libc-backed dynamic linking.

- Website: [dev.qail.io/zig](https://dev.qail.io/zig)
- Docs: [dev.qail.io/zig/docs](https://dev.qail.io/zig/docs)
- Benchmarks: [dev.qail.io/zig/benchmarks](https://dev.qail.io/zig/benchmarks)
- Changelog: [`CHANGELOG.md`](./CHANGELOG.md)

## Highlights

- **56,749 total LOC** — 53,426 Zig lines across 172 tracked `.zig` files, with optional Linux libc/GSSAPI integration only for Kerberos/GSSENC
- **AST-Native Queries** — Type-safe query building, not string concatenation
- **Codegen Parity** — 26 enums + 9 structs auto-generated from [qail.rs](https://github.com/qail-io/qail) AST
- **Full PostgreSQL Driver** — Connection pooling, pipelining, TLS, COPY
- **10 Builder Modules** — Conditions, aggregates, binary, cast, JSON, literals, time, case/when, shortcuts, typed
- **Fuzz Testing** — Decoder, value, and transpiler fuzzing
- **Editor Tooling** — Use the published qail.rs OpenVSX LSP extension
- **CLI** — Migrations, REPL, formatting, schema diff

## Benchmarks

Published benchmark results live on the website instead of this README:

- Driver benchmarks: [dev.qail.io/zig/benchmarks](https://dev.qail.io/zig/benchmarks)
- Project overview: [dev.qail.io/zig](https://dev.qail.io/zig)

The web pages are the canonical place for the current benchmark matrix, methodology, and interpretation. The README stays intentionally short so users do not have to parse large benchmark tables here.

```bash
# Run benchmarks locally
zig build ast-bench
zig build pgzig-bench -- qail single --workload point
zig build pgzig-bench -- pgzig pool10 --workload many_params

# Optional convenience wrapper (equivalent commands)
./scripts/zigw pgzig-bench qail single --workload point
./scripts/zigw pgzig-bench pgzig pool10 --workload many_params
```

## Installation

```bash
# Requires Zig 0.16+ and PostgreSQL 14+
git clone https://github.com/qail-io/qail-zig.git
cd qail-zig
zig build -Doptimize=ReleaseFast

# Optional wrapper for the common build/test commands:
./scripts/zigw doctor
./scripts/zigw test
```

## Quick Start

```zig
const std = @import("std");
const qail = @import("qail");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Connect
    var driver = try qail.driver.driver.PgDriver.connect(allocator, "127.0.0.1", 5432, "postgres", "mydb");
    defer driver.deinit();

    // AST-native query
    const cmd = qail.ast.QailCmd.get("users").limit(10);
    const rows = try driver.fetchAll(&cmd);
    defer allocator.free(rows);

    for (rows) |row| {
        std.debug.print("id={}, name={s}\n", .{
            row.get(i32, 0),
            row.getString(1) orelse "null",
        });
    }
}
```

## Codegen

AST types are auto-generated from the Rust source to maintain parity:

```bash
# From qail-zig/
./scripts/regenerate_codegen.sh ../qail.rs

# CI-style drift check (ignores only timestamp header line)
./scripts/check_codegen_sync.sh ../qail.rs
```

| Source (Rust) | Generated (Zig) | Contents |
|---------------|------------------|----------|
| `operators.rs` | `operators.gen.zig` | 13 enums (Operator, SortOrder, Action, etc.) |
| `values.rs` | `values.gen.zig` | 2 enums (Value, IntervalUnit) |
| `conditions.rs` | `conditions.gen.zig` | 1 struct (Condition) |
| `cages.rs` | `cages.gen.zig` | 1 enum + 1 struct (CageKind, Cage) |
| `joins.rs` | `joins.gen.zig` | 1 struct (Join) |
| `cmd/mod.rs` | `cmd.gen.zig` | 1 enum + 3 structs (QailCmd, CTEDef, OnConflict) |
| `expr.rs` | `expr.gen.zig` | 9 enums + 3 structs (Expr, WindowFrame, etc.) |

## API

### Queries

```zig
// SELECT
const cmd = QailCmd.get("users").limit(10).offset(20);

// SELECT with columns and WHERE
const cmd = QailCmd.get("orders")
    .select(&.{ Expr.col("id"), Expr.col("total") })
    .where(&.{
        .{ .condition = .{ .column = "status", .op = .eq, .value = .{ .string = "active" } } },
    });

// INSERT
const cmd = QailCmd.add("events")
    .values(&.{
        .{ .column = "name", .value = .{ .string = "click" } },
        .{ .column = "count", .value = .{ .int = 1 } },
    });

// UPDATE
const cmd = QailCmd.set("users")
    .values(&.{ .{ .column = "email", .value = .{ .string = "new@mail.com" } } })
    .where(&.{ .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = 42 } } } });

// DELETE
const cmd = QailCmd.del("users")
    .where(&.{ .{ .condition = .{ .column = "id", .op = .eq, .value = .{ .int = 42 } } } });
```

### Builders

```zig
const b = @import("qail").ast.builders;

// Conditions
const cond = b.conditions.eq("status", .{ .string = "active" });

// Aggregates
const total = b.aggregates.sum("orders.total");
const cnt = b.aggregates.count("*");

// Binary expressions
const expr = b.binary.add(Expr.col("price"), Expr.col("tax"));

// JSON access
const email = b.json.arrow("metadata", "email");

// CASE WHEN
const label = b.case_when.when(cond, .{ .string = "yes" }, .{ .string = "no" });

// Type cast
const casted = b.cast.cast(Expr.col("created_at"), "date");

// Time
const interval = b.time.interval(7, .day);
```

### Joins

```zig
const cmd = QailCmd.get("orders")
    .join(&.{.{
        .kind = .inner,
        .table = "users",
        .on_left = "orders.user_id",
        .on_right = "users.id",
    }});
```

### Connection Pool

```zig
const config = qail.driver.pool.PoolConfig.new("localhost", 5432, "postgres", "mydb")
    .password("secret")
    .max_connections(20);

var pool = try qail.driver.pool.PgPool.init(allocator, config);
defer pool.deinit();

var conn = try pool.acquire();
defer conn.release();

const rows = try conn.fetchAll(&cmd);
```

### RLS Context (Centralized)

```zig
const token = qail.driver.rls.SuperAdminToken.forSystemProcess("migration");
const admin_ctx = qail.driver.rls.RlsContext.superAdmin(token);
const tenant_ctx = qail.driver.rls.RlsContext.tenant("550e8400-e29b-41d4-a716-446655440000");

// Direct driver path
try driver.setRlsContext(&tenant_ctx);
defer driver.clearRlsContext() catch {};

// Pooled path (auto COMMIT/reset on release)
var scoped = try pool.acquireWithRlsTimeout(tenant_ctx, 5_000);
defer scoped.release();
```

### Prepared Statements

```zig
const cmd = qail.ast.QailCmd.get("users")
    .where(&.{.{ .condition = .{ .column = "id", .op = .eq, .value = .{ .param = 1 } } }});

try driver.prepare("users_by_id", &cmd);
const rows = try driver.fetchPrepared("users_by_id", &[_]?[]const u8{"42"});
```

### COPY Protocol

```zig
const rows_copied = try qail.driver.copy.copyIn(&driver.connection, "users", &.{"id", "name"}, data);
```

## CLI

```bash
zig build cli

qail --help              # Show all commands
qail symbols             # Symbol reference
qail repl                # Interactive REPL
qail migrate status      # Migration status
qail migrate up          # Apply migrations
qail diff old.qail new.qail  # Schema diff
qail fmt file.qail       # Format QAIL
qail lint file.qail      # Lint checks
```

## Project Structure

```
.
├── build.zig                 # Build graph and targets
├── build.zig.zon             # Package manifest
├── src/                      # Library, driver, tooling, tests, and benchmarks
│   ├── lib.zig               # Root module export surface
│   ├── main.zig              # Main build/test entry
│   ├── qail_main.zig         # CLI entry point
│   ├── cli.zig               # CLI commands
│   ├── ast/                  # AST core, builders, and generated parity types
│   ├── analyzer/             # Scanner and impact analysis
│   ├── data_safety/          # SQL and snapshot safety helpers
│   ├── driver/               # Connection, pool, TLS, COPY, RLS, auth
│   ├── fuzz/                 # Fuzz targets
│   ├── tests/                # Integration, smoke, stress, and fail-closed suites
│   ├── parser/               # Grammar, schema parser, migrations, differ
│   ├── protocol/             # Wire protocol codec and auth framing
│   ├── qail_pgzig_bench/     # Benchmark workloads and runner
│   ├── runtime/              # IO, time, rand, process, TLS client primitives
│   ├── sanitize/             # AST sanitization tests
│   └── transpiler/           # PostgreSQL SQL rendering
├── scripts/                  # Codegen, parity, and policy guard scripts
│   └── ci/                   # CI environment helpers
├── docs/                     # mdBook docs, guides, and theme overrides
│   ├── src/                  # Documentation pages and book index
│   └── theme/                # Custom mdBook theme assets
├── .github/workflows/        # CI workflows
├── CHANGELOG.md              # Versioned release notes
├── CONTRIBUTING.md           # Contribution guide
└── PARITY_AST_PG_DRIVER.md   # qail.rs parity notes
```



## Comparison with qail.rs

| Feature | qail-zig | qail.rs |
|---------|----------|---------|
| Total LOC | 56,749 | 210,593 |
| Dependencies | 0 | 15+ crates |
| Build Time | <2s | ~30s |
| Binary Size | ~200KB | ~2MB |
| Codegen | Yes (generated from Rust) | Yes (source of truth) |
| CLI | Yes | Yes |
| Bundled LSP binary | No (use qail.rs OpenVSX extension) | Yes |
| Connection Pool | Yes | Yes |
| TLS | Yes (std.crypto) | Yes (rustls) |
| COPY Protocol | Yes | Yes |
| Fuzz Testing | Yes (3 targets) | Yes (proptest) |
| Python Bindings | No | Yes (PyO3) |
| PHP Bindings | No | Yes |
| WASM | No | Yes |

### When to Use Each

**qail-zig** — Pure Zig PostgreSQL driver:
- Zero dependencies, fast builds, minimal binary
- Native Zig projects, embedded systems
- Maximum control & performance

**qail.rs** — Cross-language ecosystem:
- Python, PHP, WASM bindings
- Async runtime (Tokio)
- Broader language support

## Related Projects

- [qail.rs](https://github.com/qail-io/qail) — Rust implementation with language bindings
- [pg.zig](https://github.com/karlseguin/pg.zig) — Established Zig PostgreSQL driver

## License

MIT — see [LICENSE](LICENSE)

---

**Zig-first PostgreSQL Driver** | Zero Dependencies | AST-Native Queries
