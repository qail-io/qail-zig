# Changelog

QAIL Zig now tracks its own release notes separately from qail.rs.

## Current Highlights (post-`v0.8.3`, `2026-05-21`)

- qail-zig's latest release tag is `v0.8.3`; the current docs also cover post-`v0.8.3` main-branch API hardening.
- Public raw SQL inputs, cursor SQL helpers, trusted/raw compatibility helpers, and data-safety raw helpers are hidden from the current public API.
- Public driver execution and public transpilation fail closed for raw commands and nested raw escape hatches.
- Real PostgreSQL CLI matrix remains validated on live DB paths for `exec` (inline/file/json/tx/dry-run), `seed`, `pull`, and `migrate status|plan|up|down`.
- Migration receipt writes include `applied_at`, `sql_down`, conflict-safe insertion, and generated-version retry semantics.
- AST column-definition SQL rendering preserves nullable-by-default columns correctly; `NOT NULL` is emitted only when explicitly requested.
- The Linux `PgDriver.connect` stack-size fix and pipeline failure metadata from `v0.8.1` remain in place.

For the repository changelog, see:

- [`CHANGELOG.md`](https://github.com/qail-io/qail-zig/blob/main/CHANGELOG.md)
