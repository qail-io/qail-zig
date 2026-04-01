# QAIL Zig Documentation

> **Zig-first PostgreSQL wire-protocol driver with AST-native query building, PostgreSQL-path parity tracking against qail.rs, and optional Linux Kerberos/GSSENC integration via the platform GSSAPI stack.**

QAIL Zig is the active Zig implementation of the QAIL PostgreSQL stack. It shares the same AST direction as qail.rs, but keeps the runtime, protocol path, and tooling in Zig. The core driver path is Zig-native; Linux Kerberos/GSSENC support is an optional runtime integration with system libc/GSSAPI rather than a self-contained Zig Kerberos stack. Full qail.rs ecosystem parity is still incomplete outside the PostgreSQL-focused track.

## Latest Updates (March 2026)

- qail-zig is active again and no longer documented as deferred.
- PG driver hardening now includes AST sanitization, stricter startup/auth sequencing, COPY fail-closed checks, and replication hardening suites.
- The current public benchmark story is now the dedicated qail-zig versus `pg.zig` shared-surface matrix.
- qail-zig now has its own versioned changelog and docs track.

## What QAIL Zig Covers

| Area | Status |
|------|--------|
| PostgreSQL driver | ✅ Active |
| Connection pooling | ✅ Active |
| Prepared pipelines | ✅ Active |
| COPY in/out helpers | ✅ Active |
| TLS | ✅ Active |
| Logical replication core | ✅ Active |
| CLI + LSP | ✅ Active |
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
