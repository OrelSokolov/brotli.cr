#!/bin/bash
# Decode benchmark (PLAN.md phase 7): Crystal decoder vs C oracle.
# Times full-file decode (CLI, output to tmpfs/null) over a set of
# .br files; prints per-engine MB/s of decompressed output.
#
# Usage: tools/bench.sh [glob]   default: tmp/silesia/br/*.q9.br

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLOB="${1:-$ROOT/tmp/silesia/br/*.q9.br}"
ORACLE="$ROOT/tmp_c/brotli_oracle"
MINE="$ROOT/tmp_c/brotli_decode"

total_out=0
t_c=0; t_x=0
for f in $GLOB; do
  [ -f "$f" ] || continue
  # output size via oracle (also warms caches)
  size=$("$ORACLE" "$f" /dev/null 2>/dev/null; stat -c %s /dev/null 2>/dev/null || echo 0)
  size=$("$ORACLE" "$f" "$ROOT/tmp/bench.out" 2>/dev/null; wc -c < "$ROOT/tmp/bench.out")
  total_out=$((total_out + size))

  s=$(date +%s%N)
  "$ORACLE" "$f" "$ROOT/tmp/bench.out" 2>/dev/null
  e=$(date +%s%N); t_c=$((t_c + (e - s) / 1000000))

  s=$(date +%s%N)
  "$MINE" "$f" "$ROOT/tmp/bench.out" 2>/dev/null
  e=$(date +%s%N); t_x=$((t_x + (e - s) / 1000000))
done
rm -f "$ROOT/tmp/bench.out"

mb=$((total_out / 1000000))
echo "output: ${total_out} bytes (${mb} MB)"
echo "C oracle:     ${t_c} ms  $(awk "BEGIN{printf \"%.1f\", $total_out / $t_c / 1000}") MB/s"
echo "Crystal port: ${t_x} ms  $(awk "BEGIN{printf \"%.1f\", $total_out / $t_x / 1000}") MB/s"
awk "BEGIN{printf \"ratio: %.2fx\n\", $t_x / $t_c}"
