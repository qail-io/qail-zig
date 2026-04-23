# Changelog

This changelog tracks qail-zig releases separately from qail.rs.

## Unreleased

## v0.8.1 — 2026-04-23

### Added

- Pipeline failures now retain inspectable metadata after drain-to-`ReadyForQuery`, including the failing query index, completed/skipped counts, rollback semantics, and PostgreSQL SQLSTATE/message/detail/hint fields.
- The adversarial test runner can now execute a single hardening case directly, which made the live Linux real-DB regressions easier to isolate during this patch release.

### Fixed

- Linux `PgDriver.connect` no longer crashes on the real server/real PostgreSQL path when large transport-backed driver values move through the nested connect helpers; the connect path now materializes the final driver through pointer-based `Into` helpers instead of returning oversized driver/transport values across multiple stack frames.
- Real pipeline-failure validation now confirms the cycle rollback semantics and connection recovery behavior on the Linux server after a failed pipelined statement.

## v0.8.0 — 2026-04-22

### Breaking

- qail-zig now targets Zig `0.16+` only; Zig `0.15` compatibility shims and the older std-I/O fallback path were removed.
- The public compatibility modules moved from `src/compat/*` to `src/runtime/*`; downstream imports should switch to the new runtime namespace.
- Std-I/O runtime selection now uses `QAIL_STD_IO_MODE=threaded|evented`; the earlier evented toggle path is no longer the supported contract.
- `scripts/zigw` is now a thin convenience wrapper around `zig build`; workflows that depended on the older direct-build workaround behavior should update.

### Changed

- PostgreSQL protocol processing now runs through the lower-level raw backend-message path, reducing parsing overhead and tightening startup/query handling around the driver core.
- Benchmark-heavy README tables were removed in favor of the canonical website pages at `/zig` and `/zig/benchmarks`.

### Fixed

- Linux TLS startup/auth flows now complete cleanly on a real PostgreSQL server, including live `SCRAM-SHA-256` over TLS and `channel_binding=require` validation.
- TLS transport state is now kept in stable heap-backed storage, fixing connection-move pointer invalidation in the local TLS client path.
- Linux `GSSENCRequest` handling no longer trips the Zig 0.16 nonblocking `EAGAIN` panic path during request probing.
- Prepared execution now accepts backend `.no_data` responses in the GSSENC path, fixing the cached prepared-statement flow validated against the Linux Kerberos/PostgreSQL smoke environment.
- Added and refreshed release validation coverage with the real-DB TLS smoke path, the Linux enterprise-auth smoke workflow, and regenerated AST files to restore parity CI.
- Analyzer scanner parity with qail.rs was improved for Rust-style builder chains (`Qail::get(...).columns(...).eq(...).order_by(...)`), including resolution of const/let table and column bindings.
- Scanner preprocessing now preserves line boundaries when joining multiline `let`/`const` statements, preventing inline `//` comments inside const column arrays from swallowing the remainder of the statement.
- Release workflow localhost socket hangs were fixed, and timeout connects now use the runtime socket domain cast correctly.

## v0.7.3 — 2026-04-01

### Fixed

- Linux Kerberos/GSS smoke validation now uses the correct runtime path in CI: the smoke binary links libc so Zig uses the platform `dlopen`/`dlsym` path for GSSAPI lookup instead of the narrower ELF-only loader.
- Linux GSSAPI loading now falls back to the RFC host-based service OID bytes when Ubuntu's MIT Kerberos library does not export the hostbased-service OID symbol names expected by the earlier loader.
- The dedicated `Enterprise Auth Smoke` workflow now completes successfully on `ubuntu-24.04`, validating one real AST-native roundtrip over `gssencmode=require`.

### Changed

- README and docs wording now describe qail-zig accurately as a Zig-first PostgreSQL driver with optional Linux libc/GSSAPI integration for Kerberos/GSSENC, instead of claiming a blanket pure-Zig/no-FFI implementation on every path.
- Package/docs version references are aligned on `v0.7.3`.

## v0.7.2 — 2026-04-01

### Fixed

- Restored the AST parity guard by updating `scripts/check_parity.sh` to read `CmdKind` from `src/ast/cmd/types.zig`, which matches the current AST layout.
- Fixed non-Linux `GSSENC` transport stubs so release builds compile on macOS and Windows after the new transport variant was added.
- Re-ran the parity workflow on `main`; the post-fix `Parity Guards` run for commit `e41f4dc4aa85ac1620f020756295189d4ca019f3` completed successfully.

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
