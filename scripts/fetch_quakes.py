#!/usr/bin/env python3
"""fetch_quakes.py -- OHB backend feeder for HamClock's Quakes overlay.

Polls USGS's public earthquake GeoJSON summary feed and writes:
  1. a small flat summary file at the path given on the command line (served as
     /quakes/quakes.txt), which quakes.cpp fetches and parses every ~5 min.
  2. one plain-text file per event in a "detail/" directory alongside it (served as
     /quakes/detail/<sanitized-id>.txt). The client only fetches an individual detail file on
     demand, when the user taps that specific event -- the client has no TLS stack, so it
     can never reach earthquake.usgs.gov directly; this just carries the full text through
     the same backend-proxy pipe the one-line summary already comes through.

Feed used: the "2.5_day" summary (all M2.5+ earthquakes in the past 24 hours). That's a
reasonable balance -- wide enough to catch anything a ham station might care about, not so
wide (like "all_day", which includes M1.0 microquakes) that the list is dominated by noise.
Swap FEED_URL below for a different USGS feed if you want a different magnitude/time window;
see https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php for the full list.

Output format for quakes.txt -- one line per event, comma-separated, 7 fields:
    ID,TIME,MAG,DEPTH_KM,LAT,LON,PLACE
where TIME is unix epoch seconds (USGS gives milliseconds; this script converts) and PLACE is
USGS's own human-readable location string (e.g. "10km SW of Anza, CA"), comma-sanitized.

IMPORTANT -- every file written here must end in a newline. HamClock's client-side
getTCPLine() only returns a line when it sees a trailing '\\n'; on EOF without one it silently
discards whatever was already read and the client gets nothing back at all. (This bit the
marine warnings detail files during development -- don't repeat it here.)

Usage:
    fetch_quakes.py
(writes to /opt/hamclock-backend/htdocs/ham/HamClock/quakes/quakes.txt -- see HAMCLOCK_BASE
below to change the base path)
"""

import sys
import os
import json
import time
import urllib.request
import tempfile

FEED_URL = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson"
USER_AGENT = "HamClock-OHB/1.0 (fetch_quakes.py)"
TIMEOUT_S = 15


def sanitize(text, maxlen):
    """flatten to one line, strip commas (field separator) and newlines, clip to maxlen-1"""
    if not text:
        return ""
    flat = " ".join(text.split())
    flat = flat.replace(",", ";")
    return flat[:maxlen - 1]


def sanitize_id_for_path(event_id):
    """MUST exactly match quakeSanitizeIdForPath() in quakes.cpp: isalnum, '.', '_', '-'
    pass through, everything else becomes '_'.
    """
    return "".join(c if (c.isalnum() or c in "._-") else "_" for c in event_id)[:23]


def build_detail_text(props, mag, depth_km, maxlen=380):
    """title + tsunami flag + felt reports + status, flattened for the client's scrollable
    detail view. maxlen leaves headroom under the client's QUAKE_DETAIL_MAXLEN (400) buffer.
    """
    parts = []
    title = props.get("title")
    if title:
        parts.append(" ".join(title.split()))
    else:
        parts.append(f"M{mag:.1f} earthquake, {depth_km:.0f}km deep")

    if props.get("tsunami"):
        parts.append("A tsunami warning/advisory may be associated with this event.")

    felt = props.get("felt")
    if felt:
        parts.append(f"Reported felt by {felt} people.")

    status = props.get("status")
    if status:
        parts.append(f"Status: {status}.")

    net = props.get("net")
    if net:
        parts.append(f"Source network: {net}.")

    text = "  ".join(parts)
    return text[:maxlen]


def fetch_events():
    req = urllib.request.Request(FEED_URL, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/geo+json",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        return json.load(resp)


def build_lines(geojson):
    lines = []
    details = {}      # sanitized_id -> detail text
    for feature in geojson.get("features", []):
        props = feature.get("properties", {}) or {}
        geometry = feature.get("geometry")
        raw_id = feature.get("id", "")

        event_id = sanitize(raw_id, 24)
        if not event_id:
            continue

        mag = props.get("mag")
        if mag is None:
            continue                       # unreviewed/incomplete event, skip rather than guess
        time_ms = props.get("time")
        if time_ms is None:
            continue
        time_s = int(time_ms / 1000)

        coords = (geometry or {}).get("coordinates") or [None, None, None]
        lon, lat, depth_km = (coords + [None, None, None])[:3]
        if lon is None or lat is None:
            continue
        depth_km = depth_km if depth_km is not None else 0.0

        place = sanitize(props.get("place") or "", 80)

        line = f"{event_id},{time_s},{mag:.1f},{depth_km:.1f},{lat:.4f},{lon:.4f},{place}"
        lines.append(line)

        details[sanitize_id_for_path(event_id)] = build_detail_text(props, mag, depth_km)

    return lines, details


HAMCLOCK_BASE = "/opt/hamclock-backend/htdocs/ham/HamClock"
TMP_DIR = "/opt/hamclock-backend/htdocs/tmp"
OUT_PATH = os.path.join(HAMCLOCK_BASE, "quakes", "quakes.txt")


def atomic_write(target_path, content):
    """Write content to a temporary file in TMP_DIR and atomically replace target_path."""
    os.makedirs(TMP_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(target_path), exist_ok=True)
    prefix = f".{os.path.basename(target_path)}."
    fd, tmp_path = tempfile.mkstemp(dir=TMP_DIR, prefix=prefix, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, target_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def main():
    out_path = OUT_PATH
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    try:
        geojson = fetch_events()
        lines, details = build_lines(geojson)
    except Exception as e:
        sys.stderr.write(f"fetch_quakes: fetch/parse failed: {e}\n")
        sys.exit(1)

    summary_content = "# generated by fetch_quakes.py -- do not edit\n"
    for line in lines:
        summary_content += line + "\n"
    atomic_write(out_path, summary_content)

    detail_dir = os.path.join(os.path.dirname(out_path) or ".", "detail")
    os.makedirs(detail_dir, exist_ok=True)

    for safe_id, text in details.items():
        det_path = os.path.join(detail_dir, f"{safe_id}.txt")
        atomic_write(det_path, text + "\n")             # trailing newline is required, see module docstring

    current = {f"{safe_id}.txt" for safe_id in details}
    for fn in os.listdir(detail_dir):
        if fn.endswith(".txt") and fn not in current:
            try:
                os.remove(os.path.join(detail_dir, fn))
            except OSError:
                pass

    print(f"fetch_quakes: wrote {len(lines)} events and {len(details)} detail files to {out_path}")


if __name__ == "__main__":
    main()
