# Installation

## Requirements

- Zig `0.15+`
- PostgreSQL `14+`
- macOS, Linux, or another platform supported by the Zig toolchain

## Clone and Build

```bash
git clone https://github.com/qail-io/qail-zig.git
cd qail-zig
zig build -Doptimize=ReleaseFast
```

## Current macOS Note

On the current macOS 26 host used during parity work, `zig build` can fail while linking the build runner for the host target. Direct Zig commands work when the target is clamped to an older SDK floor.

Example:

```bash
./scripts/zigw doctor
./scripts/zigw test
./scripts/zigw pgzig-bench qail single --workload point
```

`./scripts/zigw` delegates to normal `zig build` on healthy toolchains and only falls back to the direct target-clamped path on the known broken host/toolchain combination.

## Docs Build

The Zig docs book is configured to publish into the existing `dev.qail.io` tree at `public/zig/docs`.

```bash
cd docs
mdbook build
```
