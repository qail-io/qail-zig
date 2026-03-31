# Native AST PG Driver Parity (qail-zig vs qail.rs)

Snapshot date: 2026-03-31
qail-zig ref: `working tree`
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
- Supported: basic driver, pooling, prepared cache, pipeline fast paths, COPY in/out, COPY helper variants (`copy_bulk`, `copy_bulk_raw`, `copy_export_raw`, `copy_export_stream_raw`), cancellation (module-level `cancel_query` + driver-level `get_cancel_key`/`cancel_token`/`cancel_query`), TLS, async connect, transaction/savepoint, startup auth (cleartext + MD5 + SCRAM-SHA-256 + SCRAM-SHA-256-PLUS policy selection), auth policy controls (allow/deny cleartext, MD5, SCRAM, Kerberos, GSSAPI, SSPI), LISTEN/NOTIFY (`listen/unlisten/unlisten_all/recv_notification/poll_notifications`), logical replication core (`connect_logical_replication`, `identify_system`, slot create/drop, `start_logical_replication`, `recv_replication_message`, `send_standby_status_update`), timeout-aware high-level connect APIs (`connect_with_timeout`, `connect_with_auth_timeout`, `connect_logical_replication_with_auth_timeout` and password/plain variants, including TLS connect-timeout path), URL/env/builder connection ergonomics (`connect_url`, `connect_env`, `connect_with_options`, `builder`), URL query auth/TLS mapping (`auth_*`, `auth_mode`, `channel_binding`, `connect_timeout`, `replication`, `sslmode`, `sslrootcert`, `tls_server_end_point_cert_der`), `PgDriver` transport unification (`sslmode=prefer|require` now routes through `TlsConnection` on `connect_with_options`), centralized RLS context SQL helpers (`RlsContext`, `context_to_sql*`, `set_rls_context*`, `clear_rls_context`) and pooled scoped APIs (`acquire_with_rls*`, `with_rls/with_system/with_global/with_tenant`, auto-reset-on-release), table-level RLS helpers (`enable_rls/disable_rls/force_rls/no_force_rls`), EXPLAIN estimate helpers (`explain_estimate` / `explain_estimate_sql`), enterprise auth handshake hooks (Kerberos/GSS/SSPI via token provider callbacks), plain TCP io backend runtime policy + transport (`QAIL_PG_IO_BACKEND=auto|sync|io_uring`; Linux `io_uring` stream path implemented for read/write in `driver/io_backend.zig`), SCRAM+ TLS channel-binding auto-derivation from the handshake leaf cert with configured DER fallback (`TlsConfig.tls_server_end_point_cert_der`)
- Newly closed in this slice: public raw-runtime execution is fail-closed by default, typed RLS helper builders are available through `ast.policy`, schema policy parsing normalizes common `pg_dump` wrappers (`NULLIF(current_setting(...))::type`, `COALESCE(current_setting(...), 'false'::text)`), policy diffs now treat those wrappers as equivalent typed predicates instead of emitting churn, and handwritten Zig `CTEDef` regained the typed `recursive_query` / `source_table` shape already present in Rust and the generated AST.

## Estimated Overall Parity

Heuristic weighted score for "native AST PG driver parity":
- 20% AST action surface
- 50% AST-native encoder
- 30% runtime capabilities

Estimated parity: `~99%`
Estimated gap: mostly maturity/polish, not missing core PG-driver features

## High-Impact Gap List (Priority)

1. Keep the remaining trusted/internal raw escape hatches quarantined
- Public driver execution is already fail-closed for `.raw` and nested raw procedural escapes.
- Remaining raw surfaces are legacy/internal compatibility fields and trusted helper paths, not the default runtime contract.
- Raw nested-query compatibility assignment is now confined to `src/ast/trusted_nested_query.zig`, and repo checks gate both assignment and field access spread.

2. Finish enterprise auth polish
- Keep the local TLS client fork isolated and covered so handshake-native `tls-server-end-point` extraction survives Zig stdlib churn.

3. Keep Zig 0.16 migration isolated through `src/compat/*`
- Already centralized for network/io/time/rand/process/network callsites; keep new work behind compat aliases.

## Recommended Next Execution Order

1. Enterprise auth polish (keep the local TLS client fork minimal and compatible across Zig upgrades)
2. Decide whether the remaining trusted/internal raw escape hatches should stay as compatibility fields or be removed entirely
3. Zig 0.16 std I/O migration pass (retain compat aliases and avoid leaking std API changes into driver callsites)
