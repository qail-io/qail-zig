# QAIL Zig

**Pure Zig PostgreSQL driver with AST-native query building.**

[![Zig](https://img.shields.io/badge/Zig-0.15+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.3.0-green.svg?style=flat-square)](https://github.com/qail-io/qail-zig/releases/tag/v0.3.0)

> 🚀 **323K queries/second** on M3 MacBook - Pure Zig, zero FFI, zero GC

## What's New in v0.3.0

- **QailCmd Parity**: Full feature parity with Rust AST (`IndexDef`, `TableConstraint`, `SetOpDef`, etc.)
- **LISTEN/NOTIFY**: Pub/Sub support for real-time PostgreSQL events
- **Transaction Commands**: `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`
- **New Builder Methods**: `distinctOn`, `groupByMode`, `onConflict`, `withCtes`, and more

## Why QAIL Zig?

- **Pure Zig**: No C dependencies, no FFI, no Rust - just Zig
- **AST-Native**: Build queries with type-safe AST, not string concatenation
- **Fast**: 323K q/s on M3 with pipelining and prepared statements
- **Simple**: One `zig build` and you're done
- **Lightweight**: ~4,000 lines of code

## Benchmarks

50 million query stress test (single connection + pipeline):

| Platform | Driver | Queries/Second | Winner |
|----------|--------|----------------|--------|
| **M3 MacBook** | qail-zig | **323,143** | ⚡ Zig +10% |
| **M3 MacBook** | qail-pg (Rust) | 294,239 | |
| **Linux EPYC** | qail-pg (Rust) | **198,000** | 🦀 Rust +13% |
| **Linux EPYC** | qail-zig | 175,000 | |

### Key Insights
- **M3 MacBook**: Zig's sync I/O beats Rust's async (faster single-core)
- **Linux servers**: Rust's async batching wins on throughput-optimized CPUs
- Both achieve **300K+ q/s** on fast hardware

> 📌 See [qail.rs](https://github.com/qail-io/qail) for the Rust version

## Installation

### Requirements
- Zig 0.15.1 or later
- PostgreSQL server

### Build from Source

```bash
git clone https://github.com/meastblue/qail-zig.git
cd qail-zig
zig build
```

### Run Tests
```bash
zig build test
```

### Run Example
```bash
zig build run
```

### Run Benchmarks
```bash
# Encoding benchmark (no DB)
zig build bench

# Full roundtrip stress test
zig build stress

# Fair comparison (matches Rust config)
zig build fair
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
| Lines of Code | ~4,000 | ~8,000 |
| Dependencies | 0 | 15+ crates |
| Build Time | <2s | ~30s |
| Binary Size | ~200KB | ~2MB |
| Performance | 323K q/s | 294K q/s |
| Async | Sync | Tokio |
| TLS | ❌ Planned | ✅ Yes |
| Connection Pool | ❌ Planned | ✅ Yes |

**Choose Zig for**: Simplicity, fast builds, minimal dependencies  
**Choose Rust for**: Mature ecosystem, async, production features

## Roadmap

- [x] Core AST types
- [x] PostgreSQL wire protocol
- [x] Prepared statements
- [x] Pipelining
- [x] Basic driver
- [x] LISTEN/NOTIFY pub/sub
- [x] Transaction commands
- [ ] TLS/SSL support
- [ ] Connection pooling
- [ ] Async I/O

## Related Projects

- [qail.rs](https://github.com/qail-io/qail) - Rust version with full features
- [QAIL Website](https://qail.rs) - Documentation and playground

## License

MIT License - see [LICENSE](LICENSE) for details.


---

**Built with ❤️ in pure Zig**
