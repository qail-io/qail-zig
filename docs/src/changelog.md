# Changelog

QAIL Zig now tracks its own release notes separately from qail.rs.

## Current Highlights (`v0.8.0`)

- qail-zig is now Zig `0.16+` only, with the older compatibility layer consolidated into the `runtime/*` namespace.
- The Linux TLS path was fixed and live-validated against a real PostgreSQL server, including TLS SCRAM channel binding.
- The Linux Kerberos/GSSENC smoke path remains green in CI and now shares the same tightened release validation story.
- Package metadata, readme, and changelog references are aligned on `v0.8.0`.

For the repository changelog, see:

- [`CHANGELOG.md`](https://github.com/qail-io/qail-zig/blob/main/CHANGELOG.md)
