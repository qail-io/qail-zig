# QAIL Zig

**Pure Zig PostgreSQL driver with AST-native query building, codegen, and CLI.**

[![Zig](https://img.shields.io/badge/Zig-0.15+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.6.0-green.svg?style=flat-square)](https://github.com/qail-io/qail-zig/releases/tag/v0.6.0)

> **Status: Active** — The PostgreSQL driver, pooling, TLS, COPY, CLI, LSP, hardening suites, and benchmark harness are live, tracking wire-protocol parity against qail.rs.
>
> **Scope:** ~22K lines of pure Zig code across 120 files covering the wire protocol, connection pool, TLS, pipeline, COPY, AST encoder, parser, CLI, LSP, builders, and benchmarks.
>
> **[qail.rs](https://github.com/qail-io/qail)** remains the generalized production platform; qail-zig is the dedicated pure-Zig driver implementation.

> Pure Zig, zero FFI, zero GC. Latest isolated medians against `pgx` and qail.rs: **48.6K** single, **542K** pipeline, **147K** pool10.

- Docs: `dev.qail.io/zig/docs`
- Changelog: [`CHANGELOG.md`](./CHANGELOG.md)

## Highlights

- **~22K lines of pure Zig** — 120 tracked `.zig` files, no C, no FFI, no dependencies
- **AST-Native Queries** — Type-safe query building, not string concatenation
- **Codegen Parity** — 26 enums + 9 structs auto-generated from [qail.rs](https://github.com/qail-io/qail) AST
- **Full PostgreSQL Driver** — Connection pooling, pipelining, TLS, COPY
- **10 Builder Modules** — Conditions, aggregates, binary, cast, JSON, literals, time, case/when, shortcuts, typed
- **Fuzz Testing** — Decoder, value, and transpiler fuzzing
- **Language Server** — LSP with hover, completions, diagnostics
- **CLI** — Migrations, REPL, formatting, schema diff

## Benchmarks

### I/O: PostgreSQL Query Throughput

Isolated 12-sample medians from the `qail_pgx_modes_once` harness on `example_staging` (`SELECT id, name FROM harbors WHERE id = $1`), measured on March 27, 2026.

| Benchmark | pgx (Go) | qail.rs (Rust) | qail-zig |
|-----------|----------|----------------|----------|
| **Single (prepared, 1 conn)** | 35,530 q/s | 39,303 q/s | **48,561 q/s** |
| **Pipeline (prepared batch, 1 conn)** | 456,955 q/s | **572,791 q/s** | 542,388 q/s |
| **Pool10 (prepared singles, 10 conns)** | 96,741 q/s | 135,182 q/s | **147,078 q/s** |
| **Build time** | n/a | ~30s | <2s |
| **Binary size** | n/a | ~2MB | ~200KB |

> Performance topology: Zig maximizes single-query latencies and pool concurrency; Rust optimizes for throughput via intermediate pipeline caching.

### CPU: AST Build + Transpile (1M iterations)

| Tier | qail-zig | qail.rs (Rust) |
|------|----------|----------------|
| **T1 — SELECT \*** | 58 ns/op | 271 ns/op |
| **T2 — SELECT WHERE** | 196 ns/op | 1,755 ns/op |
| **T3 — ORDER/LIMIT** | 268 ns/op | 2,307 ns/op |
| **T4 — INSERT 5 cols** | 238 ns/op | 1,143 ns/op |
| **T5 — UPDATE WHERE** | 280 ns/op | 1,720 ns/op |
| **T6 — JOIN/GROUP/HAVING** | 340 ns/op | 4,834 ns/op |

> **Why Zig is faster here:** Zig's AST is comptime-evaluated (zero-cost struct init with `[]const u8` slices), and the transpiler appends slices directly into an `ArrayList`. Rust's transpiler uses `format!()` with intermediate `String` allocations. In production, Rust's prepared statement cache amortizes transpiler cost to zero, which is why it wins the I/O benchmark.

```bash
# Run benchmarks
zig build ast-bench          # AST benchmark
zig build bench              # I/O benchmark (requires PostgreSQL)
```

## Installation

```bash
# Requires Zig 0.15+ and PostgreSQL 14+
git clone https://github.com/qail-io/qail-zig.git
cd qail-zig
zig build -Doptimize=ReleaseFast
```

## Quick Start

```zig
const std = @import("std");
const qail = @import("qail");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Connect
    var driver = try qail.PgDriver.connect(allocator, "127.0.0.1", 5432, "postgres", "mydb");
    defer driver.deinit();

    // AST-native query
    const cmd = qail.QailCmd.get("users").limit(10);
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
const config = qail.driver.PoolConfig.new("localhost", 5432, "postgres", "mydb")
    .password("secret")
    .max_connections(20);

var pool = try qail.driver.PgPool.connect(config);
defer pool.deinit();

var conn = try pool.acquire();
defer conn.release();

const rows = try conn.fetchAll(&cmd);
```

### RLS Context (Centralized)

```zig
const token = qail.SuperAdminToken.forSystemProcess("migration");
const admin_ctx = qail.RlsContext.superAdmin(token);
const tenant_ctx = qail.RlsContext.tenant("550e8400-e29b-41d4-a716-446655440000");

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
const rows_copied = try qail.driver.copyIn(&driver.connection, "users", &.{"id", "name"}, data);
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
- [pg.zig](https://github.com/karlseguin/pg.zig) — Alternative Zig PG driver

## License

MIT — see [LICENSE](LICENSE)

---

**Pure Zig PostgreSQL Driver** | Zero Dependencies | ~22K Code Lines | 1M+ queries/second
