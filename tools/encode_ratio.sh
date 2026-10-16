#!/bin/bash
# Ratio vs C reference encoder: sum(ours) vs sum(C) per quality.
# Usage: tools/encode_ratio.sh [dir] [q...]   (default: testdata, q0..q11)
set -u
DIR="${1:-upstream/brotli/tests/testdata}"
shift || true
QS="${@:-0 1 2 3 4 5 6 7 8 9 10 11}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for q in $QS; do
  ours=0; cref=0
  for f in "$DIR"/*; do
    case "$f" in *.compressed*|*.br) continue;; esac
    [ -f "$f" ] || continue
    "$ROOT/tmp_c/enc_roundtrip" "$q" "$f" "$TMP/e.br" >/dev/null || { echo "ENC FAIL $f"; exit 1; }
    ours=$((ours + $(stat -c %s "$TMP/e.br")))
    cref=$((cref + "$("$ROOT/tmp_c/brotli_cli" -q "$q" -c "$f" | wc -c)"))
  done
  printf "q%-2s ours=%-10d C=%-10d delta=%+.2f%%\n" "$q" "$ours" "$cref" \
    "$(python3 -c "print(($ours-$cref)/$cref*100)")"
done
