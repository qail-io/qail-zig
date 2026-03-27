# Native AST PG Driver Parity (qail-zig vs qail.rs)

Snapshot date: 2026-03-28
qail-zig ref: `f757624`
qail.rs ref: `a31ea83c`

## Scope

This parity map focuses on the PostgreSQL path only:
- AST action surface (`Action` in Rust vs `CmdKind` in Zig)
- AST-native wire encoder action coverage
- Runtime driver capabilities (pool, pipeline, copy, auth, replication, etc.)

## Validation Snapshot

Validated against `/Users/orion/qail.rs` with:
- `./scripts/check_codegen_sync.sh /Users/orion/qail.rs` -> `codegen sync check passed`
- `./scripts/check_parity.sh /Users/orion/qail.rs` -> `AST actions: rust=75 zig=76`, `Encoder actions: rust=57 zig=76`, `parity check passed`

## Quantitative Parity

1. AST action surface parity vs `qail.rs`: `75/75 = 100.0%`
- Matched after normalizing equivalent names (`TxnStart -> begin`, `Export -> copy_out`, etc.)
- Extra in `qail-zig`: `raw`
- Script counts therefore show `rust=75` and `zig=76`, while the Rust-covered surface still matches fully.

2. AST-native encoder parity vs `qail.rs` AST encoder: `57/57 = 100.0%`
- Rust encoder action set (`pg/src/protocol/ast_encoder/mod.rs`): 57 actions
- Zig encoder action set now includes all Rust-covered actions, plus Zig-only extra coverage for local-only variants.

3. AST-native encoder coverage vs full Zig action enum: `76/76 = 100.0%`
- Encoder now has an explicit branch for every `CmdKind` variant.
- Non-PostgreSQL command kinds (`create_collection`, `delete_collection`, `gen`) are explicitly fail-closed for PG unless `raw_sql` is provided.
- The `.raw` command remains available for trusted/local call sites, but `validateAst` rejects it for untrusted AST ingress.

4. Runtime capability parity (manual matrix): `~99%`
- Supported: basic driver, pooling, prepared cache, pipeline fast paths, COPY in/out, COPY helper variants (`copy_bulk`, `copy_bulk_raw`, `copy_export_raw`, `copy_export_stream_raw`), cancellation (module-level `cancel_query` + driver-level `get_cancel_key`/`cancel_token`/`cancel_query`), TLS, async connect, transaction/savepoint, startup auth (cleartext + MD5 + SCRAM-SHA-256 + SCRAM-SHA-256-PLUS policy selection), auth policy controls (allow/deny cleartext, MD5, SCRAM, Kerberos, GSSAPI, SSPI), LISTEN/NOTIFY (`listen/unlisten/unlisten_all/recv_notification/poll_notifications`), logical replication core (`connect_logical_replication`, `identify_system`, slot create/drop, `start_logical_replication`, `recv_replication_message`, `send_standby_status_update`), timeout-aware high-level connect APIs (`connect_with_timeout`, `connect_with_auth_timeout`, `connect_logical_replication_with_auth_timeout` and password/plain variants, including TLS connect-timeout path), URL/env/builder connection ergonomics (`connect_url`, `connect_env`, `connect_with_options`, `builder`), URL query auth/TLS mapping (`auth_*`, `auth_mode`, `channel_binding`, `connect_timeout`, `replication`, `sslmode`, `sslrootcert`, `tls_server_end_point_cert_der`), `PgDriver` transport unification (`sslmode=prefer|require` now routes through `TlsConnection` on `connect_with_options`), centralized RLS context SQL helpers (`RlsContext`, `context_to_sql*`, `set_rls_context*`, `clear_rls_context`) and pooled scoped APIs (`acquire_with_rls*`, `with_rls/with_system/with_global/with_tenant`, auto-reset-on-release), table-level RLS helpers (`enable_rls/disable_rls/force_rls/no_force_rls`), EXPLAIN estimate helpers (`explain_estimate` / `explain_estimate_sql`), enterprise auth handshake hooks (Kerberos/GSS/SSPI via token provider callbacks), plain TCP io backend runtime policy + transport (`QAIL_PG_IO_BACKEND=auto|sync|io_uring`; Linux `io_uring` stream path implemented for read/write in `driver/io_backend.zig`), SCRAM+ TLS channel-binding auto-derivation from configured leaf cert DER (`TlsConfig.tls_server_end_point_cert_der`)
- Partial: fully automatic TLS leaf-cert extraction from handshake for SCRAM `tls-server-end-point` binding (still blocked on Zig std TLS peer-cert API exposure; current auto path needs configured cert DER)

## Estimated Overall Parity

Heuristic weighted score for "native AST PG driver parity":
- 20% AST action surface
- 50% AST-native encoder
- 30% runtime capabilities

Estimated parity: `~99%`
Estimated gap: `<1% behind qail.rs`

## High-Impact Gap List (Priority)

1. Close the raw-runtime policy delta
- `qail.rs` removed raw runtime SQL APIs from the default execution path, while `qail-zig` still carries `.raw` for trusted/local use.
- Current mitigation: `validateAst` rejects `.raw` and other procedural escape hatches for untrusted AST ingress.

2. Finish enterprise auth polish
- Add handshake-native TLS leaf-cert extraction for `tls-server-end-point` (current SCRAM+ auto path is DER-config-driven, not peer-cert-introspected).

3. Keep Zig 0.16 migration isolated through `src/compat/*`
- Already centralized for network/io/time/rand/process/network callsites; keep new work behind compat aliases.

## Recommended Next Execution Order

1. Decide whether `.raw` remains a trusted/internal-only escape hatch or should be removed to mirror `qail.rs`
2. Enterprise auth polish (handshake-native TLS leaf-cert extraction for SCRAM+ once std TLS exposes peer cert DER)
3. Zig 0.16 std I/O migration pass (retain compat aliases and avoid leaking std API changes into driver callsites)
