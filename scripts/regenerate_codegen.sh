#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RS_DIR="${ROOT_DIR}/../qail.rs"
RS_DIR="${1:-${QAIL_RS_DIR:-${DEFAULT_RS_DIR}}}"
CODEGEN_DIR="${RS_DIR}/codegen"

if [[ ! -f "${CODEGEN_DIR}/Cargo.toml" ]]; then
  echo "error: qail.rs codegen crate not found at ${CODEGEN_DIR}" >&2
  echo "usage: scripts/regenerate_codegen.sh /path/to/qail.rs" >&2
  exit 2
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to run qail.rs/codegen" >&2
  exit 2
fi

expected_link="$(cd "${RS_DIR}/.." && pwd -P)/qail-zig"
created_link=0

cleanup() {
  if [[ "${created_link}" -eq 1 && -L "${expected_link}" ]]; then
    rm -f "${expected_link}"
  fi
}
trap cleanup EXIT

if [[ -e "${expected_link}" ]]; then
  expected_real="$(cd "${expected_link}" && pwd -P)"
  root_real="$(cd "${ROOT_DIR}" && pwd -P)"
  if [[ "${expected_real}" != "${root_real}" ]]; then
    echo "error: qail.rs codegen will write to ${expected_link}, which is not this repo" >&2
    echo "expected: ${root_real}" >&2
    echo "actual:   ${expected_real}" >&2
    exit 2
  fi
else
  ln -s "${ROOT_DIR}" "${expected_link}"
  created_link=1
fi

(
  cd "${CODEGEN_DIR}"
  cargo run --quiet
)

echo "codegen regeneration completed"
