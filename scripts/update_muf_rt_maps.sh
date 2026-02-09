#!/usr/bin/env bash
set -euo pipefail

MAPDIR="${MAPDIR:-/opt/hamclock-backend/htdocs/ham/HamClock/maps}"
OUTDIR="${OUTDIR:-/opt/hamclock-backend/htdocs/ham/HamClock/maps}"

# Load unified size list
# shellcheck source=/dev/null
source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes

PY="${PY:-python3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${BUILDER:-$SCRIPT_DIR/build_muf_rt.py}"

for sz in "${SIZES[@]}"; do
  w="${sz%x*}"
  h="${sz#*x}"

  base_day="$MAPDIR/map-D-$sz-Countries.bmp.z"
  base_night="$MAPDIR/map-N-$sz-Countries.bmp.z"

  if [[ ! -s "$base_day" ]]; then
    echo "WARN: missing base day $base_day; skipping $sz" >&2
    continue
  fi
  if [[ ! -s "$base_night" ]]; then
    echo "WARN: missing base night $base_night; skipping $sz" >&2
    continue
  fi

  echo "Rendering MUF-RT $sz (D+N) ..."
  "$PY" "$BUILDER" \
    --width "$w" --height "$h" \
    --base-day "$base_day" \
    --base-night "$base_night" \
    --outdir "$OUTDIR" \
    --product "MUF-RT" \
    --alpha 0.55 \
    --active-seconds 3600 \
    --min-confidence 0.0 \
    --k 24 \
    --p 2.0 \
    --debug-png
done

