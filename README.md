# qail-zig

**QAIL bindings for Zig** - High-performance PostgreSQL driver powered by Rust core.

## Performance

| Driver | Individual q/s | Pipeline q/s |
|--------|---------------|--------------|
| **qail-zig** | 34,000 🏆 | 241,000 🏆 |
| pg.zig | 17,000 | N/A |

**2x faster than pg.zig!** Pipeline mode gives 14x speedup.

## Quick Start

```bash
# Clone and build - library downloads automatically!
git clone https://github.com/qail-rs/qail-zig
cd qail-zig
zig build -Doptimize=ReleaseFast

# Run benchmarks
./zig-out/bin/qail-zig-bench
./zig-out/bin/qail-zig-bench-io
```

The build script **automatically downloads** the correct `libqail.a` for your platform from GitHub releases.

## Usage in Your Project

1. Add to your `build.zig.zon`:
```zig
.dependencies = .{
    .qail = .{
        .url = "https://github.com/qail-rs/qail-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",  // zig build will tell you this
    },
},
```

2. In your `build.zig`:
```zig
const qail = b.dependency("qail", .{});
exe.root_module.addImport("qail", qail.module("qail"));
```

3. Use in code:
```zig
const qail = @import("qail");

pub fn main() !void {
    // Encode a SELECT query
    var query = qail.encodeSelect("users", "id,name", 10);
    defer query.deinit();
    
    // Send query.data to PostgreSQL socket
    _ = try socket.write(query.data);
}
```

## Features

- ✅ **Zero setup** - library downloads automatically
- ✅ Zero-overhead FFI to Rust core
- ✅ Pipeline/batch mode (1000 queries in 1 round-trip)
- ✅ Type-safe AST queries
- ✅ No SQL injection possible
- ✅ 68% of native Rust performance

## Platforms

| Platform | Status |
|----------|--------|
| macOS arm64 | ✅ |
| macOS x64 | ✅ |
| Linux x64 | ✅ |
| Linux arm64 | ✅ |
| Windows x64 | ✅ |

## License

MIT
