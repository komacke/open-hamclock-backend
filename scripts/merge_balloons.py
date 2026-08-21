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
#  merge_balloons.py
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
# merge_balloons.py -- OHB backend cron script for HamClock's "Balloons" pane:
# combines hab.txt (written continuously by hab_daemon.py) and pico.txt (written
# every 15 min by fetch_pico.py) into balloons.txt, the single file balloons.cpp
# actually fetches via openCachedFile() at /ham/HamClock/balloons/balloons.txt.
#
# Deliberately trivial: adds the shared credit line, concatenates whatever rows
# are currently in each partial file, writes atomically. All the real logic
# (fetching, per-flight caching, staleness, breadcrumb tracks) lives in
# hab_daemon.py/fetch_pico.py and their own state files -- this script doesn't
# talk to either upstream API and doesn't need to know anything about SondeHub
# or wsprlive.
#
# If one partial file is missing entirely (eg hab_daemon.py hasn't written its
# first flush yet), this just merges in zero rows for that source rather than
# failing -- the pane will simply show only what it has. A quick freshness check
# is printed to stderr (not enforced) so a stalled fetcher is easy to notice in
# the logs without merge itself needing an opinion about how stale is "too stale".
#
# OUTPUT FILE:
#   <OUTDIR>/balloons.txt (served at /ham/HamClock/balloons/balloons.txt)
#
# CRON (every 5 minutes -- more often than either source updates, so it always
# has something to merge; reading a partial file mid-write is not a concern
# since both hab_daemon.py and fetch_pico.py write atomically):
#   */5 * * * * $SCRIPTS/cron-wrapper.sh $VENV/bin/python3 $SCRIPTS/merge_balloons.py
# ============================================================

import argparse
import os
import time

from balloon_common import log, atomic_write_lines

CREDIT_LINE = "Credit: SondeHub + wsprlive"

OUTDIR = "/opt/hamclock-backend/htdocs/ham/HamClock/balloons"   # adjust to your OHB webroot

STALE_WARN_SEC = 30 * 60   # just a log hint, not enforced


def read_rows(path):
    try:
        with open(path, "r") as f:
            rows = [line.rstrip("\n") for line in f if line.strip()]
        age = time.time() - os.path.getmtime(path)
        if age > STALE_WARN_SEC:
            log("MERGE", f"warning: {path} is {age/60:.0f} min old -- its fetcher may not be running")
        return rows
    except FileNotFoundError:
        log("MERGE", f"{path} not found yet -- treating as zero flights from that source")
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=OUTDIR,
                     help="directory containing hab.txt/pico.txt, and where balloons.txt is written")
    args = ap.parse_args()

    hab_rows = read_rows(os.path.join(args.dir, "hab.txt"))
    pico_rows = read_rows(os.path.join(args.dir, "pico.txt"))

    lines = [CREDIT_LINE] + hab_rows + pico_rows
    outpath = os.path.join(args.dir, "balloons.txt")
    atomic_write_lines(outpath, lines)
    log("MERGE", f"wrote {len(hab_rows)} HAB + {len(pico_rows)} PICO -> {outpath}")


if __name__ == "__main__":
    main()
