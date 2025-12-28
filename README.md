# QAIL Zig

**Pure Zig PostgreSQL driver with AST-native query building and CLI.**

[![Zig](https://img.shields.io/badge/Zig-0.15+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.4.0-green.svg?style=flat-square)](https://github.com/qail-io/qail-zig/releases/tag/v0.4.0)

> 🚀 **1M+ queries/second** with pooling, **316K** single connection - Pure Zig, zero FFI, zero GC

## What's New in v0.4.0

- **CLI Parity**: Full 1:1 CLI command parity with qail.rs
  - `qail repl` - Interactive REPL
  - `qail migrate status/up/down/plan/create/shadow/promote/abort` 
  - `qail explain/fmt/pull/check/diff/lint/watch`
- **QailCmd Parity**: Full feature parity with Rust AST
- **TLS/SSL**: Pure Zig TLS support via std.crypto.tls
- **Connection Pool**: Thread-safe PgPool

## CLI Usage

```bash
# Build the CLI
zig build -Doptimize=ReleaseFast

# Show help
./zig-out/bin/qail --help

# Show symbol reference
./zig-out/bin/qail symbols

# Check migration status
./zig-out/bin/qail migrate status postgres://localhost/mydb

# Apply migrations
./zig-out/bin/qail migrate up old.qail:new.qail postgres://localhost/mydb
```

## Why QAIL Zig?

- **Pure Zig**: No C dependencies, no FFI, no Rust - just Zig
- **AST-Native**: Build queries with type-safe AST, not string concatenation
- **Fast**: 1M+ q/s pooled, 316K single connection with pipelining
- **Simple**: One `zig build` and you're done
- **Lightweight**: ~4,500 lines of code

## Benchmarks

### Pool Benchmark (150M queries, 10 workers)
Query: `SELECT id, name FROM harbors LIMIT $1`

| Driver | Queries/Second | Rows Parsed |
|--------|----------------|-------------|
| **qail-zig** | **1,016,729** | 825M |
| qail-pg (Rust) | 1,200,000 | - |

### Single Connection (50M queries, pipeline)

| Driver | Queries/Second | Time |
|--------|----------------|------|
| **qail-zig** | **316,872** | 157.8s |
| qail-pg (Rust) | ~300,000 | ~166s |

> 📌 See [qail.rs](https://github.com/qail-io/qail) for the Rust version

## Installation

### Requirements
- Zig 0.15.2 or later ([download](https://ziglang.org/download/))
- PostgreSQL 14+ server

### Build from Source

```bash
# Clone the repository
git clone https://github.com/qail-io/qail-zig.git
cd qail-zig

# Build in release mode
zig build -Doptimize=ReleaseFast

# Build and run the CLI
./zig-out/bin/qail --help
```

### Run Benchmarks

```bash
# Encoding benchmark (no database required)
zig build bench -Doptimize=ReleaseFast

# Pipeline stress test (requires PostgreSQL)
zig build stress -Doptimize=ReleaseFast

# Pool benchmark (matches Rust config)
zig build pool -Doptimize=ReleaseFast
```

## Quick Start

```zig
const std = @import("std");
const qail = @import("qail");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Connect to PostgreSQL
    var driver = try qail.PgDriver.connect(
        allocator,
        "127.0.0.1",
        5432,
        "postgres",
        "mydb",
    );
    defer driver.deinit();
    
    // Build query with AST
    const cols = [_]qail.Expr{ 
        qail.Expr.col("id"), 
        qail.Expr.col("name") 
    };
    const cmd = qail.QailCmd.get("users")
        .select(&cols)
        .limit(10);
    
    // Execute and fetch rows
    const rows = try driver.fetchAll(&cmd);
    defer allocator.free(rows);
    
    for (rows) |row| {
        std.debug.print("id={s}, name={s}\n", .{
            row.getString(0) orelse "null",
            row.getString(1) orelse "null",
        });
    }
}
```

## AST Builder API

### SELECT Queries
```zig
// Simple select
const cmd = QailCmd.get("users");

// With columns
const cols = [_]Expr{ Expr.col("id"), Expr.col("name") };
const cmd = QailCmd.get("users").select(&cols).limit(10);

// With aggregates
const cols = [_]Expr{ Expr.count(), Expr.sum("amount") };
const cmd = QailCmd.get("orders").select(&cols).distinct_();
```

### Joins
```zig
const joins = [_]qail.ast.Join{.{
    .kind = .inner,
    .table = "orders",
    .alias = "o",
    .on_left = "u.id",
    .on_right = "o.user_id",
}};
const cmd = QailCmd.get("users")
    .alias("u")
    .select(&cols)
    .join(&joins);
```

### Mutations
```zig
// INSERT
const cmd = QailCmd.add("users");

// UPDATE  
const cmd = QailCmd.set("users");

// DELETE
const cmd = QailCmd.del("users");

// TRUNCATE
const cmd = QailCmd.truncate("temp");
```

## Project Structure

```
src/
├── lib.zig           # Root module
├── cli.zig           # CLI implementation (NEW in v0.4.0)
├── qail_main.zig     # CLI entry point (NEW in v0.4.0)
├── ast/              # AST types (QailCmd, Expr, Value)
│   ├── mod.zig
│   ├── cmd.zig       # Query commands
│   ├── expr.zig      # Expressions
│   ├── values.zig    # Literal values
│   └── operators.zig # Operators
├── protocol/         # PostgreSQL wire protocol
│   ├── mod.zig
│   ├── wire.zig      # Message types
│   ├── encoder.zig   # Frontend messages
│   ├── decoder.zig   # Backend parsing
│   ├── auth.zig      # SCRAM-SHA-256
│   ├── types.zig     # OID mappings
│   └── ast_encoder.zig # AST → Wire
├── driver/           # Database driver
│   ├── mod.zig
│   ├── connection.zig
│   ├── driver.zig    # PgDriver
│   └── row.zig       # PgRow
└── transpiler/       # SQL output (debug only)
    ├── mod.zig
    └── postgres.zig
```

## Comparison with Rust Version

| Feature | QAIL Zig | QAIL Rust |
|---------|----------|-----------|
| Lines of Code | ~4,500 | ~10,000 |
| Dependencies | 0 | 15+ crates |
| Build Time | <2s | ~30s |
| Binary Size | ~200KB | ~2MB |
| CLI | ✅ Full parity | ✅ Full |
| Performance | 1M q/s (pool) | 1.2M q/s (pool) |
| TLS | ✅ Pure Zig | ✅ rustls |
| Connection Pool | ✅ PgPool | ✅ Yes |

**Choose Zig for**: Simplicity, fast builds, zero dependencies  
**Choose Rust for**: Mature ecosystem, async, language bindings

## Related Projects

- [qail.rs](https://github.com/qail-io/qail) - Rust version with full features
- [QAIL Website](https://qail.rs) - Documentation and playground

## License

MIT License - see [LICENSE](LICENSE) for details.


---

**Built with ❤️ in pure Zig**
