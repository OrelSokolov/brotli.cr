#!/bin/bash
# Differential test: Crystal decoder vs C oracle on every corpus file.
# Compares exit code and output bytes for each input.
#
# Usage: tools/diff_test.sh [dir-with-.br-files]
#   default dir = upstream/brotli/tests/testdata

set -u
DIR="${1:-upstream/brotli/tests/testdata}"
ORACLE="$(dirname "$0")/../tmp_c/brotli_oracle"
MINE="$(dirname "$0")/../tmp_c/brotli_decode"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
for f in "$DIR"/*.compressed* "$DIR"/*.br; do
  [ -f "$f" ] || continue
  "$ORACLE" "$f" "$TMP/a.out" 2>"$TMP/a.err"; ra=$?
  "$MINE"   "$f" "$TMP/b.out" 2>"$TMP/b.err"; rb=$?
  if [ "$ra" != "$rb" ]; then
    echo "FAIL(exit) $f: oracle=$ra mine=$rb ($(tail -c 100 "$TMP/b.err" | tr '\n' ' '))"
    fail=$((fail+1)); continue
  fi
  if ! cmp -s "$TMP/a.out" "$TMP/b.out"; then
    echo "FAIL(bytes) $f: $(cmp "$TMP/a.out" "$TMP/b.out" 2>&1 | head -1)"
    fail=$((fail+1)); continue
  fi
  pass=$((pass+1))
done
echo "----------------------------------------"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
