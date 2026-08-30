#!/usr/bin/env python3
"""fetch_firewx_warnings.py -- OHB backend feeder for HamClock's Fire Wx overlay.

Polls api.weather.gov for active US NWS fire weather products (Red Flag Warning, Fire
Weather Watch) and writes:
  1. a small flat summary file at the path given on the command line (served as
     /firewx/warnings.txt), which firewx.cpp fetches and parses every ~5 min.
  2. one plain-text file per active warning in a "detail/" directory alongside it (served as
     /firewx/detail/<sanitized-id>.txt), containing the full NWS description/instruction text.
     The client only fetches an individual detail file on demand, when the user taps that
     specific warning -- the client has no TLS stack, so it can never reach api.weather.gov
     directly; this just carries the *full* text through the same backend-proxy pipe the
     one-line summary already comes through.

NOTE on geolocation: unlike Special Marine Warning (county-based, includes a polygon
directly), Red Flag Warning / Fire Weather Watch are ZONE-based products -- the alert itself
carries "geometry": null and instead references its fire weather zone by URL in
properties.affectedZones. This script fetches that zone's own geometry as a fallback. Do not
remove this fallback and revert to "skip if alert has no polygon" (that was tried first and
silently dropped every real alert -- there is essentially never a Red Flag Warning with
polygon geometry directly on the alert).

Output format for warnings.txt -- one line per warning, comma-separated, 9 fields, last optional:
    ID,OFFICE,ISSUED,EXPIRES,CENTER_LAT,CENTER_LON,HEADLINE,AREA,VERTS
where AREA is the CAP alert's areaDesc (human-readable affected zone, e.g. "Coastal Plains of
southeast GA and northeast FL") and VERTS (if present) is "lat1:lon1;lat2:lon2;...;latN:lonN".
VERTS is always the last field so it may itself contain further commas -- it doesn't, by
construction below, but the client parser is written to tolerate that regardless.

Usage:
    fetch_firewx_warnings.py
(writes to /opt/hamclock-backend/htdocs/ham/HamClock/firewx/warnings.txt -- see HAMCLOCK_BASE
below to change the base path)
"""

import sys
import os
import json
import time
import urllib.request
import tempfile

NWS_URL = ("https://api.weather.gov/alerts/active"
           "?event=Red%20Flag%20Warning,Fire%20Weather%20Watch")
USER_AGENT = "HamClock-OHB/1.0 (fetch_firewx_warnings.py)"
TIMEOUT_S = 15


def sanitize(text, maxlen):
    """flatten to one line, strip commas (field separator) and newlines, clip to maxlen-1"""
    if not text:
        return ""
    flat = " ".join(text.split())
    flat = flat.replace(",", ";")
    return flat[:maxlen - 1]


def iso_to_epoch(iso_str):
    if not iso_str:
        return 0
    try:
        # NWS timestamps are like "2026-08-28T07:21:00-05:00" -- fromisoformat parses the
        # offset directly, so this is correct regardless of what timezone this script runs in.
        # (datetime.fromisoformat handles colon-separated offsets on Python 3.7+.)
        from datetime import datetime
        dt = datetime.fromisoformat(iso_str)
        return int(dt.timestamp())
    except Exception:
        return 0


def polygon_centroid(coords):
    """coords: list of [lon, lat] pairs (GeoJSON order). returns (lat, lon) simple centroid."""
    if not coords:
        return None
    n = len(coords)
    lat_sum = sum(c[1] for c in coords)
    lon_sum = sum(c[0] for c in coords)
    return (lat_sum / n, lon_sum / n)


def extract_polygon(geometry):
    """returns list of (lat, lon) vertices, or [] if no usable polygon geometry."""
    if not geometry or geometry.get("type") != "Polygon":
        return []
    rings = geometry.get("coordinates") or []
    if not rings:
        return []
    outer = rings[0]                 # ignore holes, if any -- irrelevant at this scale
    verts = [(c[1], c[0]) for c in outer]   # GeoJSON is [lon,lat] -> flip to (lat,lon)
    # drop a closing vertex that just repeats the first (client polygon doesn't need it)
    if len(verts) > 1 and verts[0] == verts[-1]:
        verts = verts[:-1]
    return verts[:20]                # cap matches MARINE_MAXVERTS in firewx.cpp


def sanitize_id_for_path(alert_id):
    """MUST exactly match sanitizeIdForPath() in firewx.cpp: isalnum, '.', '_', '-'
    pass through, everything else becomes '_'. CAP alert ids look like
    "urn:oid:2.49.0.1.840.0.936f066bc47a75db" and need to become a safe filename component.
    """
    return "".join(c if (c.isalnum() or c in "._-") else "_" for c in alert_id)[:39]


def build_detail_text(props, maxlen=650):
    """headline + description + instruction, flattened for the client's scrollable detail
    view. maxlen leaves headroom under the client's MARINE_DETAIL_MAXLEN (700) buffer.
    """
    parts = []
    headline = props.get("headline") or props.get("event")
    if headline:
        parts.append(" ".join(headline.split()))
    description = props.get("description")
    if description:
        parts.append(" ".join(description.split()))
    instruction = props.get("instruction")
    if instruction:
        parts.append(" ".join(instruction.split()))
    text = "  ".join(parts) if parts else "No further details available."
    if len(text) <= maxlen:
        return text
    # trim to the last whole word that fits, rather than slicing mid-word
    cut = text[:maxlen]
    last_space = cut.rfind(" ")
    if last_space > 0:
        cut = cut[:last_space]
    return cut + "..."


