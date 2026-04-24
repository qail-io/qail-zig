#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QAIL_BIN="${QAIL_BIN:-${ROOT_DIR}/zig-out/bin/qail}"
GENERATED="${ROOT_DIR}/src/cli/generated/rs_cli_surface.gen.zig"
QAIL_RS_DIR=""
STRICT=false

for arg in "$@"; do
  case "${arg}" in
    --strict)
      STRICT=true
      ;;
    *)
      if [[ -z "${QAIL_RS_DIR}" ]]; then
        QAIL_RS_DIR="${arg}"
      else
        echo "usage: $0 [QAIL_RS_DIR] [--strict]" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ ! -x "${QAIL_BIN}" ]]; then
  echo "error: qail binary not found/executable at ${QAIL_BIN}" >&2
  echo "build it first: zig build" >&2
  exit 2
fi

if [[ -n "${QAIL_RS_DIR}" ]]; then
  python3 "${ROOT_DIR}/scripts/cli_surface_codegen.py" sync-check \
    --qail-rs "${QAIL_RS_DIR}" \
    --generated "${GENERATED}"
fi

if [[ "${STRICT}" == true ]]; then
  python3 "${ROOT_DIR}/scripts/cli_surface_codegen.py" parity \
    --generated "${GENERATED}" \
    --qail-zig-bin "${QAIL_BIN}" \
    --against full \
    --strict
else
  python3 "${ROOT_DIR}/scripts/cli_surface_codegen.py" parity \
    --generated "${GENERATED}" \
    --qail-zig-bin "${QAIL_BIN}" \
    --against full
fi
