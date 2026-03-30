#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

allowlist=(
  "src/ast/raw_cmd.zig"
)

exclude_args=()
for path in "${allowlist[@]}"; do
  exclude_args+=(-g "!$path")
done

if hits="$(rg -n 'QailCmd\.raw\(' "$repo_root/src" "${exclude_args[@]}")"; then
  echo "Direct QailCmd.raw() usage found outside allowlist:"
  echo "$hits"
  echo
  echo "Route through src/ast/raw_cmd.zig instead."
  exit 1
fi

echo "OK: no direct QailCmd.raw() usage outside allowlist."
