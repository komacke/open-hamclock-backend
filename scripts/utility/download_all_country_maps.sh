#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://clearskyinstitute.com/ham/HamClock/maps"
OUTDIR="${OUTDIR:-./maps}"
TYPES=("D" "N")

DEFAULT_SIZES=( \
  "660x330" \
  "1320x660" \
  "1980x990" \
  "2640x1320" \
  "3960x1980" \
  "5280x2640" \
  "5940x2970" \
  "7920x3960" \
)

# Controls
DECOMPRESS="${DECOMPRESS:-1}"     # 1 = try to produce .bmp as well, 0 = only download .z
FORCE="${FORCE:-0}"               # 1 = redownload even if file exists
CURL_OPTS=(
  --fail --show-error --location
  --connect-timeout 15
  --retry 3 --retry-delay 2 --retry-all-errors
)

mkdir -p "$OUTDIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

decompress_zlib() {
  local zfile="$1"
  local bmpfile="${zfile%.z}"

  if [[ "$FORCE" != "1" && -s "$bmpfile" ]]; then
    echo "OK (exists): $(basename "$bmpfile")"
    return 0
  fi

  if have_cmd zlib-flate; then
    zlib-flate -uncompress < "$zfile" > "$bmpfile"
    echo "OK (zlib-flate): $(basename "$bmpfile")"
    return 0
  fi

  if have_cmd python3; then
    python3 - "$zfile" "$bmpfile" <<'PY'
import sys, zlib
zfile, bmpfile = sys.argv[1], sys.argv[2]
with open(zfile, "rb") as f:
    comp = f.read()
raw = zlib.decompress(comp)
with open(bmpfile, "wb") as f:
    f.write(raw)
PY
    echo "OK (python3): $(basename "$bmpfile")"
    return 0
  fi

  echo "WARN: no zlib-flate or python3 available; leaving only .z for $(basename "$zfile")" >&2
  return 0
}

download_one() {
  local type="$1"
  local size="$2"
  local fname="map-${type}-${size}-Countries.bmp.z"
  local url="${BASE_URL}/${fname}"
  local out="${OUTDIR}/${fname}"

  if [[ "$FORCE" != "1" && -s "$out" ]]; then
    echo "SKIP (exists): $fname"
  else
    echo "GET: $url"
    curl "${CURL_OPTS[@]}" -o "$out" "$url"
    echo "OK: $fname"
  fi

  if [[ "$DECOMPRESS" == "1" ]]; then
    decompress_zlib "$out"
  fi
}

for t in "${TYPES[@]}"; do
  for s in "${DEFAULT_SIZES[@]}"; do
    download_one "$t" "$s"
  done
done

echo "Done. Output directory: $OUTDIR"
