# QAIL Zig

**Pure Zig PostgreSQL driver with AST-native query building, LSP, and CLI.**

[![Zig](https://img.shields.io/badge/Zig-0.15+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.4.0-green.svg?style=flat-square)](https://github.com/qail-io/qail-zig/releases/tag/v0.4.0)

> ⚠️ **Status: Deferred** — This repository is paused until Zig stabilizes its I/O standard library (expected in Zig **0.16**). The current `std.io` has known instability issues that make production-grade networking unreliable. Rather than building on an unstable foundation and rewriting when the API breaks, we're waiting for the stable interface.
>
> **What's done:** ~15,400 lines of pure Zig covering the wire protocol, connection pool, TLS, pipeline, COPY, AST encoder, parser, CLI, and LSP — all at ~85% feature parity with [qail.rs](https://github.com/qail-io/qail). When `std.io` stabilizes, wiring up I/O to the existing modules is a matter of days, not months.
>
> **Active development continues on [qail.rs](https://github.com/qail-io/qail)** (Rust), which serves as the production implementation and battle-tested reference.

> 🚀 **1M+ queries/second** pooled, **316K** single connection - Pure Zig, zero FFI, zero GC

## Highlights

- **~15,400 lines of pure Zig** - No C, no FFI, no dependencies
- **AST-Native Queries** - Type-safe query building, not string concatenation
- **Full PostgreSQL Driver** - Connection pooling, pipelining, TLS, COPY
- **Language Server** - LSP with hover, completions, diagnostics
- **CLI** - Migrations, REPL, formatting, schema diff

## Benchmarks

| Benchmark | qail-zig | qail.rs (Rust) |
|-----------|----------|----------------|
| **Pooled (10 workers)** | 1,016,729 q/s | 1,200,000 q/s |
| **Pipeline (single)** | 316,872 q/s | ~300,000 q/s |
| **Build time** | <2s | ~30s |
| **Binary size** | ~200KB | ~2MB |

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

## CLI

```bash
# Build CLI
zig build cli

# Commands
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
# Build LSP
zig build

# Run LSP server (stdio)
./zig-out/bin/qail-lsp
```

Features:
- **textDocument/completion** - QAIL keywords, snippets
- **textDocument/hover** - Query info, SQL preview
- **textDocument/publishDiagnostics** - Parse errors

## API

### Queries

```zig
// SELECT
const cmd = QailCmd.get("users").limit(10).offset(20);

// SELECT with columns
const cols = [_]Expr{ Expr.col("id"), Expr.col("name") };
const cmd = QailCmd.get("users").select(&cols);

// SELECT DISTINCT
const cmd = QailCmd.get("users").distinct_();

// INSERT
const cmd = QailCmd.add("users");

// UPDATE
const cmd = QailCmd.set("users");

// DELETE
const cmd = QailCmd.del("users");
```

### Joins

```zig
const joins = [_]Join{.{
    .kind = .inner,
    .table = "orders",
    .alias = "o",
    .on_left = "u.id",
    .on_right = "o.user_id",
}};
const cmd = QailCmd.get("users").alias("u").join(&joins);
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

### Prepared Statements

```zig
const stmt = try driver.prepare("SELECT * FROM users WHERE id = $1");
const rows = try driver.fetchPrepared(&stmt, &[_]?[]const u8{"42"});
```

### COPY Protocol

```zig
const rows_copied = try qail.driver.copyIn(&driver.connection, "users", &.{"id", "name"}, data);
```

## Project Structure

```
src/
├── lib.zig           # Root module
├── cli.zig           # CLI implementation
├── qail_main.zig     # CLI entry point
├── data_safety.zig   # Migration safety checks
├── validator.zig     # Schema validation
├── fmt.zig           # QAIL formatter
├── ast/              # AST types (QailCmd, Expr, Value)
├── parser/           # QAIL text parser
├── protocol/         # PostgreSQL wire protocol
├── driver/           # Database driver, pool, pipeline
├── analyzer/         # Code scanner, impact analysis
├── transpiler/       # SQL output
└── lsp/              # Language Server Protocol
    ├── mod.zig
    ├── protocol.zig  # JSON-RPC types
    └── server.zig    # LSP server
```

## Module Summary

| Module | Lines | Purpose |
|--------|-------|---------|
| **driver/** | 4,294 | PostgreSQL driver, pool, pipeline, COPY |
| **parser/** | 2,284 | QAIL text syntax parser |
| **protocol/** | 1,725 | Wire protocol, auth, encoding |
| **ast/** | 1,773 | Query AST types |
| **cli.zig** | ~900 | CLI commands |
| **analyzer/** | 659 | Code scanner, migration impact |
| **lsp/** | 535 | Language server |
| **Total** | **~15,400** | |

## Comparison with qail.rs

| Feature | qail-zig | qail.rs |
|---------|----------|---------|
| Lines of Code | ~15,400 | ~30,000 |
| Dependencies | 0 | 15+ crates |
| Build Time | <2s | ~30s |
| Binary Size | ~200KB | ~2MB |
| CLI | ✅ | ✅ |
| LSP | ✅ | ✅ |
| Connection Pool | ✅ | ✅ |
| TLS | ✅ (std.crypto) | ✅ (rustls) |
| COPY Protocol | ✅ | ✅ |
| Python Bindings | ❌ | ✅ (PyO3) |
| PHP Bindings | ❌ | ✅ |
| WASM | ❌ | ✅ |

### When to Use Each

**qail-zig** - Pure Zig PostgreSQL driver:
- Zero dependencies, fast builds, minimal binary
- Native Zig projects, embedded systems
- Maximum control & performance

**qail.rs** - Cross-language ecosystem:
- Python, PHP, WASM bindings
- Async runtime (Tokio)
- Broader language support

## Related Projects

- [qail.rs](https://github.com/qail-io/qail) - Rust implementation with language bindings
- [pg.zig](https://github.com/karlseguin/pg.zig) - Alternative Zig PG driver (we have full parity + more features)

## License

MIT - see [LICENSE](LICENSE)

---

**Pure Zig PostgreSQL Driver** | Zero Dependencies | 1M+ queries/second