def fetch_zone_geometry(zone_url):
    """fire weather (and other zone-based) alerts carry geometry:null and instead reference
    their zone by URL in properties.affectedZones -- fetch that zone's own GeoJSON Feature to
    get its polygon. One extra request per active alert; bounded and infrequent enough (this
    only runs every 5 min, for whatever's currently active) to not be a real cost.
    """
    req = urllib.request.Request(zone_url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/geo+json",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        return json.load(resp)


def fetch_alerts():
    req = urllib.request.Request(NWS_URL, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/geo+json",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        return json.load(resp)


def build_lines(geojson):
    lines = []
    details = {}      # sanitized_id -> detail text, for the caller to write out
    for feature in geojson.get("features", []):
        props = feature.get("properties", {}) or {}
        geometry = feature.get("geometry")

        raw_id = props.get("id", "")
        alert_id = sanitize(raw_id, 40)
        if not alert_id:
            continue

        office = sanitize((props.get("senderName") or props.get("office") or "")[:8], 8)
        issued = iso_to_epoch(props.get("onset") or props.get("sent"))
        expires = iso_to_epoch(props.get("expires") or props.get("ends"))
        headline = sanitize(props.get("headline") or props.get("event") or "", 80)
        area = sanitize(props.get("areaDesc") or "", 90)

        verts = extract_polygon(geometry)
        if not verts:
            # zone-based products (Red Flag Warning, Fire Weather Watch) normally arrive with
            # geometry:null and reference their zone by URL instead -- fetch that zone's own
            # polygon rather than skipping the alert entirely
            for zone_url in (props.get("affectedZones") or [])[:1]:
                try:
                    zone_feature = fetch_zone_geometry(zone_url)
                    verts = extract_polygon(zone_feature.get("geometry"))
                except Exception as e:
                    sys.stderr.write(f"fetch_firewx_warnings: zone lookup failed for "
                                      f"{zone_url}: {e}\n")
                break

        if verts:
            center_lat, center_lon = polygon_centroid([[v[1], v[0]] for v in verts])
            verts_field = ";".join(f"{lat:.4f}:{lon:.4f}" for lat, lon in verts)
        else:
            # genuinely no geometry available (alert geometry AND zone lookup both empty) --
            # skip rather than guess
            continue

        line = f"{alert_id},{office},{issued},{expires},{center_lat:.4f},{center_lon:.4f}," \
               f"{headline},{area},{verts_field}"
        lines.append(line)

        # key off alert_id (the CSV-safe string that actually ends up in w.id on the client),
        # not raw_id -- the client only ever sees what's in the ID column of warnings.txt, so
        # sanitizing anything else here would produce a filename the client never requests.
        details[sanitize_id_for_path(alert_id)] = build_detail_text(props)

    return lines, details


HAMCLOCK_BASE = "/opt/hamclock-backend/htdocs/ham/HamClock"
TMP_DIR = "/opt/hamclock-backend/htdocs/tmp"
OUT_PATH = os.path.join(HAMCLOCK_BASE, "firewx", "warnings.txt")


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
        geojson = fetch_alerts()
        lines, details = build_lines(geojson)
    except Exception as e:
        sys.stderr.write(f"fetch_firewx_warnings: fetch/parse failed: {e}\n")
        # leave any existing files in place rather than clobber them with empty data on a
        # transient network hiccup -- openCachedFile()'s own max-age will force a retry
        sys.exit(1)

    summary_content = "# generated by fetch_firewx_warnings.py -- do not edit\n"
    for line in lines:
        summary_content += line + "\n"
    atomic_write(out_path, summary_content)

    # detail/ lives alongside warnings.txt, served as /firewx/detail/<id>.txt
    detail_dir = os.path.join(os.path.dirname(out_path) or ".", "detail")
    os.makedirs(detail_dir, exist_ok=True)

    for safe_id, text in details.items():
        det_path = os.path.join(detail_dir, f"{safe_id}.txt")
        # HamClock's client-side getTCPLine() only returns a line when it sees a
        # trailing '\n' -- on EOF without one it discards whatever was already read
        # and returns false, so *every* file served through openCachedFile() must end
        # in a newline or the client silently gets nothing back.
        atomic_write(det_path, text + "\n")

    # prune detail files for warnings that are no longer active, so this directory doesn't
    # grow forever
    current = {f"{safe_id}.txt" for safe_id in details}
    for fn in os.listdir(detail_dir):
        if fn.endswith(".txt") and fn not in current:
            try:
                os.remove(os.path.join(detail_dir, fn))
            except OSError:
                pass

    print(f"fetch_firewx_warnings: wrote {len(lines)} warnings and "
          f"{len(details)} detail files to {out_path}")


if __name__ == "__main__":
    main()
