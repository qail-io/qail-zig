#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

checks=(
  "src/driver/driver.zig:pub fn executeRaw("
  "src/driver/mod.zig:pub const raw_sql ="
  "src/driver/mod.zig:pub const raw_cmd ="
  "src/ast/mod.zig:pub const raw_cmd ="
)

for check in "${checks[@]}"; do
  file="${check%%:*}"
  needle="${check#*:}"
  if rg -n -F "$needle" "$repo_root/$file" >/dev/null 2>&1; then
    echo "public raw runtime surface reintroduced: $file contains '$needle'"
    exit 1
  fi
done

echo "OK: public raw runtime surface is not re-exported."
