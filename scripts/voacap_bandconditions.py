#!/usr/bin/env python3
"""
VOACAP band conditions — output matches ClearSkyInstitute fetchBandConditions.pl format.

Scoring formula (reverse-engineered from CSI reference data):
  score = clamp(sigmoid(snr_xx, c=-2.0, k=0.14) * muf_day^0.4, 0, 1)

Key dvoacap parameters:
  - required_snr = 3.0 dB  (CW mode threshold)
  - required_reliability = 0.1  (optimistic 10th percentile, gives highest snr_xx)
  - man_made_noise_at_3mhz = 145.0  (default "quiet rural" noise, dB above kTB)
    This matches CSI's "-153 dB" quiet-location noise (which is the absolute floor,
    not the dvoacap parameter — 145 dB above kTB IS the quiet rural CCIR noise figure)

Fields used from dvoacap Prediction:
  - pred.snr_xx:         SNR at required-reliability percentile (dB) — primary score driver
  - pred.signal.muf_day: P(MUF > freq) — gates near/above-MUF bands via muf_day^0.4

Sigmoid parameters (c=-2.0, k=0.14, N=0.40) were grid-search optimised against the
full CSI 24-hour reference output for FL→CA path, Jan 2026, SSN=39.
"""
import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import List, Optional

import numpy as np
from dvoacap.path_geometry import GeoPoint
from dvoacap.prediction_engine import PredictionEngine

# 9 columns, CSI/HamClock style: 160, 80, 40, 30, 20, 17, 15, 12, 10
FREQS_MHZ = [1.8, 3.5, 7.0, 10.1, 14.0, 18.1, 21.0, 24.9, 28.0]
BANDS     = ["160", "80", "40", "30", "20", "17", "15", "12", "10"]

# dvoacap engine parameters
CW_REQUIRED_SNR         = 3.0    # dB — CW mode SNR threshold
CW_REQUIRED_RELIABILITY = 0.1    # 10th percentile (optimistic) for highest snr_xx
MAN_MADE_NOISE          = 145.0  # dB above kTB — CCIR quiet rural ("quiet location")

# Scoring parameters (grid-search optimised vs CSI reference)
SIGMOID_CENTER    = -2.0   # snr_xx (dB) at which sigmoid output = 0.5
SIGMOID_STEEPNESS =  0.14  # larger = sharper transition
MUF_EXPONENT      =  0.40  # muf_day^N — suppresses near/above-MUF bands

# muf_day below this is treated as "band above MUF" → score = 0
MUF_DEAD_THRESHOLD = 1e-4


def clamp01(x: float) -> float:
    if x != x:
        return 0.0
    return max(0.0, min(1.0, x))


def fmt_row(vals: List[float]) -> str:
    return ",".join(f"{clamp01(v):.2f}" for v in vals)


def mode_int_to_string(mode_int: int) -> str:
    return "CW"


def path_int_to_string(path_int: int) -> str:
    return "LP" if path_int == 1 else "SP"


def resolve_rx(args: argparse.Namespace) -> GeoPoint:
    if abs(args.rxlat) < 1e-9 and abs(args.rxlng) < 1e-9:
        if args.rx_default_lat is not None and args.rx_default_lon is not None:
            return GeoPoint.from_degrees(args.rx_default_lat, args.rx_default_lon)
    return GeoPoint.from_degrees(args.rxlat, args.rxlng)


def score_prediction(band: str, pred, debug: bool = False) -> float:
    """
    Compute 0..1 band score from a dvoacap Prediction object.

    score = sigmoid(snr_xx, c=-2, k=0.14) * muf_day^0.4

    snr_xx  = SNR at the 10th-percentile reliability threshold (optimistic estimate)
    muf_day = P(MUF > freq), used to scale down near-MUF and zero above-MUF bands
    """
    sig_obj = getattr(pred, "signal", None)
    if sig_obj is None:
        return 0.0

    muf_day = float(getattr(sig_obj, "muf_day", 0.0))

    if muf_day < MUF_DEAD_THRESHOLD:
        if debug:
            print(f"  {band}: muf_day={muf_day:.2e} → above MUF → 0.00", file=sys.stderr)
        return 0.0

    snr_xx = getattr(pred, "snr_xx", None)
    if snr_xx is None:
        snr_xx = getattr(sig_obj, "snr_xx", None)
    if snr_xx is None:
        if debug:
            print(f"  {band}: no snr_xx → 0.00", file=sys.stderr)
        return 0.0
    snr_xx = float(snr_xx)

    sigmoid_val = 1.0 / (1.0 + math.exp(-SIGMOID_STEEPNESS * (snr_xx - SIGMOID_CENTER)))
    score = clamp01(sigmoid_val * (muf_day ** MUF_EXPONENT))

    if debug:
        print(
            f"  {band}: snr_xx={snr_xx:+.2f}dB  muf_day={muf_day:.4f}"
            f"  sigmoid={sigmoid_val:.4f}  score={score:.4f}",
            file=sys.stderr,
        )
    return score


