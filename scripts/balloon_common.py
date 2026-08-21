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
#  balloon_common.py
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
# balloon_common.py -- shared helpers for hab_daemon.py and fetch_pico.py (the
# "Balloons" pane backend). Not run directly by cron or docker/run.sh; imported
# by those two, which live alongside it in this same scripts/ directory.
#
# Most OHB scripts are deliberately standalone (see eg fetch_launches.py). This
# one is shared because hab_daemon.py and fetch_pico.py both need the same
# per-flight state/breadcrumb-track cache (BalloonState below), and duplicating
# that logic risked the two copies quietly drifting apart -- a correctness
# concern, not just a style preference.
#
# Row format written by fetch_pico.py (pico.txt) and hab_daemon.py (hab.txt and,
# with the credit line prepended, the final balloons.txt HamClock fetches --
# hab_daemon.py reads pico.txt and combines both directly on every flush, no
# separate merge script involved):
#
#   TYPE,NAME,CALLSIGN,LASTHEARD,LAT,LON,ALT_M,SPEED_MPS,HDG_DEG,DETAIL,URL,TRACK,
#   FREQ_HZ,BATT_V,TEMP_C
#
# See balloons.cpp (HamClock client) for the full field-by-field description --
# this module just builds/serializes that same row, generically, from a dict of
# whatever fields a given source happens to have.
# ============================================================

import json
import os
import sys
import tempfile
import time
import urllib.request

HTTP_TIMEOUT_SEC = 20
USER_AGENT = "OpenHamClockBackend-balloons/1.0 (+https://github.com/openhamclock/open-hamclock-backend)"

# breadcrumb-track tuning -- shared by both sources, matches balloons.cpp's BALN_MAX_TRACK
TRACK_MAX_POINTS   = 8
TRACK_MAX_AGE_SEC  = 2 * 86400     # drop breadcrumbs older than this
TRACK_MIN_MOVE_DEG = 0.01          # skip near-duplicate samples (parked/no-fix noise)


def log(tag, msg):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {tag}: {msg}", file=sys.stderr, flush=True)


def http_get(url, timeout=HTTP_TIMEOUT_SEC):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def clean_field(s):
    """Row output here is unquoted CSV, so scrub commas/newlines out of free text."""
    if s is None:
        return ""
    return str(s).replace(",", ";").replace("\n", " ").replace("\r", " ").strip()


def fmt_num(x, ndigits=None):
    """Format a number for the wire, or the literal "NA" if x is None/unparseable."""
    if x is None:
        return "NA"
    try:
        x = float(x)
    except (TypeError, ValueError):
        return "NA"
    return f"{x:.{ndigits}f}" if ndigits is not None else repr(x)


def atomic_write_lines(path, lines):
    """Write lines (no trailing newlines needed) to path, atomically (temp + rename)."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".balloons.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            for line in lines:
                f.write(line + "\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class BalloonState:
    """Persistent per-flight cache: latest known fields + a breadcrumb track, keyed by
    a source-specific string (eg "HAB:N0CALL-11" or "PICO:AC3AU-17M-111").

    Exists because SondeHub asked that HAB not be re-queried for a wide time window on
    every poll (direct correspondence, Aug 2026 -- see hab_daemon.py's module
    docstring). So instead of a wide query: hab_daemon.py keeps a live websocket
    connection (or, if it were cron-polled, a narrow rolling window) and updates this
    cache as data arrives, then always emits every still-fresh cached entry -- not
    just whatever showed up most recently -- so a flight doesn't flicker out of the
    pane between updates.
    """

    def __init__(self, path, drop_age_sec):
        self.path = path
        self.drop_age_sec = drop_age_sec
        try:
            with open(path, "r") as f:
                self.data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self.data = {}

    def is_empty(self):
        return len(self.data) == 0

    def update(self, key, fields, ts, lat, lon):
        """fields is a dict of whatever this source knows: name, callsign, alt_m,
        speed_mps, hdg_deg, detail, url, freq_hz, batt_v, temp_c -- any subset; missing
        keys just mean that field stays absent (renders as NA/? downstream).
        """
        entry = self.data.setdefault(key, {"track": []})
        entry.update(fields)
        entry["last_t"] = ts
        entry["lat"] = lat
        entry["lon"] = lon

        track = entry.setdefault("track", [])
        if not track or (ts > track[-1][0] and (abs(lat - track[-1][1]) >= TRACK_MIN_MOVE_DEG
                                                  or abs(lon - track[-1][2]) >= TRACK_MIN_MOVE_DEG)):
            track.append([ts, lat, lon])
        cutoff = time.time() - TRACK_MAX_AGE_SEC
        track[:] = [p for p in track if p[0] >= cutoff][-TRACK_MAX_POINTS:]

    def prune(self):
        """drop entries whose last update is older than drop_age_sec."""
        cutoff = time.time() - self.drop_age_sec
        for key in list(self.data.keys()):
            if self.data[key].get("last_t", 0) < cutoff:
                del self.data[key]

    def track_field(self, key):
        """older breadcrumb points only (current position is a separate CSV column),
        oldest-first -- see balloons.cpp's TRACK field docs."""
        entry = self.data.get(key)
        if not entry:
            return ""
        pts = entry.get("track", [])
        older = pts[:-1] if pts else []
        return "|".join(f"{lat:.5f}:{lon:.5f}" for _, lat, lon in older)

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f)
        os.replace(tmp, self.path)

    def all_rows(self, type_tag):
        """build one balloons.txt-format CSV row per cached entry."""
        rows = []
        for key, e in self.data.items():
            row = ",".join([
                type_tag,
                clean_field(e.get("name", "")),
                clean_field(e.get("callsign", "")),
                str(int(e["last_t"])),
                f"{e['lat']:.5f}",
                f"{e['lon']:.5f}",
                fmt_num(e.get("alt_m"), 0),
                fmt_num(e.get("speed_mps"), 1),
                fmt_num(e.get("hdg_deg"), 0),
                clean_field(e.get("detail", "")),
                clean_field(e.get("url", "")),
                self.track_field(key),
                fmt_num(e.get("freq_hz"), 0),
                fmt_num(e.get("batt_v"), 2),
                fmt_num(e.get("temp_c"), 0),
            ])
            rows.append(row)
        return rows
