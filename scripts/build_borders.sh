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
#  build_borders.sh
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
# One-off OHB script: builds the compact country-border overlay
# file HamClock downloads once and caches locally, the same way it caches
# Clouds/Terrain/Countries bitmaps. Run manually whenever the source
# boundary data should be refreshed -- it does not change often.
#
set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

# Border data is static (doesn't change), so this is safe to run from cron
# repeatedly -- it just quits immediately once the files already exist.
# Delete both files manually to force a regeneration (e.g. after updating
# to a newer Natural Earth release).
if [[ -s "$OUTDIR/borders.bin" && -s "$OUTDIR/borders.bin.z" ]]; then
    echo "borders.bin(.z) already present in $OUTDIR -- nothing to do."
    exit 0
fi

SRC_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
need curl
need python3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading Natural Earth 1:110m admin-0 countries..."
curl -fsSL "$SRC_URL" -o "$TMP/countries.geojson"

BIN="$TMP/borders.bin"
python3 - "$TMP/countries.geojson" "$BIN" <<'PY'
import json, struct, sys

src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))

# encode each ring as: uint16 point_count, then that many (int16 lon_cd, int16 lat_cd)
# pairs at 0.01-degree precision (~1.1km at the equator -- plenty for this display
# scale, and 8x smaller than storing float32 pairs). Exterior rings only; interior
# rings (lake holes etc) are dropped since they add no value for a simple border
# overlay at this resolution.
rings = []
for feat in d["features"]:
    geom = feat["geometry"]
    polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
    for poly in polys:
        exterior = poly[0]              # first ring of each polygon = exterior
        rings.append(exterior)

with open(out, "wb") as f:
    f.write(b"HCBD")                    # magic
    f.write(struct.pack("<BH", 1, len(rings)))   # version, ring count

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

mv "$BIN" "$OUTDIR/borders.bin"
mv "$BIN.z" "$OUTDIR/borders.bin.z"
chmod 0644 "$OUTDIR/borders.bin" "$OUTDIR/borders.bin.z"

echo "OK: wrote $OUTDIR/borders.bin ($(stat -c%s "$OUTDIR/borders.bin" 2>/dev/null || wc -c <"$OUTDIR/borders.bin") bytes), .z ($(stat -c%s "$OUTDIR/borders.bin.z" 2>/dev/null || wc -c <"$OUTDIR/borders.bin.z") bytes)"
