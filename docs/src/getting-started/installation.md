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
zig test src/lib.zig -target aarch64-macos.15.0 -fno-emit-bin
zig build-exe src/qail_pgzig_bench.zig -target aarch64-macos.15.0 -O ReleaseFast
```

This is an environment/toolchain issue, not a qail-zig protocol issue.

## Docs Build

The Zig docs book is configured to publish into the existing `dev.qail.io` tree at `public/zig/docs`.

```bash
cd docs
mdbook build
```
