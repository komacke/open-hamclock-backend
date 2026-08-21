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
#  hab_daemon.py
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
# hab_daemon.py -- persistent SondeHub-Amateur listener for HamClock's "Balloons"
# pane, HAB half. Same shape as blitzortung_daemon.py: a long-lived process that
# docker/run.sh launches directly.
#
# Requires the `sondehub` PyPI package
#
# ============================================================

import argparse
import json
import os
import signal
import sys
import threading
import time
from datetime import datetime

import sondehub

from balloon_common import BalloonState, http_get, clean_field, log, atomic_write_lines

HAB_URL_TMPL = "https://api.v2.sondehub.org/amateur?last={lookback}"
HAB_TRACKER_URL = "https://amateur.sondehub.org/"

CREDIT_LINE = "Credit:SondeHub+wsprlive"

OUTDIR = "/opt/hamclock-backend/htdocs/ham/HamClock/balloons"   # adjust to your OHB webroot

DEFAULT_BACKFILL_LOOKBACK_SEC = 4 * 3600
DEFAULT_DROP_AGE_SEC          = 12 * 3600
DEFAULT_FLUSH_INTERVAL_SEC    = 60
DEFAULT_STALE_AFTER_SEC       = 30 * 60   # no messages at all for this long -> assume wedged, exit

def parse_iso8601_to_unix(s):
    if not s:
        return None
    try:
        s = s.replace("Z", "+00:00")
        return int(datetime.fromisoformat(s).timestamp())
    except ValueError:
        return None

def record_from_amateur_msg(rec):
    """Extract (key, fields, ts, lat, lon) from one Amateur Telemetry Format dict, or
    None if it doesn't have enough to place on the map. Shared between the startup
    REST backfill and every live websocket message -- both use the same schema.
    """
    callsign = rec.get("payload_callsign") or rec.get("serial")
    lat = rec.get("lat")
    lon = rec.get("lon")
    if not callsign or lat is None or lon is None:
        return None
    lat, lon = float(lat), float(lon)
    if lat == 0.0 and lon == 0.0:
        # "null island" -- SondeHub passes this through as the payload's default/
        # no-fix coordinate before it's gotten a first real GPS lock (often paired
        # with sats=0, as seen in practice). Not a real position; don't map it.
        return None

    last_t = parse_iso8601_to_unix(rec.get("datetime")) or int(time.time())

    detail_bits = []
    if rec.get("frequency"):
        detail_bits.append(f"{rec['frequency']:.3f} MHz")
    if rec.get("batt") is not None:
        detail_bits.append(f"{rec['batt']:.1f}V")
    if rec.get("temp") is not None:
        detail_bits.append(f"{rec['temp']:.0f}C")
    if rec.get("sats") is not None:
        detail_bits.append(f"{rec['sats']}sat")
    detail = clean_field(" ".join(detail_bits))

    fields = {
        "name": callsign,
        "callsign": callsign,
        "alt_m": rec.get("alt"),
        "speed_mps": rec.get("vel_h"),
        "hdg_deg": rec.get("heading"),
        "detail": detail,
        "url": HAB_TRACKER_URL,
        # SondeHub reports frequency in MHz; the wire format uses Hz throughout
        "freq_hz": rec["frequency"] * 1e6 if rec.get("frequency") else None,
        "batt_v": rec.get("batt"),
        "temp_c": rec.get("temp"),
    }
    key = f"HAB:{callsign}"
    return key, fields, last_t, lat, lon

