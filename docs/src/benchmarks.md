# QAIL Zig Benchmarks

The current public benchmark page is published at `/zig/benchmarks` on `dev.qail.io`.

The current public Zig driver comparison is:

- `qail-zig`
- `pg.zig`

## Harness

The active harness is `src/qail_pgzig_bench.zig` and reports the shared prepared-statement surface:

- `single` — prepared single-query path on one connection
- `pool10` — prepared singles over ten connections

It covers five workloads:

- `point` — tiny point lookup path
- `wide_rows` — medium result sets with wide mixed rows
- `large_rows` — larger result-set receive/decode path
- `many_params` — parameter-heavy bind/encode path
- `aggregate` — more server-heavy aggregate slice

The methodology is intentionally strict:

- qail-zig workloads are authored as native `QailCmd` ASTs
- qail-zig compiles them once to SQL for statement preparation
- qail-zig then runs them through its prepared protocol path
- `pg.zig` executes the same prepared SQL templates through its cached prepared-query path
- `pipeline` is excluded so the published page stays on the clearest shared modes between the two drivers

## Runner Examples

```bash
# Canonical benchmark runner
zig build pgzig-bench -- qail single --workload point
zig build pgzig-bench -- pgzig single --workload point

# Full published matrix surface
zig build pgzig-bench -- qail pool10 --workload wide_rows
zig build pgzig-bench -- pgzig pool10 --workload wide_rows
zig build pgzig-bench -- qail single --workload many_params
zig build pgzig-bench -- pgzig pool10 --workload aggregate
```

## Latest Published 3-Round Medians

| Workload | Single (`pg.zig` / `qail-zig`) | Pool10 (`pg.zig` / `qail-zig`) |
|----------|----------------------------------|----------------------------------|
| Point | 19,535 / **44,862** q/s | 72,251 / **158,675** q/s |
| Wide rows | 4,544 / **5,474** q/s | 16,246 / **19,062** q/s |
| Large rows | 88.306 / **90.000** q/s | 279.950 / **306.865** q/s |
| Many params | 19,118 / **41,570** q/s | 71,257 / **153,386** q/s |
| Aggregate | 228.241 / **236.793** q/s | 1,438.975 / **1,474.389** q/s |

## Reading the Results

- qail-zig leads all `10 / 10` shared throughput cells in the published matrix.
- The biggest gains are on `point` and `many_params`, which points at lower execution-path and bind-handling cost.
- `wide_rows` also stays positive, which means the win is not restricted to tiny dispatch-heavy lookups.
- The smallest gaps are `large_rows` and `aggregate`, where PostgreSQL itself dominates more of the total work.
- The page is intentionally narrow on feature parity. Pipeline is a qail-zig capability, but it is not part of the `pg.zig` comparison page so the benchmark stays on the clearest shared surface.

## Benchmark Discipline

The benchmark numbers are only meaningful when the compared paths are equivalent. The current work explicitly separated:

- shared SQL template after qail-zig AST compilation
- matched prepared execution on both sides
- interleaved rounds with median reporting

That keeps the comparison at the driver/runtime boundary instead of turning it into a fake API-surface mismatch.

## Recommended Next Reads

- Read the public benchmark page at `/zig/benchmarks` for the published matrix and interpretation.
- Read `README.md` in the repo root for the short current benchmark summary.
- If you want pipeline numbers, treat them as qail-zig-only capability measurements rather than as a direct `pg.zig` comparison.
