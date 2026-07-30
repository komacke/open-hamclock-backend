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
# same idea as build_borders.sh. Uses Natural Earth's 1:10m admin-1 dataset --
# public domain, no attribution required, same as borders.bin. Bumped up
# from the earlier 1:50m theme for finer coastline/border precision; the
# admin-1 unit definitions themselves (which regions count as a "state")
# are the same at either scale, this just changes how smoothly they're
# traced. A few small nations/microstates (Monaco, Andorra, Liechtenstein,
# San Marino, etc) aren't covered at admin-1 in this dataset -- acceptable
# tradeoff for staying public domain instead of switching to a dataset
# that requires attribution.
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

SRC_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_1_states_provinces.geojson"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
need curl
need python3

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading Natural Earth 1:10m admin-1 states/provinces..."
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

    # uint16 point count per ring -- the 1:10m theme's finer tracing means a
    # handful of very complex coastlines/borders can still exceed this after
    # quantizing to 0.01 degree, so dedupe consecutive duplicate points and,
    # failing that, uniformly downsample rather than overflow the format.
    MAX_PTS = 65535
    total_pts = 0
    n_downsampled = 0
    n_degenerate = 0
    out_rings = []
    for ring in rings:
        pts = []
        for lon, lat in ring:
            lon_cd = max(-18000, min(18000, int(round(lon * 100))))
            lat_cd = max(-9000, min(9000, int(round(lat * 100))))
            if not pts or pts[-1] != (lon_cd, lat_cd):
                pts.append((lon_cd, lat_cd))

        if len(pts) > MAX_PTS:
            step = (len(pts) + MAX_PTS - 1) // MAX_PTS
            pts = pts[::step]
            n_downsampled += 1

        if len(pts) < 3:
            n_degenerate += 1
            continue

        out_rings.append(pts)
        total_pts += len(pts)

    f.write(struct.pack("<BH", 1, len(out_rings)))
    for pts in out_rings:
        f.write(struct.pack("<H", len(pts)))
        for lon_cd, lat_cd in pts:
            f.write(struct.pack("<hh", lon_cd, lat_cd))

print(f"encoded {len(out_rings)} rings, {total_pts} points -> {out}", file=sys.stderr)
if n_downsampled:
    print(f"note: {n_downsampled} ring(s) exceeded {MAX_PTS} points and were downsampled", file=sys.stderr)
if n_degenerate:
    print(f"note: {n_degenerate} degenerate ring(s) (<3 points after dedup) were dropped", file=sys.stderr)
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
