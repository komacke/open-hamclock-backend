#!/usr/bin/env bash
# ============================================================
#
#   ██████╗ ██╗  ██╗██████╗
#  ██╔═══██╗██║  ██║██╔══██╗
#  ██║   ██║███████║██████╔╝
#  ██║   ██║██╔══██║██╔══██╗
#  ╚██████╔╝██║  ██║██████╔╝
#   ╚═════╝ ╚═╝  ╚═╝╚═════╝
#
#  Open HamClock Backend
#  build_states.sh
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# ============================================================
# One-off OHB script: builds the states/provinces overlay file,
# same idea as build_borders.sh. Uses Natural Earth's 1:50m admin-1 dataset
# rather than 1:110m -- the 110m admin-1 theme is effectively US-only, the
# 50m one has real global coverage (states/provinces/oblasts/etc for most
# countries). This is only meant to be shown at HamClock's closest zoom
# level, so the extra detail/file size is the right tradeoff here.
#
set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

# States data is static (doesn't change), so this is safe to run from cron
# repeatedly -- it just quits immediately once the files already exist.
# Delete both files manually to force a regeneration (e.g. after updating
# to a newer Natural Earth release).
if [[ -s "$OUTDIR/states.bin" && -s "$OUTDIR/states.bin.z" ]]; then
    echo "states.bin(.z) already present in $OUTDIR -- nothing to do."
    exit 0
fi

SRC_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_1_states_provinces.geojson"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
need curl
need python3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading Natural Earth 1:50m admin-1 states/provinces..."
curl -fsSL "$SRC_URL" -o "$TMP/states.geojson"

BIN="$TMP/states.bin"
python3 - "$TMP/states.geojson" "$BIN" <<'PY'
import json, struct, sys

src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))

# Same binary format as borders.bin (see build_borders.sh): uint16 point
# count per ring, then that many (int16 lon_cd, int16 lat_cd) pairs at
# 0.01-degree precision. Exterior rings only.
#
# Unlike admin-0 countries (always MultiPolygon in this dataset), admin-1
# features can be plain Polygon too, so both geometry types are handled.
rings = []
for feat in d["features"]:
    geom = feat["geometry"]
    if geom["type"] == "MultiPolygon":
        polys = geom["coordinates"]
    elif geom["type"] == "Polygon":
        polys = [geom["coordinates"]]
    else:
        continue
    for poly in polys:
        exterior = poly[0]
        rings.append(exterior)

with open(out, "wb") as f:
    f.write(b"HCBD")                    # same magic/format as borders.bin
    f.write(struct.pack("<BH", 1, len(rings)))

    total_pts = 0
    for ring in rings:
        pts = []
        for lon, lat in ring:
            lon_cd = max(-18000, min(18000, int(round(lon * 100))))
            lat_cd = max(-9000, min(9000, int(round(lat * 100))))
            pts.append((lon_cd, lat_cd))
        f.write(struct.pack("<H", len(pts)))
        for lon_cd, lat_cd in pts:
            f.write(struct.pack("<hh", lon_cd, lat_cd))
        total_pts += len(pts)

print(f"encoded {len(rings)} rings, {total_pts} points -> {out}", file=sys.stderr)
PY

python3 - "$BIN" <<'PY'
import zlib, sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[1] + ".z", "wb").write(zlib.compress(data, 9))
PY

mv "$BIN" "$OUTDIR/states.bin"
mv "$BIN.z" "$OUTDIR/states.bin.z"
chmod 0644 "$OUTDIR/states.bin" "$OUTDIR/states.bin.z"

echo "OK: wrote $OUTDIR/states.bin ($(stat -c%s "$OUTDIR/states.bin" 2>/dev/null || wc -c <"$OUTDIR/states.bin") bytes), .z ($(stat -c%s "$OUTDIR/states.bin.z" 2>/dev/null || wc -c <"$OUTDIR/states.bin.z") bytes)"
