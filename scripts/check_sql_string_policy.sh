#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

# Runtime/core SQL strings are allowed only in files that render ASTs, build
# audited internal driver commands, or test the raw-SQL rejection policy.
#
# This is intentionally a file-level guard: adding a new runtime SQL string now
# requires adding that file here with a reason, which makes review explicit.
allowlist=(
  "src/ast/cmd/types.zig|AST enum SQL labels"
  "src/ast/expr.zig|AST action SQL labels"
  "src/ast/operators.zig|AST operator SQL labels"
  "src/ast/raw_cmd.zig|private raw-command compatibility wrapper"
  "src/ast/trusted_nested_query.zig|private trusted nested-query compatibility wrapper"
  "src/ast/trusted_policy_sql.zig|private trusted policy compatibility wrapper"
  "src/ast/values.zig|literal SQL formatter tests and escaping"
  "src/data_safety/sql.zig|audited snapshot DDL/INSERT builders"
  "src/driver/copy/sql.zig|audited COPY protocol SQL builders"
  "src/driver/cursor/sql.zig|audited cursor SQL builders"
  "src/driver/cursor.zig|cursor tests and internal cursor formatting"
  "src/driver/driver.zig|driver operation labels and replication builder tests"
  "src/driver/raw_policy.zig|raw-SQL rejection tests"
  "src/driver/raw_sql.zig|central audited internal driver SQL helpers"
  "src/driver/replication.zig|audited replication command builders"
  "src/driver/rls.zig|audited transaction-local RLS SQL helpers"
  "src/protocol/ast_encoder.zig|primary AST-to-Postgres renderer"
  "src/transpiler/postgres.zig|debug SQL transpiler"
  "src/transpiler/postgres/commands.zig|debug SQL transpiler command renderer"
)

roots=(
  "$repo_root/src/ast"
  "$repo_root/src/data_safety"
  "$repo_root/src/driver"
  "$repo_root/src/protocol"
  "$repo_root/src/transpiler"
)

is_allowed() {
  local rel="$1"
  local entry path
  for entry in "${allowlist[@]}"; do
    path="${entry%%|*}"
    if [[ "$rel" == "$path" ]]; then
      return 0
    fi
  done
  return 1
}

offenders=()
while IFS= read -r file; do
  rel="${file#$repo_root/}"
  if is_allowed "$rel"; then
    continue
  fi

  hits="$(
    awk '
      /^[[:space:]]*test "/ { exit }
      /^[[:space:]]*\/\// { next }
      {
        line = tolower($0)
        if (line ~ /("|\\\\)[[:space:]]*(select|insert|update|delete|with|copy|listen|notify|unlisten|begin|commit|rollback|create|drop|alter|truncate|grant|revoke|explain|deallocate|fetch|start_replication|identify_system|read_replication_slot|create_replication_slot|drop_replication_slot|set[[:space:]]+local|set_config)([[:space:]('\''";]|$)/) {
          print FILENAME ":" FNR ":" $0
        }
      }
    ' "$file" || true
  )"
  if [[ -n "$hits" ]]; then
    offenders+=("$hits")
  fi
done < <(find "${roots[@]}" -type f -name '*.zig' | sort)

if [[ ${#offenders[@]} -gt 0 ]]; then
  echo "SQL-like runtime string literals escaped the policy allowlist:"
  printf '%s\n' "${offenders[@]}"
  echo
  echo "Use AST builders, centralize trusted SQL in an audited helper, or add a reviewed allowlist entry with a reason."
  exit 1
fi

echo "OK: runtime SQL string literals are confined to the policy allowlist."
