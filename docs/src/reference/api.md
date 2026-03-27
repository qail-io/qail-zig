# API Surface

The high-signal public surface for qail-zig currently centers on the PostgreSQL driver and related tooling.

## Core Exports

- `qail.PgDriver`
- `qail.QailCmd`
- `qail.Expr`
- `qail.validateAst`

## Driver Module

- `qail.driver.Connection`
- `qail.driver.Pipeline`
- `qail.driver.PgPool`
- `qail.driver.TlsConnection`
- `qail.driver.ConnectOptions`
- `qail.driver.AuthOptions`
- `qail.driver.RlsContext`

## Tooling

- CLI entry via `zig build cli`
- LSP server via `zig build` / `qail-lsp`
- benchmark runners under `src/*bench*.zig`

## Recommended Reading Order

- Start with the driver docs.
- Then read the hardening page.
- Then use the parity page to understand what is intentionally in-scope versus still missing.
