# Installation

## Requirements

- Zig `0.16+`
- PostgreSQL `14+`
- macOS, Linux, or another platform supported by the Zig toolchain

## Clone and Build

```bash
git clone https://github.com/qail-io/qail-zig.git
cd qail-zig
zig build -Doptimize=ReleaseFast
```

## Optional Wrapper

`./scripts/zigw` is a thin convenience wrapper for common repo tasks.

Examples:

```bash
./scripts/zigw doctor
./scripts/zigw test
./scripts/zigw pgzig-bench qail single --workload point
```

`./scripts/zigw` delegates to normal `zig build` commands.

## Docs Build

The Zig docs book is configured to publish into the existing `dev.qail.io` tree at `public/zig/docs`.

```bash
cd docs
mdbook build
```
