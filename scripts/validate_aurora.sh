#!/bin/bash

FILE="/opt/hamclock-backend/htdocs/ham/HamClock/aurora/aurora.txt"
EXPECTED=48
CADENCE=1800
TOL=5

if [ ! -f "$FILE" ]; then
    echo "ERROR: aurora.txt missing"
    exit 1
fi

mapfile -t lines < "$FILE"

count=${#lines[@]}

echo "Samples: $count"

if [ "$count" -ne "$EXPECTED" ]; then
    echo "WARNING: expected $EXPECTED rows"
fi

prev=""
idx=0

for line in "${lines[@]}"; do
    epoch=$(echo "$line" | awk '{print $1}')

    if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
        echo "BAD ROW $idx: $line"
        exit 1
    fi

    if [ -n "$prev" ]; then
        delta=$(( epoch - prev ))

        if [ "$delta" -le 0 ]; then
            echo "ERROR: non-monotonic at row $idx"
        fi

        diff=$(( delta - CADENCE ))
        abs=${diff#-}

        if [ "$abs" -gt "$TOL" ]; then
            echo "GAP row $idx: $delta seconds"
        fi
    fi

    prev=$epoch
    ((idx++))
done

first=$(awk 'NR==1{print $1}' "$FILE")
last=$(awk 'END{print $1}' "$FILE")
span=$(( last - first ))

echo "Span seconds: $span"
echo "Span hours: $(awk "BEGIN{printf \"%.2f\",$span/3600}")"

echo "Done."
