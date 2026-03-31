#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

allowlist=(
  "src/driver/driver.zig"
)

hits=()
while IFS= read -r line; do
  [[ -n "$line" ]] && hits+=("$line")
done < <(rg -n 'executeTrustedRaw\(' "$repo_root/src" | cut -d: -f1 | sort -u || true)

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
  echo "executeTrustedRaw() callsites escaped allowlist:"
  printf '  %s\n' "${offenders[@]}"
  exit 1
fi

echo "OK: executeTrustedRaw() callsites are confined to allowlist."
