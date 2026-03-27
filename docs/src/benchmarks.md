# Throughput Benchmarks

The current benchmark story for qail-zig is based on direct three-way comparisons between:

- `pgx` (Go)
- `qail.rs` (Rust)
- `qail-zig`

## Harness

The active harness uses matching one-shot runners for:

- `single` — prepared single-query path on one connection
- `pipeline` — prepared batch pipeline on one connection
- `pool10` — prepared singles over ten connections

## Latest Isolated 12-Sample Medians

| Benchmark | pgx (Go) | qail.rs (Rust) | qail-zig |
|-----------|----------|----------------|----------|
| Single | 35,530 q/s | 39,303 q/s | **48,561 q/s** |
| Pipeline | 456,955 q/s | **572,791 q/s** | 542,388 q/s |
| Pool10 | 96,741 q/s | 135,182 q/s | **147,078 q/s** |

## Reading the Results

- Zig currently leads on `single` and `pool10` in this harness.
- Rust still leads on `pipeline`.
- `pool10` is the noisiest mode and should always be read with variance, not just peak numbers.

## Benchmark Discipline

The benchmark numbers are only meaningful when the compared paths are equivalent. The current work explicitly separated:

- interleaved round-robin runs
- isolated block runs
- per-round CSV/SVG graph output

That makes it easier to see whether a result comes from the implementation path or from order effects.
