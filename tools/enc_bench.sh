#!/bin/bash
# Encode benchmark: Crystal encoder (release) vs C brotli_cli.
# Times full-file compression (CLI, output to /dev/null) over a set of
# input files; prints per-engine MB/s of uncompressed input.
#
# Usage: tools/enc_bench.sh [quality] [glob]
#   default quality 9, glob tmp/silesia/* (files only, br/ dir skipped)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Q="${1:-9}"
GLOB="${2:-$ROOT/tmp/silesia/*}"
CLI_C="$ROOT/tmp_c/brotli_cli"
CLI_X="$ROOT/tmp_c/brotli_encode"

# rebuild release binary if missing or sources are newer
if [ ! -x "$CLI_X" ] || [ -n "$(find "$ROOT/src" "$ROOT/bin/brotli_encode" -newer "$CLI_X" -print -quit 2>/dev/null)" ]; then
  echo "building release bin/brotli_encode ..." >&2
  (cd "$ROOT" && crystal build --release -o "$CLI_X" bin/brotli_encode) || exit 1
fi

total_in=0
t_c=0; t_x=0
for f in $GLOB; do
  [ -f "$f" ] || continue
  sz=$(stat -c %s "$f"); total_in=$((total_in + sz))

  # warm caches + sanity: outputs must decode-verify once (cheap: skip)
  s=$(date +%s%N)
  "$CLI_C" -q "$Q" -c "$f" > /dev/null
  e=$(date +%s%N); t_c=$((t_c + (e - s) / 1000000))

  s=$(date +%s%N)
  "$CLI_X" "$f" /dev/null -q "$Q" 2>/dev/null
  e=$(date +%s%N); t_x=$((t_x + (e - s) / 1000000))
done

mb=$((total_in / 1000000))
echo "input: ${total_in} bytes (${mb} MB), quality $Q"
echo "C brotli_cli:     ${t_c} ms  $(awk "BEGIN{printf \"%.1f\", $total_in / $t_c / 1000}") MB/s"
echo "Crystal encoder:  ${t_x} ms  $(awk "BEGIN{printf \"%.1f\", $total_in / $t_x / 1000}") MB/s"
awk "BEGIN{printf \"ratio: %.2fx\n\", $t_x / $t_c}"
