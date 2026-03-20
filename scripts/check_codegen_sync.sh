#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RS_DIR="${ROOT_DIR}/../qail.rs"
RS_DIR="${1:-${QAIL_RS_DIR:-${DEFAULT_RS_DIR}}}"
GEN_DIR="${ROOT_DIR}/src/ast/generated"

generated_files=(
  operators.gen.zig
  values.gen.zig
  conditions.gen.zig
  cages.gen.zig
  joins.gen.zig
  cmd.gen.zig
  expr.gen.zig
)

for f in "${generated_files[@]}"; do
  if [[ ! -f "${GEN_DIR}/${f}" ]]; then
    echo "error: missing generated file ${GEN_DIR}/${f}" >&2
    exit 2
  fi
done

tmp_dir="$(mktemp -d)"
backup_dir="${tmp_dir}/backup"
mkdir -p "${backup_dir}"

restore_backups() {
  for f in "${generated_files[@]}"; do
    cp "${backup_dir}/${f}" "${GEN_DIR}/${f}"
  done
}

cleanup() {
  restore_backups
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

for f in "${generated_files[@]}"; do
  cp "${GEN_DIR}/${f}" "${backup_dir}/${f}"
done

"${ROOT_DIR}/scripts/regenerate_codegen.sh" "${RS_DIR}" >/dev/null

normalize() {
  sed '/^\/\/ Generated: /d' "$1"
}

mismatches=()
for f in "${generated_files[@]}"; do
  before_norm="${tmp_dir}/before-${f}"
  after_norm="${tmp_dir}/after-${f}"
  normalize "${backup_dir}/${f}" > "${before_norm}"
  normalize "${GEN_DIR}/${f}" > "${after_norm}"

  if ! cmp -s "${before_norm}" "${after_norm}"; then
    mismatches+=("${f}")
  fi
done

if [[ ${#mismatches[@]} -gt 0 ]]; then
  echo "generated AST files are out of date (excluding timestamp header):" >&2
  for f in "${mismatches[@]}"; do
    echo "  - src/ast/generated/${f}" >&2
  done
  echo "run: ./scripts/regenerate_codegen.sh ${RS_DIR}" >&2
  exit 1
fi

echo "codegen sync check passed"
