# Contributing to qail-zig

## Repository policy

- Upstream branch model is `main` only.
- Do not create long-lived branches in `qail-io/qail-zig` (no `staging`, `dev`, or feature branches).
- All code contributions must come through Pull Requests opened from contributor forks.

## Contribution flow

1. Fork `qail-io/qail-zig`.
2. Create your work branch in your fork.
3. Open a PR from your fork branch to `qail-io/qail-zig:main`.
4. Wait for CI and maintainer review before merge.

## Push policy

- Do not push directly to upstream without maintainer approval.
- For collaborator-assisted sessions, always ask the maintainer before running any `git push`.
- Maintainer approval is required before tags or release pushes.

## Local checks before PR

- `zig fmt` on edited Zig files.
- `zig build test`
- If AST/codegen touched: `./scripts/check_parity.sh ./qail.rs` and `./scripts/check_codegen_sync.sh ./qail.rs`
