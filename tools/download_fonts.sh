#!/bin/bash
# Download WOFF2 fonts from Google Fonts CSS API (browser UA) — the real
# streams freetype.cr will decode.
set -u
DIR="$(dirname "$0")/../tmp/woff2"
mkdir -p "$DIR"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

FAMILIES=(Roboto Open+Sans Lato Montserrat Oswald Raleway Poppins Inter
  Nunito Merriweather Playfair+Display Source+Sans+3 Ubuntu Fira+Sans
  Work+Sans Cabin Lobster Anton Pacifico Caveat Comfortaa Noto+Sans
  Noto+Serif JetBrains+Mono IBM+Plex+Sans Cormorant+Garamond Rubik
  Karla Josefin+Sans Quicksand Zilla+Slab Archivo Catamaran Asap)

count=0
for fam in "${FAMILIES[@]}"; do
  css=$(curl -sL --max-time 30 -A "$UA" \
    "https://fonts.googleapis.com/css2?family=${fam}:wght@400;700&display=swap" 2>/dev/null)
  n=0
  for u in $(printf '%s' "$css" | grep -o 'https://fonts.gstatic.com/[^)]*\.woff2'); do
    key=$(printf '%s' "$u" | md5sum | cut -c1-8)
    out="$DIR/${fam}_${key}.woff2"
    [ -s "$out" ] && { n=$((n+1)); continue; }
    curl -sL --max-time 30 -A "$UA" -o "$out" "$u" || { echo "FAIL $u"; continue; }
    n=$((n+1)); count=$((count+1))
  done
  echo "$fam: $n files"
done
echo "downloaded-total=$count"
echo DONE
