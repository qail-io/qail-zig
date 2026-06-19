# QAIL Zig Documentation

> **Zig-first PostgreSQL wire-protocol driver with AST-native query building, PostgreSQL-path parity tracking against qail.rs, and optional Linux Kerberos/GSSENC integration via the platform GSSAPI stack.**

QAIL Zig is the active Zig implementation of the QAIL PostgreSQL stack. It shares the same AST direction as qail.rs, but keeps the runtime, protocol path, and tooling in Zig. The core driver path is Zig-native; Linux Kerberos/GSSENC support is an optional runtime integration with system libc/GSSAPI rather than a self-contained Zig Kerberos stack. Full qail.rs ecosystem parity is still incomplete outside the PostgreSQL-focused track.

## Latest Updates (May 2026)

- qail-zig remains on the `v0.8.3` release line; the current `main` branch carries additional post-`v0.8.3` API hardening.
- The current public API is AST-native: `QailCmd`, typed `Expr` values, `PgDriver`, `PgPool`, `Pipeline`, COPY helpers, RLS helpers, and explicit URL/options connection APIs.
- Public raw SQL inputs and nested raw escape hatches are not part of the current driver API; public runtime and transpiler paths fail closed.
- Cursor SQL helpers, trusted/raw compatibility helpers, and data-safety raw helper modules are internal implementation details.
- CLI parity work now includes branch management, codegen tools, migration receipt hardening, and live PostgreSQL validation for `exec`, `seed`, `pull`, and `migrate status|plan|up|down`.
- Current repository snapshot: 56,749 tracked text lines total, including 53,426 lines of Zig across 172 tracked `.zig` files.
- The current qail.rs reference size for parity tracking is 210,593 total tracked lines.

## Repository Snapshot

- Total LOC: 56,749 tracked text lines in qail-zig.
- Zig LOC: 53,426 lines across 172 tracked `.zig` files.
- qail.rs total LOC: 210,593 tracked lines.

```text
.
├── src/                # Driver, AST, parser, protocol, runtime, CLI, tests, benches
├── scripts/            # Codegen, parity, and policy guards
├── docs/               # mdBook pages and theme overrides
├── .github/workflows/  # CI workflows
├── build.zig           # Build graph and targets
└── PARITY_AST_PG_DRIVER.md
```

## What QAIL Zig Covers

| Area | Status |
|------|--------|
| PostgreSQL driver | ✅ Active |
| Connection pooling | ✅ Active |
| Prepared pipelines | ✅ Active |
| COPY in/out helpers | ✅ Active |
| TLS | ✅ Active |
| Logical replication core | ✅ Active |
| CLI | ✅ Active |
| Editor LSP (via qail.rs extension) | ✅ External |
| Security hardening suites | ✅ Active |
| qail.rs parity tracking | ✅ Active |

## Implementation Positioning

- **qail.rs** is still the production reference and widest implementation.
- **qail-zig** is the serious Zig track, with active parity work and dedicated benchmarks.
- **Security boundary:** on the AST flow, the goal remains no application SQL string interpolation surface.

## Docs Map

- Start with [Installation](./getting-started/installation.md) and [Quick Start](./getting-started/quickstart.md).
- Use [PostgreSQL Driver](./core/pg-driver.md) for transport and feature coverage.
- Use [Security Hardening](./features/security-hardening.md) for the recent fail-closed work.
- Use [Throughput Benchmarks](./benchmarks.md) and [qail.rs Parity Status](./parity.md) to track the implementation line.
