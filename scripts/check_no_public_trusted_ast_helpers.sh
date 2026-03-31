#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

hits="$(
  rg -n 'pub const trusted_(nested_query|policy_sql)\b' \
    "$repo_root/src/ast/mod.zig" \
    "$repo_root/src/lib.zig" \
    || true
)"

if [[ -n "$hits" ]]; then
  echo "trusted AST helper modules must not be publicly re-exported:"
  printf '%s\n' "$hits"
  exit 1
fi

echo "OK: trusted AST helper modules are not publicly re-exported."
