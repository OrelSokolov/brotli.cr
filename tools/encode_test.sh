#!/bin/bash
# Roundtrip test: our encoder -> both decoders -> byte-compare with the
# original. Usage: tools/encode_test.sh [dir] [quality]
#   dir defaults to upstream/brotli/tests/testdata; quality defaults to 0.
set -u
DIR="${1:-upstream/brotli/tests/testdata}"
Q="${2:-0}"
ORACLE="$(dirname "$0")/../tmp_c/brotli_oracle"
CRY="$(dirname "$0")/../tmp_c/enc_roundtrip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
for f in "$DIR"/*; do
  case "$f" in *.compressed*|*.br) continue;; esac
  [ -f "$f" ] || continue
  "$CRY" "$Q" "$f" "$TMP/e.br" || { echo "ENCODE FAIL: $f"; fail=$((fail+1)); continue; }
  "$ORACLE" "$TMP/e.br" "$TMP/a.out" 2>/dev/null; ra=$?
  if [ "$ra" != 0 ] || ! cmp -s "$TMP/a.out" "$f"; then
    echo "ORACLE MISMATCH: $f (exit $ra)"; fail=$((fail+1)); continue
  fi
  "$CRY" "$Q" "$TMP/e.br" "$TMP/b.out" dec || { echo "DECODE FAIL: $f"; fail=$((fail+1)); continue; }
  cmp -s "$TMP/b.out" "$f" || { echo "OWN DECODER MISMATCH: $f"; fail=$((fail+1)); continue; }
  pass=$((pass+1))
done
echo "----------------------------------------"
echo "q$Q pass=$pass fail=$fail"
