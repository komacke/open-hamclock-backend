#!/usr/bin/env bash
set -euo pipefail

# ---- configuration ----
OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/SDO"
OUTFILE="f_304_170.bmp"
URL="https://umbra.nascom.nasa.gov/images/latest_aia_304.gif"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---- sanity checks ----
for cmd in curl convert python3 install; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: missing required command: $cmd" >&2
        exit 1
    }
done

mkdir -p "$OUTDIR"

# ---- fetch latest AIA 304 Å browse image ----
curl -fsS "$URL" -o "$TMPDIR/latest_304.gif"

# ---- convert to exact HamClock BMP contract ----
convert "$TMPDIR/latest_304.gif" \
  -resize 170x170\! \
  -colorspace sRGB \
  -type TrueColor \
  -alpha off \
  BMP3:"$TMPDIR/$OUTFILE"

# ---- raw zlib compression (RFC1950, NOT gzip) ----
python3 -c '
import zlib, sys
inp, outp = sys.argv[1], sys.argv[2]
with open(inp,"rb") as f:
    data = f.read()
with open(outp,"wb") as f:
    f.write(zlib.compress(data, 9))
' "$TMPDIR/$OUTFILE" "$TMPDIR/$OUTFILE.z"

# ---- atomic install ----
install -m 0644 "$TMPDIR/$OUTFILE.z" "$OUTDIR/$OUTFILE.z"

