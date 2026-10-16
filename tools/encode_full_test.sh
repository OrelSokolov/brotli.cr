#!/bin/bash
# E7 full matrix: double roundtrip (our encoder -> oracle + own decoder)
# across all corpora x all qualities. Usage: tools/encode_full_test.sh [logfile]
# Corpora:
#   upstream/brotli/tests/testdata  q0..q11
#   tmp/edge (empty/1B/random/abc)  q0..q11
#   tmp/edge/assets (js/css/json/svg/utf8) q0..q11
#   tmp/woff2 (173 fonts, binary)   q0..q11
#   tmp/silesia (13 files, ~211MB)  q0..q11
#   tmp/edge/big/big.bin (>64MB)    q0 q1 (window wrap) q2 q9 (q10/q11 too slow)
set -u
cd "$(dirname "$0")/.."
LOG="${1:-tmp/e7_full.log}"
: > "$LOG"

ALL_Q="0 1 2 3 4 5 6 7 8 9 10 11"
fail_total=0

run() { # <dir> <q...>
  local dir=$1; shift
  for q in "$@"; do
    echo "=== $(basename "$dir") q$q ===" >> "$LOG"
    tools/encode_test.sh "$dir" "$q" >> "$LOG" 2>&1
    local line; line=$(tail -n 1 "$LOG")
    echo "$line"
    case "$line" in *"fail=0") ;; *) fail_total=1;; esac
  done
}

run upstream/brotli/tests/testdata $ALL_Q
run tmp/edge $ALL_Q
run tmp/edge/assets $ALL_Q
run tmp/woff2 $ALL_Q
run tmp/silesia $ALL_Q
run tmp/edge/big 0 1 2 9

echo "========================================"
if [ "$fail_total" = 0 ]; then echo "ALL SUITES PASS"; else echo "FAILURES PRESENT (see $LOG)"; exit 1; fi
