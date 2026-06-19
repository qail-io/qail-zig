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
- `qail.driver.pool.PoolConfig`
- `qail.driver.tls.TlsConnection`
- `qail.driver.connect_url.ConnectOptions`
- `qail.driver.auth_options.AuthOptions`
- `qail.driver.rls.RlsContext`

## Current API Notes

- Use `qail.ast.QailCmd` and typed `qail.ast.Expr` values for application queries.
- Use `qail.driver.driver.PgDriver.connect(...)`, `connectUrl(...)`, `connectEnv(...)`, or `connectWithOptions(...)` for direct driver connections.
- Use `qail.driver.pool.PgPool.init(allocator, config)` or `PgPool.initUri(allocator, uri)` for pooled workloads.
- Use `qail.driver.pipeline.Pipeline` for prepared batch execution.
- Validate untrusted/deserialized commands with `qail.validateAst` before execution.
- Do not depend on raw SQL, cursor SQL helper, trusted compatibility, or data-safety raw helper modules; those are internal implementation details on the current line.

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

Validation date: `2026-05-21`, against the current docs/API surface.

## Recommended Reading Order

- Start with the driver docs.
- Then read the hardening page.
- Then use the parity page to understand what is intentionally in-scope versus still missing.
