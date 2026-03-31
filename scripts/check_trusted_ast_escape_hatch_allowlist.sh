#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

check_allowlist() {
  local label="$1"
  local pattern="$2"
  shift 2
  local allowlist=("$@")

  local hits=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && hits+=("$line")
  done < <(rg -n "$pattern" "$repo_root/src" | cut -d: -f1 | sort -u || true)

  local offenders=()
  for file in "${hits[@]}"; do
    local allowed=false
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
    echo "$label escaped allowlist:"
    printf '  %s\n' "${offenders[@]}"
    exit 1
  fi
}

check_allowlist \
  "source_query_sql field access" \
  '\.source_query_sql\b' \
  "src/ast/trusted_nested_query.zig" \
  "src/driver/raw_policy.zig" \
  "src/protocol/ast_encoder.zig" \
  "src/sanitize.zig"

check_allowlist \
  "CTE base_sql field access" \
  '\.base_sql\b' \
  "src/ast/trusted_nested_query.zig" \
  "src/driver/raw_policy.zig" \
  "src/protocol/ast_encoder.zig" \
  "src/sanitize.zig"

check_allowlist \
  "set_op.query_sql field access" \
  '\.query_sql\b' \
  "src/ast/trusted_nested_query.zig" \
  "src/driver/raw_policy.zig" \
  "src/protocol/ast_encoder.zig" \
  "src/sanitize.zig"

check_allowlist \
  "policy using_sql field access" \
  '\.using_sql\b' \
  "src/ast/trusted_policy_sql.zig" \
  "src/driver/raw_policy.zig" \
  "src/parser/differ/compare.zig" \
  "src/parser/differ/types.zig" \
  "src/parser/schema.zig" \
  "src/protocol/ast_encoder.zig" \
  "src/sanitize.zig" \
  "src/transpiler/postgres.zig"

check_allowlist \
  "policy with_check_sql field access" \
  '\.with_check_sql\b' \
  "src/ast/trusted_policy_sql.zig" \
  "src/driver/raw_policy.zig" \
  "src/parser/differ/compare.zig" \
  "src/parser/differ/types.zig" \
  "src/parser/schema.zig" \
  "src/protocol/ast_encoder.zig" \
  "src/sanitize.zig" \
  "src/transpiler/postgres.zig"

echo "OK: trusted AST escape-hatch field access is confined to allowlists."
