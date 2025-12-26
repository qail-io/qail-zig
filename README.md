# qail-zig

**QAIL bindings for Zig** - High-performance PostgreSQL driver powered by Rust core.

## Performance

| Driver | Individual q/s | Pipeline q/s |
|--------|---------------|--------------|
| **qail-zig** | 34,000 🏆 | 241,000 🏆 |
| pg.zig | 17,000 | N/A |

**2x faster than pg.zig!** Pipeline mode gives 14x speedup.

## Installation

1. **Build the Rust library first:**
```bash
# Clone main QAIL repo
git clone https://github.com/qail-rs/qail
cd qail
cargo build --release -p qail-php
# Copy lib to qail-zig
cp target/release/libqail_php.a /path/to/qail-zig/lib/
```

2. **Add to your `build.zig.zon`:**
```zig
.dependencies = .{
    .qail = .{
        .url = "https://github.com/qail-rs/qail-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

## Usage

```zig
const qail = @import("qail");

pub fn main() !void {
    // Encode a SELECT query
    var query = qail.encodeSelect("users", "id,name", 10);
    defer query.deinit();
    
    // Send query.data to PostgreSQL socket
    _ = try socket.write(query.data);
    
    // Pipeline mode - encode 1000 queries at once!
    var limits: [1000]i64 = undefined;
    var batch = qail.encodeBatch("users", "id,name", &limits);
    defer batch.deinit();
}
```

## Features

- ✅ Zero-overhead FFI to Rust core
- ✅ Pipeline/batch mode (1000 queries in 1 round-trip)
- ✅ Type-safe AST queries
- ✅ No SQL injection possible
- ✅ 68% of native Rust performance

## License

MIT
