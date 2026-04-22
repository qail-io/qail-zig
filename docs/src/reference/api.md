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
- LSP server via `zig build` / `qail-lsp`
- benchmark runners under `src/*bench*.zig`

## Recommended Reading Order

- Start with the driver docs.
- Then read the hardening page.
- Then use the parity page to understand what is intentionally in-scope versus still missing.
