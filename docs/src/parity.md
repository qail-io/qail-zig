# qail.rs Parity Status

qail-zig tracks qail.rs as the reference implementation for PostgreSQL driver behavior and hardening.

## Current Snapshot

As of `2026-04-23`, the narrow AST/codegen parity checks against a local `qail.rs` checkout are green:

- `./scripts/check_codegen_sync.sh ../qail.rs` -> `codegen sync check passed`
- `./scripts/check_parity.sh ../qail.rs` -> `AST actions: rust=75 zig=76`, `Encoder actions: rust=57 zig=76`, `parity check passed`

That means the Rust-driven AST porting/codegen path is working for its current scope, and the PostgreSQL AST encoder still covers the Rust action surface completely.

Real PostgreSQL CLI validation on the Zig side is also green on this date:

- Broad CLI matrix pass: `16/16` on live DB paths (`exec`, `seed`, `pull`, `migrate status|plan|up|down`).
- Migration receipt-collision stress pass: `6/6` immediate dual-`migrate up` runs across fresh databases.

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
- CLI PostgreSQL execution path (`exec`, `seed`, `pull`, `migrate status|plan|up|down`)
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
- CLI breadth outside the core PG path (`qail init`, `types`, vector/hybrid flows)
- editor tooling breadth remains on the qail.rs OpenVSX LSP track (not bundled in qail-zig)
- direct SDKs and broader non-driver surfaces

## Important Policy Delta

The main remaining policy difference is narrower now:

- `qail.rs` removed raw runtime SQL APIs from the normal execution path entirely.
- `qail-zig` now rejects `.raw` and nested procedural/raw escape hatches on the public driver path by default.
- On TLS connections, `qail-zig` now treats connection-derived `tls-server-end-point` bytes as authoritative instead of allowing caller-supplied binding overrides.
- `qail-zig` now also matches libpq-style `gssencmode` preface semantics and resolves hostnames across plain, TLS, async, and GSSENC-preface connect paths instead of assuming IPv4 literals.
- `qail-zig` now ships Linux Kerberos environment preflight diagnostics (`linuxKrb5Preflight`) and a built-in Linux Kerberos provider (`linuxKrb5TokenProvider`) via runtime GSSAPI loading on Linux.
- `qail-zig` now also exposes a session-aware `GssTokenProviderEx` callback shape, which removes the old API limitation that prevented Rust-style stateful GSS provider implementations.
- On Linux, accepted `GSSENCRequest` now proceeds into an encrypted GSS transport instead of failing closed after the preface.
- The repository now also carries a dedicated Linux Kerberos/GSSENC smoke workflow that provisions a local realm + PostgreSQL service principal and proves one AST-native roundtrip over `gssencmode=require`.
- Typed RLS helpers and typed policy parsing are now present on the Zig side, including normalization of common wrapped `current_setting(...)` forms emitted by `pg_dump`.
- The old raw nested-query and raw policy-SQL string fields have been removed from the Zig AST shape entirely; trusted compatibility now flows through internal helper modules and raw AST variants that the public runtime gate already rejects.
- Migration receipt recording now writes the full tracked shape (`version`, `name`, `applied_at`, `checksum`, `sql_up`, `sql_down`) and handles generated-version collisions without aborting roll-forward migrations.

The main remaining enterprise-auth gap is narrower now:

- runtime coverage depth and maintenance burden are now the main gap, especially expanding beyond the new smoke path and keeping the local TLS/GSS compatibility layers stable across Zig upgrades

## PG Driver Focus

The PG driver is the serious parity target right now. That is why recent work landed in:

- sanitization
- startup/auth sequencing
- protocol hardening
- replication hardening
- benchmark comparability

For detailed driver parity notes, see the repository parity file:

- `PARITY_AST_PG_DRIVER.md`
