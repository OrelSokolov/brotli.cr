#!/bin/bash
# lgwin sweep: encode with -w 10..22 across qualities, verify with the
# C oracle AND our own decoder (both must byte-match the original).
set -u
cd "$(dirname "$0")/.."
ENC=tmp_c/brotli_encode
ORA=tmp_c/brotli_oracle
DEC=tmp_c/brotli_decode
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

FILES="upstream/brotli/tests/testdata/alice29.txt \
       upstream/brotli/tests/testdata/mapsdatazrh \
       upstream/brotli/tests/testdata/random_chunks \
       upstream/brotli/tests/testdata/ukkonooa \
       upstream/brotli/tests/testdata/cp1251-utf16le \
       tmp/edge/abc400k.bin tmp/edge/one.bin tmp/edge/empty.bin"
QS="0 1 2 3 5 9 11"
pass=0; fail=0
for w in $(seq 10 22); do
  for q in $QS; do
    for f in $FILES; do
      $ENC "$f" "$TMP/e.br" -q "$q" -w "$w" 2>/dev/null || { echo "ENC FAIL w$w q$q $f"; fail=$((fail+1)); continue; }
      $ORA "$TMP/e.br" "$TMP/a.out" 2>/dev/null && cmp -s "$TMP/a.out" "$f" || { echo "ORACLE FAIL w$w q$q $f"; fail=$((fail+1)); continue; }
      $DEC "$TMP/e.br" "$TMP/b.out" 2>/dev/null && cmp -s "$TMP/b.out" "$f" || { echo "OWN DEC FAIL w$w q$q $f"; fail=$((fail+1)); continue; }
      pass=$((pass+1))
    done
  done
done
echo "----------------------------------------"
echo "lgwin sweep: pass=$pass fail=$fail"
[ "$fail" = 0 ]
