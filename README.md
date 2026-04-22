# QAIL Zig

**Zig-first PostgreSQL driver with AST-native query building, codegen, CLI, and optional Linux Kerberos/GSSENC integration.**

[![Zig](https://img.shields.io/badge/Zig-0.16+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.8.0-green.svg?style=flat-square)](https://github.com/qail-io/qail-zig/releases/tag/v0.8.0)

> **Status: Active** — The PostgreSQL driver, pooling, TLS, COPY, CLI, LSP, hardening suites, and benchmark harness are live, tracking wire-protocol parity against qail.rs.
>
> **Scope:** ~22K lines of Zig across 120 tracked `.zig` files covering the wire protocol, connection pool, TLS, pipeline, COPY, AST encoder, parser, CLI, LSP, builders, and benchmarks, plus optional Linux GSSAPI/libc integration for Kerberos/GSSENC.
>
> **[qail.rs](https://github.com/qail-io/qail)** remains the generalized production platform; qail-zig is the dedicated Zig driver implementation, with enterprise-auth on Linux using the platform GSSAPI stack rather than a self-contained Zig Kerberos implementation.

> Core driver/runtime path is Zig-native and zero-GC. The Linux Kerberos/GSSENC path uses optional runtime GSSAPI loading and libc-backed dynamic linking.

- Website: [dev.qail.io/zig](https://dev.qail.io/zig)
- Docs: [dev.qail.io/zig/docs](https://dev.qail.io/zig/docs)
- Benchmarks: [dev.qail.io/zig/benchmarks](https://dev.qail.io/zig/benchmarks)
- Changelog: [`CHANGELOG.md`](./CHANGELOG.md)

## Highlights

- **~22K lines of Zig** — 120 tracked `.zig` files, Zig-first core runtime, optional Linux libc/GSSAPI integration only for Kerberos/GSSENC
- **AST-Native Queries** — Type-safe query building, not string concatenation
- **Codegen Parity** — 26 enums + 9 structs auto-generated from [qail.rs](https://github.com/qail-io/qail) AST
- **Full PostgreSQL Driver** — Connection pooling, pipelining, TLS, COPY
- **10 Builder Modules** — Conditions, aggregates, binary, cast, JSON, literals, time, case/when, shortcuts, typed
- **Fuzz Testing** — Decoder, value, and transpiler fuzzing
- **Language Server** — LSP with hover, completions, diagnostics
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

var pool = try qail.driver.pool.PgPool.connect(config);
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
const stmt = try driver.prepare("SELECT * FROM users WHERE id = $1");
const rows = try driver.fetchPrepared(&stmt, &[_]?[]const u8{"42"});
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

## LSP (Language Server)

```bash
zig build
./zig-out/bin/qail-lsp
```

- **textDocument/completion** — QAIL keywords, snippets
- **textDocument/hover** — Query info, SQL preview
- **textDocument/publishDiagnostics** — Parse errors

## Project Structure

```
src/
├── lib.zig              # Root module
├── cli.zig              # CLI implementation
├── qail_main.zig        # CLI entry point
├── data_safety.zig      # Migration safety checks
├── validator.zig        # Schema validation
├── fmt.zig              # QAIL formatter
├── ast_bench.zig        # AST build + transpile benchmark
├── ast/                 # AST types
│   ├── cmd.zig          # QailCmd (core command type)
│   ├── expr.zig         # Expression types
│   ├── operators.zig    # Operators, sort orders, actions
│   ├── values.zig       # Value types (string, int, float, etc.)
│   ├── mod.zig          # Module re-exports
│   ├── builders/        # 10 builder modules
│   │   ├── mod.zig      # Builder re-exports
│   │   ├── aggregates.zig
│   │   ├── binary.zig
│   │   ├── case_when.zig
│   │   ├── cast.zig
│   │   ├── columns.zig
│   │   ├── conditions.zig
│   │   ├── json.zig
│   │   ├── literals.zig
│   │   ├── shortcuts.zig
│   │   ├── time.zig
│   │   └── typed.zig
│   └── generated/       # Auto-generated from qail.rs
│       ├── operators.gen.zig
│       ├── values.gen.zig
│       ├── conditions.gen.zig
│       ├── cages.gen.zig
│       ├── joins.gen.zig
│       ├── cmd.gen.zig
│       └── expr.gen.zig
├── parser/              # QAIL text parser
├── protocol/            # PostgreSQL wire protocol
├── driver/              # Database driver, pool, pipeline
├── analyzer/            # Code scanner, impact analysis
├── transpiler/          # SQL output (PostgreSQL dialect)
├── fuzz/                # Fuzz test targets
│   ├── fuzz_decoder.zig
│   ├── fuzz_value.zig
│   └── fuzz_transpiler.zig
└── lsp/                 # Language Server Protocol
```



## Comparison with qail.rs

| Feature | qail-zig | qail.rs |
|---------|----------|---------|
| Lines of code | ~22K | ~130K |
| Dependencies | 0 | 15+ crates |
| Build Time | <2s | ~30s |
| Binary Size | ~200KB | ~2MB |
| Codegen | Yes (generated from Rust) | Yes (source of truth) |
| CLI | Yes | Yes |
| LSP | Yes | Yes |
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
