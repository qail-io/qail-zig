#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

allowlist=(
  "src/ast/trusted_policy_sql.zig"
  "src/parser/schema.zig"
)

hits=()
while IFS= read -r line; do
  [[ -n "$line" ]] && hits+=("$line")
done < <(rg -n '\.using_sql\s*=|\.with_check_sql\s*=' "$repo_root/src" | cut -d: -f1 | sort -u || true)

offenders=()
for file in "${hits[@]}"; do
  allowed=false
  for path in "${allowlist[@]}"; do
    if [[ "$file" == "$repo_root/$path" ]]; then
      allowed=true
      break
    fi
  done
  if [[ "$allowed" == false ]]; then
    offenders+=("$file")
  fi
done

if [[ ${#offenders[@]} -gt 0 ]]; then
  echo "Raw policy SQL compatibility assignments escaped allowlist:"
  printf '  %s\n' "${offenders[@]}"
  exit 1
fi

echo "OK: raw policy SQL compatibility assignments are confined to allowlist."
