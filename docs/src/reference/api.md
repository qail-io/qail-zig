# API Surface

The high-signal public surface for qail-zig currently centers on the PostgreSQL driver and related tooling.

## Core Exports

- `qail.driver.driver.PgDriver`
- `qail.ast.QailCmd`
- `qail.ast.Expr`
- `qail.validateAst`

## Driver Module

- `qail.driver.connection.Connection`
- `qail.driver.pipeline.Pipeline`
- `qail.driver.pool.PgPool`
- `qail.driver.tls.TlsConnection`
- `qail.driver.connect_url.ConnectOptions`
- `qail.driver.auth_options.AuthOptions`
- `qail.driver.rls.RlsContext`

## Tooling

- CLI entry via `zig build cli`
- editor LSP via the published qail.rs extension (OpenVSX/VS Code)
- benchmark runners under `src/*bench*.zig`

## Verified Real-DB CLI Surface

- `qail exec`: inline query, `--file`, `--json`, `--tx`, and `--dry-run`
- `qail seed --file` on the PostgreSQL execution path
- `qail pull` schema extraction from a live PostgreSQL database
- `qail migrate status|plan|up|down`, including receipt recording on live DB
- database URL resolution through `QAIL_DATABASE_URL`

Validation date: `2026-04-23`, against local real PostgreSQL server runs.

## Recommended Reading Order

- Start with the driver docs.
- Then read the hardening page.
- Then use the parity page to understand what is intentionally in-scope versus still missing.
