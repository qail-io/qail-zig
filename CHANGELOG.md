# Changelog

This changelog tracks qail-zig releases separately from qail.rs.

## Unreleased

## v0.7.1 — 2026-04-01

### Added

- Linux enterprise-auth support now includes a built-in Kerberos/GSS provider stack (`linuxKrb5Preflight`, `linuxKrb5TokenProvider`, `GssTokenProviderEx`) plus accepted `GSSENCRequest` transport support on Linux instead of stopping at the negotiation preface.
- SCRAM channel binding can now derive `tls-server-end-point` bytes from the TLS handshake leaf certificate through the local TLS compat client, with configured DER fallback support kept in the same path.
- The AST now exposes first-class typed policy/query helpers, including `OwnedPolicyDef`, typed policy predicates, typed recursive CTE/query-source support, and typed `LOCK TABLE` modes.
- Schema parsing and diffing now understand typed policy predicates and normalize common `pg_dump` wrapper forms instead of falling back immediately to raw SQL strings.
- CI/parity guardrails now include public-raw-surface checks, trusted-helper visibility checks, cross-target `zig test --test-no-exec` coverage, and GSSENC framing regressions.

### Changed

- Public driver and pipeline execution now fail closed for `.raw` commands and nested raw escape hatches by default; trusted compatibility is still available, but it is now quarantined behind internal helper modules instead of the default public runtime path.
- Legacy raw nested-query and raw policy string fields were removed from the AST shape in favor of typed AST nodes and internal trusted compatibility helpers.
- Connection handling now resolves hostnames consistently across plain, TLS, async, and GSSENC-preface paths, and TLS startup treats connection-derived channel-binding bytes as authoritative over caller-supplied overrides.
- The benchmark harness now drives native QAIL AST workloads across the broader shared-surface set (`point`, `wide_rows`, `large_rows`, `many_params`, `aggregate`) instead of the earlier narrow point-query path.
- Parity docs now describe the PostgreSQL driver track as functionally near-complete and reflect the current enterprise-auth/channel-binding coverage.

### Notes

- Most of this release is additive, but the raw-runtime hardening is a real compatibility change for callers that relied on the old public raw SQL escape hatches. If that contract matters to you, treat this more like a minor release than a pure patch.
- The remaining PostgreSQL driver gap is now validation depth rather than missing feature families, especially running the Linux GSSENC/Kerberos path against real credentials in CI or a dedicated test environment.

## v0.7.0 — 2026-03-31

### Changed

- Benchmark docs/readme/changelog copy now consistently frames the current public result as the `qail-zig` versus `pg.zig` shared-surface matrix, with more neutral peer-to-peer wording.
- Benchmark docs now point to the dedicated `qail_pgzig_bench.zig` harness and the five published workloads: `point`, `wide_rows`, `large_rows`, `many_params`, and `aggregate`.
- README benchmark matrix now reflects the March 31, 2026 5-round shared-surface medians.
- Added `scripts/zigw`, a checked-in macOS fallback wrapper that keeps `test` and `pgzig-bench` usable on the known Zig 0.15.x build-runner failure path.
- Bumped qail-zig package version references to `v0.7.0`.

### Removed

- Deleted obsolete benchmark sources that still described an older FFI-era comparison and a non-equivalent 10M pipeline projection.

## v0.6.3 — 2026-03-30

### Changed

- The canonical public benchmark page now lives at `/zig/benchmarks`, and the published three-way prepared-point medians were refreshed to the March 30, 2026 12-round snapshot.
- Public benchmark interpretation was updated to the current shape: qail-zig leads prepared single-query throughput, while qail.rs currently leads the same prepared-point harness on pipeline and pool10.
- README/docs/changelog references were bumped to `v0.6.3`.

## v0.6.2 — 2026-03-28

### Fixed

- AST protocol encoder WHERE generation now matches transpiler cage semantics: `AND` filters are emitted directly and `orFilter(...)` chains are grouped as `AND ( ... OR ... )`.
- Parser WHERE-chain semantics are aligned with qail.rs: pure `and` chains and pure `or` chains are accepted; mixed infix `and/or` chains are rejected.
- Added regression coverage for select/update/delete OR-cage SQL rendering in `src/protocol/ast_encoder.zig` and parser logical-op normalization in `src/parser/grammar/clauses.zig`.

## v0.6.1 — 2026-03-28

### Fixed

- SQL transpiler now groups mixed `AND` + `OR` where clauses as `AND ( ... OR ... )` to match qail.rs `or_filter` semantics.
- Added transpiler regressions for mixed `AND`/`OR` and pure-OR where clause rendering.

## v0.6.0 — 2026-03-27

### Added

- dedicated Zig docs track intended for `dev.qail.io/zig/docs`
- dedicated qail-zig changelog
- `qail_pgx_modes_once.zig` benchmark runner for direct `pgx` / qail.rs / qail-zig comparison
- AST sanitization entry point for untrusted command validation
- startup, protocol, and replication hardening suites

### Changed

- qail-zig is documented as active again rather than deferred
- benchmark documentation now uses current three-way benchmark results
- PG driver startup/auth sequencing rejects more malformed or unsafe backend flows
- COPY and replication paths fail closed on more invalid state transitions

### Notes

- qail.rs remains the production reference and parity target.
- qail-zig is the active pure-Zig implementation track.
