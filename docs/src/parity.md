# qail.rs Parity Status

qail-zig tracks qail.rs as the reference implementation for PostgreSQL driver behavior and hardening.

## Active Areas with Strong Coverage

- AST core exports
- PostgreSQL wire protocol
- prepared execution and pipelines
- pooling
- TLS transport
- COPY in/out helpers
- LISTEN / NOTIFY
- logical replication core
- RLS helper APIs
- startup/auth policy controls
- protocol hardening suites

## Current Reality

Parity is not complete across the entire qail.rs ecosystem. The largest gaps remain outside the core PG driver track:

- gateway / auto-REST stack
- some CLI breadth
- some LSP breadth
- broader SDK and non-driver surfaces

## PG Driver Focus

The PG driver is the serious parity target right now. That is why recent work landed in:

- sanitization
- startup/auth sequencing
- protocol hardening
- replication hardening
- benchmark comparability

For detailed driver parity notes, see the repository parity file:

- `PARITY_AST_PG_DRIVER.md`
