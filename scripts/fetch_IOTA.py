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
#  fetch_IOTA.py
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
"""
fetch_IOTA.py -- build a compact IOTA group reference/name cache for HamClock.

IOTA group definitions change extremely rarely (new groups are added by
RSGB IOTA committee approval, not day to day), so once a day is already
generous -- this is nothing like the minute-by-minute spot feeds.

No API key is required for the iota-world.org downloads.

SCHEMA CAVEAT
-------------
REF_KEYS / NAME_KEYS below are confirmed against a real groups.json record
(captured 2026-08-08): {'refno': 'AF-001', 'name': 'Agalega Islands',
'dxcc_num': '4', 'latitude_max': ..., 'grp_region': ..., 'whitelist': ...,
'pc_credited': ..., 'comment': ...}. Only refno/name are used here; the rest
(dxcc_num, lat/lon bounds, pc_credited) are left for a future enhancement
(eg resolving DXCC country, or a "requires X% credit" hint) rather than
bloating this first cache.
"""

import sys
import os
import json
import time
import urllib.request

GROUPS_URL = ("https://www.iota-world.org/islands-on-the-air/downloads/"
              "download-file.html?path=groups.json")

# candidate JSON key names to try, in order, for each field -- tolerant of
# the source schema using a different name than we guessed.
# confirmed against a live groups.json record on 2026-08-08:
#   {'refno': 'AF-001', 'name': 'Agalega Islands', 'dxcc_num': '4', ...}
REF_KEYS = ("refno", "reference", "iotaRef", "iota_ref", "ref", "code")
NAME_KEYS = ("name", "groupName", "group_name", "title")

MAX_NAME_LEN = 40          # keep cache lines short for embedded (ESP32) clients
TIMEOUT_S = 30
USER_AGENT = "HamClock-fetchIOTA/1.0 (+https://ohb.works/)"


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        return json.load(resp)


def first_present(d, keys):
    for k in keys:
        if k in d and d[k] not in (None, ""):
            return d[k]
    return None


def clean_name(name):
    name = str(name or "").replace(",", ";").strip()
    if len(name) > MAX_NAME_LEN:
        name = name[:MAX_NAME_LEN - 1] + "\u2026"
    return name


def normalize_ref(ref):
    return str(ref or "").strip().upper()


def extract_records(raw):
    """groups.json may be a bare list, or an object with the list under some
    top-level key (e.g. {"groups": [...]}) -- handle both."""
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        for v in raw.values():
            if isinstance(v, list):
                return v
    return []


def build_lines(records):
    lines = []
    misses = 0
    sample_logged = False
    for rec in records:
        if not isinstance(rec, dict):
            continue
        ref = normalize_ref(first_present(rec, REF_KEYS))
        name = first_present(rec, NAME_KEYS)
        if not ref or name is None:
            misses += 1
            if not sample_logged:
                print(f"fetchIOTA: schema miss, sample record: {rec}", file=sys.stderr)
                sample_logged = True
            continue
        lines.append(f"{ref},{clean_name(name)}")

    if misses:
        print(f"fetchIOTA: {misses} record(s) skipped (unmatched schema keys) "
              f"-- see REF_KEYS/NAME_KEYS in this script", file=sys.stderr)

    lines.sort()
    return lines


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} outfile", file=sys.stderr)
        return 1
    outfile = sys.argv[1]

    if os.path.isdir (outfile) or outfile.endswith ("/"):
        print(f"fetchIOTA: outfile must be a file path, not a directory: {outfile!r}\n"
              f"           did you mean {os.path.join(outfile, 'iota.txt')!r} ?", file=sys.stderr)
        return 1

    try:
        raw = fetch_json(GROUPS_URL)
    except Exception as e:
        # a failed download is not fatal to HamClock: openCachedFile() just
        # keeps serving the previous file until it goes stale. so we log and
        # bail without touching outfile, rather than write something empty.
        print(f"fetchIOTA: download failed: {e}", file=sys.stderr)
        return 1

    records = extract_records(raw)
    lines = build_lines(records)
    if not lines:
        print("fetchIOTA: no groups parsed, refusing to overwrite cache", file=sys.stderr)
        return 1

    tmp = outfile + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"# IOTA group reference cache -- generated "
                 f"{time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())} UTC\n")
        f.write(f"# source: {GROUPS_URL}\n")
        for line in lines:
            f.write(line + "\n")
    os.replace(tmp, outfile)   # atomic swap: client never sees a half-written file

    print(f"fetchIOTA: wrote {len(lines)} groups to {outfile}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
