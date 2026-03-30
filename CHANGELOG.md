# Changelog

This changelog tracks qail-zig releases separately from qail.rs.

## Unreleased

### Changed

- Benchmark docs/readme/changelog copy now consistently frames the current public result as the `qail-zig` versus `pg.zig` shared-surface matrix, with more neutral peer-to-peer wording.
- Benchmark docs now point to the dedicated `qail_pgzig_bench.zig` harness and the five published workloads: `point`, `wide_rows`, `large_rows`, `many_params`, and `aggregate`.
- Added `scripts/zigw`, a checked-in macOS fallback wrapper that keeps `test` and `pgzig-bench` usable on the known Zig 0.15.x build-runner failure path.

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
