# QAIL Zig Benchmarks

The current public benchmark page is published at `/zig/benchmarks` on `dev.qail.io`.

The current benchmark story for qail-zig is based on direct three-way comparisons between:

- `pgx` (Go)
- `qail.rs` (Rust)
- `qail-zig`

## Harness

The active harness uses matching one-shot runners for:

- `single` — prepared single-query path on one connection
- `pipeline` — prepared batch pipeline on one connection
- `pool10` — prepared singles over ten connections

The runner now also supports workload selection:

- `point` — the current tiny prepared lookup (`SELECT id, name FROM harbors WHERE id = $1`)
- `wide_rows` — large result sets with wide rows, nullable columns, text, ints, bools, and float parsing
- `many_params` — parameter-heavy prepared query to stress bind/encode overhead directly

Current published medians are still for the `point` workload. The new workloads exist to answer a different question: whether qail-zig only wins on tiny request dispatch, or whether the advantage survives on receive/decode and parameter-heavy paths too.

## Runner Examples

```bash
# Build the comparison runner directly
zig build-exe src/qail_pgx_modes_once.zig -target aarch64-macos.15.0 -O ReleaseFast -femit-bin=/tmp/qail_zig_modes_once

# Current published baseline
/tmp/qail_zig_modes_once single --workload point
/tmp/qail_zig_modes_once pipeline --workload point
/tmp/qail_zig_modes_once pool10 --workload point

# Receive/decode stress
/tmp/qail_zig_modes_once single --workload wide_rows
/tmp/qail_zig_modes_once pool10 --workload wide_rows

# Bind/encode stress
/tmp/qail_zig_modes_once single --workload many_params
/tmp/qail_zig_modes_once pipeline --workload many_params
```

## Latest Isolated 12-Sample Medians

| Benchmark | pgx (Go) | qail.rs (Rust) | qail-zig |
|-----------|----------|----------------|----------|
| Single | 38,148 q/s | 40,725 q/s | **48,337 q/s** |
| Pipeline | 473,362 q/s | **571,663 q/s** | 561,055 q/s |
| Pool10 | 130,042 q/s | **167,746 q/s** | 163,038 q/s |

## Reading the Results

- Zig currently leads on `single` in this harness.
- Rust currently leads on `pipeline` and `pool10`.
- `pool10` is the noisiest mode and should always be read with variance, not just peak numbers.
- The published table is intentionally narrow. It does not by itself prove superiority on wide result sets, decode/materialization, or parameter-heavy queries.
- `wide_rows` is the best next receive-path benchmark.
- `many_params` is the best next bind/encode benchmark.

## Benchmark Discipline

The benchmark numbers are only meaningful when the compared paths are equivalent. The current work explicitly separated:

- interleaved round-robin runs
- isolated block runs
- per-round CSV/SVG graph output

That makes it easier to see whether a result comes from the implementation path or from order effects.

## Recommended Next Reads

- Use `wide_rows` to test whether the advantage survives large row materialization.
- Use `many_params` to test whether the advantage grows when bind/encode overhead dominates.
- Keep `point` as the tiny-query baseline so the three workloads answer different questions instead of repeating the same one.