class HabDaemon:

    def __init__(self, outdir, drop_age_sec, flush_interval_sec, stale_after_sec, backfill_lookback_sec):
        self.outdir = outdir
        self.flush_interval_sec = flush_interval_sec
        self.stale_after_sec = stale_after_sec
        self.backfill_lookback_sec = backfill_lookback_sec
        self.state = BalloonState(os.path.join(outdir, "hab_state.json"), drop_age_sec)
        self.lock = threading.Lock()
        self.last_msg_t = time.time()          # seed so the watchdog doesn't fire immediately
        self.n_msgs_total = 0                  # lifetime count, resets only on process restart
        self.n_msgs_window = 0                 # count since the last flush() -- see flush() below
        self.stopping = threading.Event()

    def backfill(self):
        log("HAB", f"startup backfill query ({self.backfill_lookback_sec}s)")
        try:
            raw = http_get(HAB_URL_TMPL.format(lookback=self.backfill_lookback_sec))
            data = json.loads(raw)
            n = 0
            with self.lock:
                for serial, rec in data.items():
                    got = record_from_amateur_msg(rec)
                    if got:
                        key, fields, ts, lat, lon = got
                        self.state.update(key, fields, ts, lat, lon)
                        n += 1
            log("HAB", f"backfill seeded {n} flights")
        except Exception as e:
            log("HAB", f"backfill failed ({e}) -- continuing; live messages will populate state")

    def on_message(self, msg):
        try:
            recs = msg if isinstance(msg, list) else [msg]
            with self.lock:
                for rec in recs:
                    got = record_from_amateur_msg(rec)
                    if got:
                        key, fields, ts, lat, lon = got
                        self.state.update(key, fields, ts, lat, lon)
                        self.n_msgs_total += 1
                        self.n_msgs_window += 1
            self.last_msg_t = time.time()
        except Exception as e:
            log("HAB", f"error handling message: {e}")

    def on_connect(self, mqttc, obj, flags, rc):
        log("HAB", f"websocket connected (rc={rc})")

    def on_disconnect(self, client, userdata, rc):
        log("HAB", f"websocket disconnected (rc={rc}) -- sondehub.Stream will attempt to reconnect")

    def flush(self):
        with self.lock:
            self.state.prune()
            self.state.save()
            hab_rows = self.state.all_rows("HAB")
            # snapshot-and-reset the per-interval counter here, still under the same
            # lock on_message() uses to increment it, so nothing lands in the gap
            # between reading and clearing it
            msgs_this_interval = self.n_msgs_window
            self.n_msgs_window = 0
        hab_path = os.path.join(self.outdir, "hab.txt")
        atomic_write_lines(hab_path, hab_rows)

        # also write the final merged balloons.txt HamClock actually fetches, folding
        # in whatever fetch_pico.py's cron has most recently written to pico.txt.
        pico_rows = []
        pico_path = os.path.join(self.outdir, "pico.txt")
        try:
            with open(pico_path, "r") as f:
                pico_rows = [line.rstrip("\n") for line in f if line.strip()]
        except FileNotFoundError:
            log("HAB", f"{pico_path} not found yet -- balloons.txt will have zero PICO rows for now")

        balloons_path = os.path.join(self.outdir, "balloons.txt")
        atomic_write_lines(balloons_path, [CREDIT_LINE] + hab_rows + pico_rows)

        log("HAB", f"flushed {len(hab_rows)} HAB ({msgs_this_interval} msgs in the last "
                    f"{self.flush_interval_sec}s, {self.n_msgs_total} total since start) "
                    f"+ {len(pico_rows)} PICO -> {balloons_path}")

    def flush_loop(self):
        while not self.stopping.wait(self.flush_interval_sec):
            self.flush()

    def watchdog_loop(self):
        while not self.stopping.wait(30):
            idle = time.time() - self.last_msg_t
            if idle > self.stale_after_sec:
                log("HAB", f"no messages received in {idle:.0f}s (> {self.stale_after_sec}s) -- "
                            "assuming the connection is wedged; exiting so docker/run.sh's restart loop "
                            "relaunches us (same philosophy as the blitzortung block above it)")
                self.flush()
                os._exit(1)                  # hard exit -- let the restart loop fully reinit the process

    def run(self):
        self.backfill()
        self.flush()                          # write hab.txt right away, don't wait a full flush interval

        threading.Thread(target=self.flush_loop, daemon=True).start()
        threading.Thread(target=self.watchdog_loop, daemon=True).start()

        stream = sondehub.Stream(on_message=self.on_message, on_connect=self.on_connect,
                                  on_disconnect=self.on_disconnect, prefix="amateur",
                                  auto_start_loop=True)

        def handle_signal(signum, frame):
            log("HAB", f"received signal {signum}, shutting down")
            self.stopping.set()
            self.flush()
            try:
                stream.disconnect()
            except Exception:
                pass
            sys.exit(0)

        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)

        log("HAB", "listening for live amateur telemetry...")
        while not self.stopping.is_set():
            time.sleep(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--outdir", default=OUTDIR,
                     help="directory to write hab.txt and the state cache into")
    ap.add_argument("--drop-age", type=int, default=DEFAULT_DROP_AGE_SEC,
                     help="drop a cached flight if its last report is older than this, seconds")
    ap.add_argument("--flush-interval", type=int, default=DEFAULT_FLUSH_INTERVAL_SEC,
                     help="how often to write hab.txt/save state, seconds")
    ap.add_argument("--stale-after", type=int, default=DEFAULT_STALE_AFTER_SEC,
                     help="exit if no message received at all in this many seconds")
    ap.add_argument("--backfill-lookback", type=int, default=DEFAULT_BACKFILL_LOOKBACK_SEC,
                     help="REST backfill window on startup, seconds")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    daemon = HabDaemon(args.outdir, args.drop_age, args.flush_interval,
                        args.stale_after, args.backfill_lookback)
    daemon.run()


if __name__ == "__main__":
    main()
