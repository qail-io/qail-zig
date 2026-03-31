# qail.rs Parity Status

qail-zig tracks qail.rs as the reference implementation for PostgreSQL driver behavior and hardening.

## Current Snapshot

As of `2026-03-31`, the narrow AST/codegen parity checks against a local `qail.rs` checkout are green:

- `./scripts/check_codegen_sync.sh ../qail.rs` -> `codegen sync check passed`
- `./scripts/check_parity.sh ../qail.rs` -> `AST actions: rust=75 zig=76`, `Encoder actions: rust=57 zig=76`, `parity check passed`

That means the Rust-driven AST porting/codegen path is working for its current scope, and the PostgreSQL AST encoder still covers the Rust action surface completely.

## Active Areas with Strong Coverage

- AST core exports
- Rust-driven AST codegen sync
- PostgreSQL wire protocol
- prepared execution and pipelines
- pooling
- TLS transport
- COPY in/out helpers
- LISTEN / NOTIFY
- logical replication core
- RLS helper APIs
- startup/auth policy controls
- TLS SCRAM channel-binding derivation and fail-closed precedence on TLS startup
- protocol hardening suites
- typed policy parsing and diff normalization for common `pg_dump` wrappers
- typed recursive CTE AST support and typed source-query constructors for views/materialized views

## Current Reality

Parity is not complete across the entire qail.rs ecosystem. The largest gaps remain outside the core PG driver track:

- gateway / auto-REST / WebSocket / OpenAPI stack
- qdrant vector driver and hybrid execution path
- workflow engine
- typed schema codegen (`qail types`) and build-time SQL / N+1 guard rails
- some CLI breadth (`qail init`, `exec`, `types`, vector/hybrid flows)
- some LSP breadth (notably formatting and code actions)
- direct SDKs and broader non-driver surfaces

## Important Policy Delta

The main remaining policy difference is narrower now:

- `qail.rs` removed raw runtime SQL APIs from the normal execution path entirely.
- `qail-zig` now rejects `.raw` and nested procedural/raw escape hatches on the public driver path by default, but still keeps some trusted/internal compatibility fields in the AST.
- On TLS connections, `qail-zig` now treats connection-derived `tls-server-end-point` bytes as authoritative instead of allowing caller-supplied binding overrides.
- Typed RLS helpers and typed policy parsing are now present on the Zig side, including normalization of common wrapped `current_setting(...)` forms emitted by `pg_dump`.
- The remaining raw nested-query and raw policy-SQL compatibility fields are now quarantined behind internal trusted helper modules plus repo allowlist checks, rather than ad hoc direct assignment or normal AST re-exports.

## PG Driver Focus

The PG driver is the serious parity target right now. That is why recent work landed in:

- sanitization
- startup/auth sequencing
- protocol hardening
- replication hardening
- benchmark comparability

For detailed driver parity notes, see the repository parity file:

- `PARITY_AST_PG_DRIVER.md`
