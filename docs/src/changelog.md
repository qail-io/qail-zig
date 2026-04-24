# Changelog

QAIL Zig now tracks its own release notes separately from qail.rs.

## Current Highlights (Post-`v0.8.1`, `2026-04-23`)

- Real PostgreSQL CLI matrix is validated on live DB paths for `exec` (inline/file/json/tx/dry-run), `seed`, `pull`, and `migrate status|plan|up|down`.
- Migration receipt writes now include `applied_at` and `sql_down` on the AST-native path, matching the migration table contract used in runtime flows.
- Auto migration receipts now use conflict-safe insertion and version-retry semantics, so immediate back-to-back `migrate up` calls no longer fail on `_qail_migrations_version_key`.
- Migration-table creation via the public AST route remains raw-policy compatible (no trusted-only column default escape hatch in that path).
- AST column-definition SQL rendering now preserves nullable-by-default columns correctly; `NOT NULL` is emitted only when explicitly requested.
- The Linux `PgDriver.connect` and pipeline failure-metadata fixes from `v0.8.1` remain in place.

For the repository changelog, see:

- [`CHANGELOG.md`](https://github.com/qail-io/qail-zig/blob/main/CHANGELOG.md)
