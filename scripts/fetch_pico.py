#!/usr/bin/env python3
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
#  fetch_pico.py
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
# fetch_pico.py -- OHB backend cron script for HamClock's "Balloons" pane,
# PicoBalloon half.
#
# Downloads Kevin Normoyle's (see the CSV's own header) daily-updated WSPR/APRS
# PicoBalloon roster:
#
#     https://raw.githubusercontent.com/knormoyle/knormoyle.github.io/main/mymaps.csv
#
# which is itself derived from wsprlive -- see that project's own notes on why
# this isn't something worth re-deriving locally (flights aren't announced;
# discovery is an inherently fuzzy multi-day heuristic process over the wsprlive
# firehose). We just consume its output.
#
# Unlike hab_daemon.py's SondeHub-Amateur source, this one already hands back one
# current row per flight on every fetch (mymaps.csv itself keeps a few days of
# hysteresis so a flight that's gone briefly quiet doesn't immediately vanish),
# so there's no live-feed/rolling-window concern here the way there is for HAB.
# This script still keeps a BalloonState cache regardless, for two reasons:
# (1) it's what accumulates the breadcrumb TRACK field across polls (mymaps.csv
# has no history column, just current position), and (2) if a poll fails
# outright, the previous cache is reused rather than writing an empty pico.txt.
#
# ============================================================

import argparse
import csv
import io
import logging
import os
import time
from datetime import datetime, timezone

from balloon_common import BalloonState, http_get, clean_field, atomic_write_lines

# ---- configuration -------------------------------------------------------
PICO_CSV_URL         = "https://raw.githubusercontent.com/knormoyle/knormoyle.github.io/main/mymaps.csv"
OUTDIR               = "/opt/hamclock-backend/htdocs/ham/HamClock/balloons"
DEFAULT_DROP_AGE_SEC = 4 * 86400   # mymaps.csv's own hysteresis is a couple days; give it margin
# --------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)


def parse_lastgood_to_unix(s):
    # observed format: "2026-08-15-01:34:00"  (UTC)
    try:
        dt = datetime.strptime(s.strip(), "%Y-%m-%d-%H:%M:%S").replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except (ValueError, AttributeError):
        return None


def na_or_float(s):
    if s is None:
        return None
    s = s.strip()
    if s == "" or s == "-":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def fetch_and_update(state):
    log.info(f"Fetching {PICO_CSV_URL}")
    raw = http_get(PICO_CSV_URL).decode("utf-8", errors="replace")
    reader = csv.DictReader(io.StringIO(raw))

    now = time.time()
    n_seen = 0
    for rec in reader:
        try:
            flight   = (rec.get("flight") or "").strip()
            callsign = (rec.get("callsign") or "").strip()
            lat = na_or_float(rec.get("lat"))
            lon = na_or_float(rec.get("lon"))
            if flight == "" or lat is None or lon is None:
                continue
            if lat == 0.0 and lon == 0.0:
                continue    # "null island" -- same defensive filter as hab_daemon.py

            last_t = parse_lastgood_to_unix(rec.get("LASTGOOD")) or int(now)

            alt = na_or_float(rec.get("altitude"))

            band     = (rec.get("c_band") or "").strip()
            channel  = (rec.get("channel") or "").strip()
            protocol = (rec.get("protocol") or "").strip()
            volt     = na_or_float(rec.get("voltage"))
            temp     = na_or_float(rec.get("temp"))
            freq_hz  = na_or_float(rec.get("c_frequency"))   # already Hz in mymaps.csv

            detail_bits = []
            if band:
                detail_bits.append(band)
            if channel:
                detail_bits.append(f"ch{channel}")
            if protocol:
                detail_bits.append(protocol)
            if volt is not None:
                detail_bits.append(f"{volt:.2f}V")
            if temp is not None:
                detail_bits.append(f"{temp:.0f}C")
            detail = clean_field(" ".join(detail_bits))

            url = (rec.get("url") or "").strip() or f"https://wsprtv.com/?show_unattached&cs={callsign}"

            fields = {
                "name": flight,
                "callsign": callsign,
                "alt_m": alt,
                "speed_mps": None,     # mymaps.csv carries no derived ground speed
                "hdg_deg": None,       # ...nor heading
                "detail": detail,
                "url": url,
                "freq_hz": freq_hz,
                "batt_v": volt,
                "temp_c": temp,
            }

            key = f"PICO:{flight}"
            state.update(key, fields, last_t, lat, lon)
            n_seen += 1
        except Exception as e:
            log.warning(f"Skipping row {rec.get('flight')}: {e}")
            continue

    log.info(f"{n_seen} flights in this fetch")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--outdir", default=OUTDIR,
                     help="directory to write pico.txt and the state cache into")
    ap.add_argument("--drop-age", type=int, default=DEFAULT_DROP_AGE_SEC,
                     help="drop a cached flight if its last report is older than this, seconds")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    state = BalloonState(os.path.join(args.outdir, "pico_state.json"), args.drop_age)

    try:
        fetch_and_update(state)
    except Exception as e:
        log.warning(f"Fetch failed ({e}), writing out previously cached flights unchanged")

    state.prune()
    state.save()

    rows = state.all_rows("PICO")
    outpath = os.path.join(args.outdir, "pico.txt")
    atomic_write_lines(outpath, rows)
    log.info(f"Wrote {len(rows)} flights -> {outpath}")


if __name__ == "__main__":
    main()
