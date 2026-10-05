#!/bin/bash
# Compress every Silesia file at q0..q11 with the upstream C encoder.
set -u
cd "$(dirname "$0")/../tmp/silesia"
BROTLI=../../tmp_c/brotli_cli
mkdir -p br
for f in dickens mozilla mr nci ooffice osdb reymont samba sao webster x-ray xml; do
  for q in 0 1 2 3 4 5 6 7 8 9 10 11; do
    out="br/$f.q$q.br"
    [ -s "$out" ] && continue
    "$BROTLI" -q "$q" -c "$f" > "$out" || { echo "FAIL $f q$q"; exit 1; }
  done
  echo "done $f"
done
echo ALL-DONE
