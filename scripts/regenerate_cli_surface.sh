#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RS_DIR="${ROOT_DIR}/../qail.rs"
RS_DIR="${1:-${QAIL_RS_DIR:-${DEFAULT_RS_DIR}}}"
OUTPUT_FILE="${ROOT_DIR}/src/cli/generated/rs_cli_surface.gen.zig"

python3 "${ROOT_DIR}/scripts/cli_surface_codegen.py" regen \
  --qail-rs "${RS_DIR}" \
  --output "${OUTPUT_FILE}"

