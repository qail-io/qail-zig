# Pool, Pipeline, and COPY

## Pool

`PgPool` provides fixed-size connection pooling with scoped helpers and reset-on-release behavior.

Use it when:

- you want concurrent prepared single-query workloads
- you need pooled RLS or tenant-scoped acquisition
- you want explicit `min_connections` / `max_connections`

## Pipeline

`Pipeline` batches `Bind + Execute` messages and sends one `Sync` per batch. This is the highest-throughput path for prepared count-only or row-collecting workloads on a single connection.

Use it when:

- you already have a prepared statement
- batch throughput matters more than per-query latency
- you want one connection and many completions per round trip

## COPY

The COPY helpers are active and hardened.

Supported areas:

- COPY FROM STDIN helpers
- COPY TO STDOUT raw export helpers
- stricter protocol sequencing checks
- fail-closed handling on malformed COPY states and oversized data

COPY is now treated as a protocol feature that must reject unexpected backend frames rather than attempting to continue.
