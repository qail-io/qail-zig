# Changelog

QAIL Zig now tracks its own release notes separately from qail.rs.

## Current Highlights (`v0.8.1`)

- Linux `PgDriver.connect` no longer crashes on the real PostgreSQL server path; the driver connect helpers now avoid returning oversized transport-backed values through nested stack frames.
- Pipeline failures now expose query index and PostgreSQL error metadata after the batch drains, which makes hardening and recovery checks explicit.
- The Linux TLS and enterprise-auth coverage from `v0.8.0` remains in place and is still part of the current release validation story.
- Package metadata, readme, and changelog references are aligned on `v0.8.1`.

For the repository changelog, see:

- [`CHANGELOG.md`](https://github.com/qail-io/qail-zig/blob/main/CHANGELOG.md)
