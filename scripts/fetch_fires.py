#!/usr/bin/env python3
"""
fetch_fires.py -- OHB-side poller for HamClock's Fires overlay.

Polls NASA FIRMS for global active-fire hotspots (VIIRS NOAA-20 + NOAA-21 --
the Suomi NPP feed is being retired 1 Nov 2026, see FIRMS' announcement),
keeps only detections that clear a confidence + intensity floor, and
atomically writes a small flat cache file that hotspots.pl serves to
HamClock clients on request. Same two-stage shape as the Blitzortung
lightning feed: a slow poller does the real work, the CGI just hands over
whatever it last wrote.

Run this from cron/systemd every FETCH_INTERVAL_MIN minutes below --
FIRMS' own NRT data only refreshes a few times a day per satellite pass
anyway, so polling more often than ~15 minutes buys nothing.

Output cache format -- one hotspot per line, matching what fires.cpp expects:
    lat,lon,frp
"""

import csv
import io
import os
import sys
import tempfile
import time
import urllib.request

# ---- configuration ---------------------------------------------------------

# Free key: https://firms.modaps.eosdis.nasa.gov/api/map_key/
MAP_KEY = os.environ.get("FIRMS_MAP_KEY", "")

# SNPP is being retired (Nov 2026) -- stick to the two current VIIRS platforms.
# Add "MODIS_NRT" if you also want 1km MODIS coverage; MODIS uses a numeric
# 0-100 confidence scale instead of VIIRS' low/nominal/high, handled below.
SOURCES = ["VIIRS_NOAA20_NRT", "VIIRS_NOAA21_NRT"]

DAY_RANGE = 1                                   # most recent day only
FETCH_INTERVAL_MIN = 15                         # for the cron/systemd timer, not enforced here

CACHE_FILE = "/opt/hamclock-backend/htdocs/ham/HamClock/fires/hotspots.txt"
LOG_FILE = "/opt/hamclock-backend/logs/fetch_fires.log"

# Threshold -- this is what keeps a world query from being 30k-100k+ points/day.
# Raise MIN_FRP_MW if the map still looks too busy; a good starting range is 10-25 MW.
MIN_FRP_MW = 10.0
VIIRS_MIN_CONFIDENCE = {"n", "h"}               # nominal or high; drop "l" (low)
MODIS_MIN_CONFIDENCE = 50                       # 0-100 scale

REQUEST_TIMEOUT_S = 60

# ---- fetch ------------------------------------------------------------------

def fetch_source(source):
    """Return list of (lat, lon, frp) tuples passing the threshold for one FIRMS source."""
    if not MAP_KEY:
        raise RuntimeError("FIRMS_MAP_KEY not set")

    url = f"https://firms.modaps.eosdis.nasa.gov/api/area/csv/{MAP_KEY}/{source}/world/{DAY_RANGE}"
    with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT_S) as resp:
        raw = resp.read().decode("utf-8", errors="replace")

    hotspots = []
    reader = csv.DictReader(io.StringIO(raw))
    is_viirs = source.startswith("VIIRS")

    for row in reader:
        try:
            lat = float(row["latitude"])
            lon = float(row["longitude"])
            frp = float(row["frp"])
        except (KeyError, ValueError):
            continue

        if frp < MIN_FRP_MW:
            continue

        conf = row.get("confidence", "").strip()
        if is_viirs:
            if conf.lower() not in VIIRS_MIN_CONFIDENCE:
                continue
        else:
            try:
                if float(conf) < MODIS_MIN_CONFIDENCE:
                    continue
            except ValueError:
                continue

        hotspots.append((lat, lon, frp))

    return hotspots


def fetch_all():
    # De-dupe overlapping satellite passes / overlapping sources onto a coarse grid,
    # keeping the higher FRP reading whenever two sources see roughly the same spot.
    seen = {}
    for source in SOURCES:
        try:
            spots = fetch_source(source)
        except Exception as e:
            log(f"fetch failed for {source}: {e}")
            continue
        for lat, lon, frp in spots:
            key = (round(lat, 2), round(lon, 2))
            if key not in seen or frp > seen[key]:
                seen[key] = frp
    return [(lat, lon, frp) for (lat, lon), frp in seen.items()]


# ---- cache write (atomic) ----------------------------------------------------

def write_cache(hotspots):
    d = os.path.dirname(CACHE_FILE)
    os.makedirs(d, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=d, prefix=".fires_", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            for lat, lon, frp in hotspots:
                f.write(f"{lat:.4f},{lon:.4f},{frp:.1f}\n")
        os.replace(tmp_path, CACHE_FILE)        # atomic on POSIX -- readers never see a partial file
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    sys.stderr.write(line)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except OSError:
        pass


def main():
    hotspots = fetch_all()
    write_cache(hotspots)
    log(f"wrote {len(hotspots)} hotspots from {SOURCES} (MIN_FRP_MW={MIN_FRP_MW})")


if __name__ == "__main__":
    main()
