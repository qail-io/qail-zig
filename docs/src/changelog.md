# Changelog

QAIL Zig now tracks its own release notes separately from qail.rs.

## Current Highlights (`v0.7.3`)

- The PostgreSQL driver track now includes a real Linux Kerberos/GSSENC smoke workflow against a provisioned PostgreSQL service principal.
- The smoke path is now validated on CI with the correct Linux runtime shape: RFC hostbased-service OID fallback plus libc-backed `dlopen`/`dlsym` for GSSAPI loading.
- README/docs wording now reflects the real implementation boundary: Zig-first core runtime, with optional Linux libc/GSSAPI integration for Kerberos/GSSENC instead of a blanket "pure Zig, zero FFI" claim.
- Package metadata, readme, and changelog references are aligned on `v0.7.3`.

For the repository changelog, see:

- [`CHANGELOG.md`](https://github.com/qail-io/qail-zig/blob/main/CHANGELOG.md)
