#!/bin/bash

THIS=$(basename "$0")

URL="https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"
OUT="/opt/hamclock-backend/htdocs/ham/HamClock/aurora/aurora.txt"
CACHE="/opt/hamclock-backend/cache"
LOG="/opt/hamclock-backend/logs/gen_aurora.log"

EXPECTED=48
CADENCE=1800
MAX_GAP=3600

mkdir -p "$CACHE"
mkdir -p "$(dirname "$LOG")"

MAX_VALUE=$(curl -fs "$URL" | jq '.coordinates | map(.[2]) | max')

if [ -z "$MAX_VALUE" ]; then
    echo "$(date -Is) ERROR: aurora fetch failed" >> "$LOG"
    exit 1
fi

# Quantize epoch to exact 30-minute bins
NOW=$(date +%s)
EPOCH_TIME=$(( NOW / CADENCE * CADENCE ))

reseed() {
    echo "$(date -Is) INFO: reseeding aurora history" >> "$LOG"
    TMP=$(mktemp "$CACHE/$THIS-XXXXX")

    for i in $(seq $((EXPECTED-1)) -1 0); do
        echo "$(( EPOCH_TIME - CADENCE * i )) $MAX_VALUE" >> "$TMP"
    done

    mv "$TMP" "$OUT"
}

if [ ! -f "$OUT" ]; then
    reseed
    exit 0
fi

LAST_EPOCH=$(tail -n 1 "$OUT" | awk '{print $1}')

if ! [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]]; then
    reseed
    exit 0
fi

DELTA=$(( EPOCH_TIME - LAST_EPOCH ))

# If gap too large or time went backwards — reseed
if [ "$DELTA" -le 0 ] || [ "$DELTA" -gt "$MAX_GAP" ]; then
    reseed
    exit 0
fi

# Normal append
echo "$EPOCH_TIME $MAX_VALUE" >> "$OUT"

# Enforce exact window
tail -n "$EXPECTED" "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
