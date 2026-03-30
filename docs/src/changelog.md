# Changelog

QAIL Zig now tracks its own release notes separately from qail.rs.

## Current Highlights (`v0.7.0`)

- The canonical public benchmark page now lives at `/zig/benchmarks`, separate from the docs-book path.
- The current published benchmark story is the matched public Zig driver comparison: qail-zig versus `pg.zig` on the shared prepared-statement surface.
- The March 31, 2026 published matrix shows qail-zig winning all `10 / 10` shared throughput slices across `point`, `wide_rows`, `large_rows`, `many_params`, and `aggregate` in `single` and `pool10`.
- qail-zig docs, readme, and changelog references were bumped to `v0.7.0`.

For the repository changelog, see:

- [`CHANGELOG.md`](https://github.com/qail-io/qail-zig/blob/main/CHANGELOG.md)
