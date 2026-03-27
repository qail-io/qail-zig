# Changelog

This changelog tracks qail-zig releases separately from qail.rs.

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
