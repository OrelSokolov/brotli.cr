#!/bin/bash
# WOFF2 differential test (PLAN.md phase 6.3).
# For every downloaded .woff2 font:
#   1. woff2_decompress must succeed (ground-truth sanity);
#   2. extract the raw brotli stream (tools/woff2_brotli.cr);
#   3. decode it with the C oracle and the Crystal decoder, compare
#      bytes and exit codes; also check the decoded length matches the
#      uncompressed size recorded in the woff2 table directory.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/tmp/woff2}"
ORACLE="$ROOT/tmp_c/brotli_oracle"
MINE="$ROOT/tmp_c/brotli_decode"
WOFF2DEC=/tmp/woff2/build/woff2_decompress
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
for f in "$DIR"/*.woff2; do
  [ -f "$f" ] || continue
  name=$(basename "$f")

  # 1. ground truth: the reference woff2 decoder accepts the file
  #    (woff2_decompress takes one arg, writes <name>.ttf next to it)
  cp "$f" "$TMP/$name"
  if ! "$WOFF2DEC" "$TMP/$name" 2>/dev/null; then
    echo "SKIP(woff2dec) $name"
    continue
  fi

  # 2. extract the brotli stream
  span=$($ROOT/tmp_c/woff2_brotli "$f" "$TMP/$name.br" 2>&1 >/dev/null) || {
    echo "FAIL(extract) $name: $span"
    fail=$((fail+1)); continue
  }
  want_len=$(printf '%s' "$span" | sed -n 's/.*uncompressed=\([0-9]*\).*/\1/p')

  # 3. oracle vs crystal decoder
  "$ORACLE" "$TMP/$name.br" "$TMP/a.out" 2>"$TMP/a.err"; ra=$?
  "$MINE"   "$TMP/$name.br" "$TMP/b.out" 2>"$TMP/b.err"; rb=$?
  if [ "$ra" != "$rb" ] || ! cmp -s "$TMP/a.out" "$TMP/b.out"; then
    echo "FAIL $name: oracle exit=$ra mine exit=$rb ($(tail -c 80 "$TMP/b.err" | tr '\n' ' '))"
    fail=$((fail+1)); continue
  fi
  if [ "$ra" = "0" ] && [ "$(wc -c < "$TMP/a.out")" != "$want_len" ]; then
    echo "FAIL(len) $name: decoded $(wc -c < "$TMP/a.out") != woff2 uncompressed $want_len"
    fail=$((fail+1)); continue
  fi
  pass=$((pass+1))
done
echo "----------------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
