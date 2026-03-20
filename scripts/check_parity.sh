#!/usr/bin/env bash
set -euo pipefail

LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_RS_DIR="${ROOT_DIR}/../qail.rs"
RS_DIR="${1:-${QAIL_RS_DIR:-${DEFAULT_RS_DIR}}}"

if [[ ! -f "${RS_DIR}/core/src/ast/operators.rs" ]]; then
  echo "error: qail.rs path is invalid: ${RS_DIR}" >&2
  echo "usage: scripts/check_parity.sh /path/to/qail.rs" >&2
  exit 2
fi

if [[ ! -f "${RS_DIR}/pg/src/protocol/ast_encoder/mod.rs" ]]; then
  echo "error: missing Rust AST encoder file under ${RS_DIR}" >&2
  exit 2
fi

if [[ ! -f "${ROOT_DIR}/src/ast/cmd.zig" ]]; then
  echo "error: expected qail-zig root at ${ROOT_DIR}" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

extract_rust_actions() {
  perl -ne '
    BEGIN { $in = 0; }
    if (/pub enum Action/) { $in = 1; next; }
    if ($in && /^}/) { last; }
    next unless $in;
    if (/^\s*([A-Za-z][A-Za-z0-9_]*)\s*,/) {
      $n = $1;
      $n =~ s/([A-Z]+)([A-Z][a-z])/$1_$2/g;
      $n =~ s/([a-z0-9])([A-Z])/$1_$2/g;
      $n = lc($n);
      $n = "begin" if $n eq "txn_start";
      $n = "commit" if $n eq "txn_commit";
      $n = "rollback" if $n eq "txn_rollback";
      $n = "copy_out" if $n eq "export";
      $n = "lock_table" if $n eq "lock";
      $n = "do_block" if $n eq "do";
      $n = "release" if $n eq "release_savepoint";
      $n = "rollback_to" if $n eq "rollback_to_savepoint";
      print "$n\n";
    }
  ' "${RS_DIR}/core/src/ast/operators.rs" | sort -u
}

extract_zig_cmd_kinds() {
  perl -ne '
    BEGIN { $in = 0; }
    if (/pub const CmdKind = enum/) { $in = 1; next; }
    if ($in && /^};/) { last; }
    next unless $in;
    if (/^\s*([a-z_][a-z0-9_]*)\s*,/) {
      print "$1\n";
    }
  ' "${ROOT_DIR}/src/ast/cmd.zig" | sort -u
}

extract_rust_encoder_actions() {
  perl -ne '
    while (/Action::([A-Za-z0-9_]+)\s*=>/g) {
      $n = $1;
      $n =~ s/([A-Z]+)([A-Z][a-z])/$1_$2/g;
      $n =~ s/([a-z0-9])([A-Z])/$1_$2/g;
      $n = lc($n);
      $n = "begin" if $n eq "txn_start";
      $n = "commit" if $n eq "txn_commit";
      $n = "rollback" if $n eq "txn_rollback";
      $n = "copy_out" if $n eq "export";
      $n = "lock_table" if $n eq "lock";
      $n = "do_block" if $n eq "do";
      $n = "release" if $n eq "release_savepoint";
      $n = "rollback_to" if $n eq "rollback_to_savepoint";
      print "$n\n";
    }
  ' "${RS_DIR}/pg/src/protocol/ast_encoder/mod.rs" | sort -u
}

extract_zig_encoder_actions() {
  perl -ne '
    if (!$in && /switch \(cmd\.kind\)\s*\{/) {
      $in = 1;
      $depth = 1;
      next;
    }
    next unless $in;

    if ($depth == 1 && /(.*?)=>/) {
      $lhs = $1;
      while ($lhs =~ /\.([a-z_][a-z0-9_]*)/g) {
        print "$1\n";
      }
    }

    $depth += tr/{/{/;
    $depth -= tr/}/}/;
    if ($depth == 0) {
      last;
    }
  ' "${ROOT_DIR}/src/protocol/ast_encoder.zig" | sort -u
}

extract_rust_actions > "${tmp_dir}/rust_actions.txt"
extract_zig_cmd_kinds > "${tmp_dir}/zig_cmd_kinds.txt"
extract_rust_encoder_actions > "${tmp_dir}/rust_encoder_actions.txt"
extract_zig_encoder_actions > "${tmp_dir}/zig_encoder_actions.txt"

comm -23 "${tmp_dir}/rust_actions.txt" "${tmp_dir}/zig_cmd_kinds.txt" > "${tmp_dir}/missing_cmd_kinds.txt"
comm -13 "${tmp_dir}/rust_actions.txt" "${tmp_dir}/zig_cmd_kinds.txt" | grep -vxF "raw" > "${tmp_dir}/unexpected_cmd_kinds.txt" || true
comm -23 "${tmp_dir}/rust_encoder_actions.txt" "${tmp_dir}/zig_encoder_actions.txt" > "${tmp_dir}/missing_encoder_actions.txt"

echo "AST actions: rust=$(wc -l < "${tmp_dir}/rust_actions.txt" | tr -d ' ') zig=$(wc -l < "${tmp_dir}/zig_cmd_kinds.txt" | tr -d ' ')"
echo "Encoder actions: rust=$(wc -l < "${tmp_dir}/rust_encoder_actions.txt" | tr -d ' ') zig=$(wc -l < "${tmp_dir}/zig_encoder_actions.txt" | tr -d ' ')"

fail=0
if [[ -s "${tmp_dir}/missing_cmd_kinds.txt" ]]; then
  fail=1
  echo "missing CmdKind entries in qail-zig (present in qail.rs Action):" >&2
  sed 's/^/  - /' "${tmp_dir}/missing_cmd_kinds.txt" >&2
fi

if [[ -s "${tmp_dir}/unexpected_cmd_kinds.txt" ]]; then
  fail=1
  echo "unexpected CmdKind entries in qail-zig (not present in qail.rs Action, excluding raw):" >&2
  sed 's/^/  - /' "${tmp_dir}/unexpected_cmd_kinds.txt" >&2
fi

if [[ -s "${tmp_dir}/missing_encoder_actions.txt" ]]; then
  fail=1
  echo "missing encoder switch arms in qail-zig (present in qail.rs AST encoder):" >&2
  sed 's/^/  - /' "${tmp_dir}/missing_encoder_actions.txt" >&2
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "parity check passed"
