# QAIL Zig

**Pure Zig PostgreSQL driver with AST-native query building.**

[![Zig](https://img.shields.io/badge/Zig-0.15+-F7A41D?style=flat-square&logo=zig)](https://ziglang.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-336791?style=flat-square&logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)

> 🚀 **316K queries/second** - Pure Zig, zero FFI, zero garbage collection

## Why QAIL Zig?

- **Pure Zig**: No C dependencies, no FFI, no Rust - just Zig
- **AST-Native**: Build queries with type-safe AST, not string concatenation
- **Fast**: 316K q/s with pipelining and prepared statements
- **Simple**: One `zig build` and you're done
- **Lightweight**: ~3,700 lines of code

## Benchmarks

50 million query stress test against PostgreSQL 18:

| Driver | Stack | Queries/Second | Time for 50M | Notes |
|--------|-------|----------------|--------------|-------|
| **qail-pg** | Pure Rust | 355,000 | 141s | Native tokio async |
| **qail-zig** | Pure Zig | **316,791** | 158s | **This repo** - Native, zero FFI |
| **qail-pg+zig** | Rust + Zig FFI | 315,708 | 158s | Rust calling Zig encoder |

### Key Insights
- **Pure Zig matches Rust+Zig FFI**: 316K vs 315K (no FFI overhead!)
- **Both within 11% of pure Rust**: Proves Zig's performance viability
- **Pure Zig is easier**: One `zig build`, no cross-language complexity

### Stack Explanation
- **qail-pg (Rust)**: Production Rust driver with full async/await on tokio
- **qail-zig (Zig)**: Pure Zig implementation - zero FFI, native Zig, easiest installation
- **qail-pg+zig (hybrid)**: Rust driver calling Zig encoder via FFI (shown on website benchmark)

Both tests use identical configuration:
- Query: `SELECT id, name FROM harbors LIMIT $1`
- Batch size: 10,000 queries per pipeline
- Prepared statements: Yes
- Connection: localhost TCP

> 📌 See [qail.rs](https://github.com/meastblue/qail.rs) for the Rust version

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
| Lines of Code | ~3,700 | ~8,000 |
| Dependencies | 0 | 15+ crates |
| Build Time | <2s | ~30s |
| Binary Size | ~200KB | ~2MB |
| Performance | 316K q/s | 355K q/s |
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
- [ ] TLS/SSL support
- [ ] Connection pooling
- [ ] Async I/O
- [ ] Full QAIL syntax parser

## Related Projects

- [qail.rs](https://github.com/meastblue/qail.rs) - Rust version with full features
- [QAIL Website](https://qail.dev) - Documentation and playground

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Built with ❤️ in pure Zig**
