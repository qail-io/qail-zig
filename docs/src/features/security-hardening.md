# Security Hardening

The recent qail-zig work focused on PG-driver hardening parity against qail.rs.

## Added or Tightened

- AST sanitization for untrusted command input
- raw SQL escape-hatch rejection on the sanitization path
- strict runtime SQL-string allowlist checks for core/driver files
- stricter startup/auth ordering checks
- authentication method-switch rejection
- SASL final / `AuthenticationOk` sequencing checks
- Bind / Parse parameter-count guards
- COPY fail-closed state validation
- replication stream fail-closed handling on malformed `CopyData`
- startup, protocol, and replication hardening suites

## Why This Matters

Protocol bugs are often state-machine bugs, not just parsing bugs. The hardening work in qail-zig now rejects malformed or unexpected backend sequences earlier instead of silently progressing through them.

## Current Safety Model

- AST-native execution is the preferred path.
- `validateAst` exists for untrusted or deserialized command ingress.
- Public driver execution rejects raw SQL command payloads; remaining SQL strings are confined to audited internal renderers/helpers.
- protocol handlers are moving toward explicit state validation and drain-to-ready behavior after errors.

## Remaining Direction

The active parity target is not "support every surface first". It is "close driver and hardening gaps without weakening the transport guarantees."