def compute_hour_row(
    eng: PredictionEngine, rx: GeoPoint, hour: int, debug: bool = False
) -> List[float]:
    eng.predict(rx_location=rx, utc_time=float(hour) / 24.0, frequencies=FREQS_MHZ)
    if debug:
        print(f"\nUTC {hour:02d}:", file=sys.stderr)
    row = [score_prediction(b, p, debug=debug) for b, p in zip(BANDS, eng.predictions)]
    return (row + [0.0] * 9)[:9]


def cache_key(args: argparse.Namespace) -> str:
    obj = {
        "year":   args.year,
        "month":  args.month,
        "ssn":    float(args.ssn),
        "tx":     (round(args.txlat, 6), round(args.txlng, 6)),
        "rx":     (round(args.rxlat, 6), round(args.rxlng, 6)),
        "rxdef":  (
            None if args.rx_default_lat is None else round(args.rx_default_lat, 6),
            None if args.rx_default_lon is None else round(args.rx_default_lon, 6),
        ),
        "path":   int(args.path),
        "pow":    int(args.pow),
        "mode":   int(args.mode),
        "toa":    float(args.toa),
        "req_snr":  CW_REQUIRED_SNR,
        "req_rel":  CW_REQUIRED_RELIABILITY,
        "noise":    MAN_MADE_NOISE,
        "sig_c":    SIGMOID_CENTER,
        "sig_k":    SIGMOID_STEEPNESS,
        "muf_n":    MUF_EXPONENT,
    }
    s = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return str(abs(sum(s) + 1315423911 * len(s)))


def load_cache(cache_dir: Path, key: str, ttl: int) -> Optional[List[List[float]]]:
    if ttl <= 0:
        return None
    p = cache_dir / f"bandcond_{key}.json"
    try:
        if (time.time() - p.stat().st_mtime) > ttl:
            return None
        obj = json.loads(p.read_text(encoding="utf-8"))
        rows = obj.get("rows")
        if isinstance(rows, list) and len(rows) == 24:
            return rows
    except Exception:
        return None
    return None


def save_cache(cache_dir: Path, key: str, rows: List[List[float]]) -> None:
    try:
        cache_dir.mkdir(parents=True, exist_ok=True)
        p = cache_dir / f"bandcond_{key}.json"
        p.write_text(json.dumps({"rows": rows}), encoding="utf-8")
    except Exception:
        pass


def compute_rows(args: argparse.Namespace, debug: bool = False) -> List[List[float]]:
    tx = GeoPoint.from_degrees(args.txlat, args.txlng)
    rx = resolve_rx(args)

    eng = PredictionEngine()
    eng.params.ssn                  = float(args.ssn)
    eng.params.month                = int(args.month)
    eng.params.tx_location          = tx
    eng.params.tx_power             = float(args.pow)
    eng.params.min_angle            = np.deg2rad(float(args.toa))
    eng.params.long_path            = bool(int(args.path) == 1)
    eng.params.required_snr         = CW_REQUIRED_SNR
    eng.params.required_reliability = CW_REQUIRED_RELIABILITY
    eng.params.man_made_noise_at_3mhz = MAN_MADE_NOISE

    return [compute_hour_row(eng, rx, h, debug=debug) for h in range(24)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--year",   type=int,   required=True)
    ap.add_argument("--month",  type=int,   required=True)
    ap.add_argument("--utc",    type=int,   required=True)
    ap.add_argument("--txlat",  type=float, required=True)
    ap.add_argument("--txlng",  type=float, required=True)
    ap.add_argument("--rxlat",  type=float, required=True)
    ap.add_argument("--rxlng",  type=float, required=True)
    ap.add_argument("--path",   type=int,   default=0)
    ap.add_argument("--pow",    type=int,   default=100)
    ap.add_argument("--mode",   type=int,   default=19)
    ap.add_argument("--toa",    type=float, default=3.0)
    ap.add_argument("--ssn",    type=float, required=True)
    ap.add_argument("--cache-dir", type=str, default="/opt/hamclock-backend/cache/voacap-cache")
    ap.add_argument("--cache-ttl", type=int, default=300)
    ap.add_argument("--rx-default-lat", type=float, default=None)
    ap.add_argument("--rx-default-lon", type=float, default=None)
    ap.add_argument("--debug",  action="store_true",
                    help="Print raw dvoacap values to stderr for diagnostics")

    args = ap.parse_args()

    if not (1 <= args.month <= 12):
        print("bad month", file=sys.stderr)
        return 2
    if not (0 <= args.utc <= 23):
        print("bad utc", file=sys.stderr)
        return 2

    cache_dir = Path(args.cache_dir)
    key = cache_key(args)

    rows = load_cache(cache_dir, key, args.cache_ttl)
    if rows is None:
        rows = compute_rows(args, debug=args.debug)
        save_cache(cache_dir, key, rows)

    utc = int(args.utc) % 24
    header = (
        f"{int(args.pow)}W,"
        f"{mode_int_to_string(int(args.mode))},"
        f"TOA>{float(args.toa):g},"
        f"{path_int_to_string(int(args.path))},"
        f"S={int(round(float(args.ssn)))}"
    )

    print(fmt_row(rows[utc]))
    print(header)
    for h in range(1, 24):
        print(f"{h} {fmt_row(rows[h])}")
    print(f"0 {fmt_row(rows[0])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
