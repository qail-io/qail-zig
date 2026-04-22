# PostgreSQL Driver

QAIL Zig implements PostgreSQL directly over the wire protocol. The active surface includes:

- plain TCP connections
- connection timeouts
- TLS transport
- startup/auth handling for cleartext, MD5, SCRAM, and enterprise auth hooks
- prepared statement execution
- pipeline execution
- connection pooling
- COPY helpers
- LISTEN / NOTIFY
- logical replication core
- RLS helper APIs

## Primary Types

- `qail.driver.driver.PgDriver`
- `qail.driver.connection.Connection`
- `qail.driver.pipeline.Pipeline`
- `qail.driver.pool.PgPool`

## Driver Direction

The focus of qail-zig is not a SQL-string convenience wrapper. The serious path is:

1. build AST or validated command input
2. encode PostgreSQL protocol frames directly
3. execute over a pure-Zig transport path
4. fail closed on protocol and state-machine violations

## Current Emphasis

Recent work concentrated on hardening the PG driver instead of broadening surface area first. That includes startup/auth state validation, protocol framing checks, COPY sequencing checks, replication stream fail-closed handling, and AST sanitization.
