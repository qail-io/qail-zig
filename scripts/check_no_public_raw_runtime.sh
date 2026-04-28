#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
)"

checks=(
  "build.zig:addModule(\"qail_protocol\""
  "src/lib.zig:pub const protocol ="
  "src/driver/driver.zig:pub fn executeRaw("
  "src/driver/driver.zig:pub fn explainEstimateSql("
  "src/driver/mod.zig:pub const raw_sql ="
  "src/driver/mod.zig:pub const raw_cmd ="
  "src/driver/mod.zig:pub const query ="
  "src/driver/mod.zig:pub const cursor ="
  "src/ast/mod.zig:pub const raw_cmd ="
  "src/driver/prepared.zig:pub fn fromSql("
  "src/driver/pipeline.zig:pub fn getOrPrepare(self: *Pipeline, sql: []const u8)"
  "src/driver/pipeline.zig:pub fn prepare(self: *Pipeline, sql: []const u8)"
  "src/driver/pipeline.zig:pub fn pipelineBytesFast("
  "src/driver/cursor.zig:query_sql: []const u8"
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
