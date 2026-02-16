#!/usr/bin/env python3
"""
Generate HamClock-compatible Kp stream: 72 lines total
- 56 historic values (7 days * 8 bins/day), ending at a chosen 3-hour boundary with optional lag
- 16 forecast values from the 3-day geomag forecast Kp table, with an adjustable bin offset
  (so you can start forecast at 03-06UT instead of 00-03UT and still keep 16 bins by
   borrowing the first bin of day3).

Output: one float per line, oldest -> newest.
Never emits NaN or negative values; fills missing with persistence.
"""

import re
import math
from io import StringIO
from datetime import datetime, timezone, timedelta

import pandas as pd
import requests


DGD_URL = "https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt"
GMF_URL = "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt"

KP_VPD = 8
KP_NHD = 7
KP_NPD = 2
KP_NV  = (KP_NHD + KP_NPD) * KP_VPD  # 72
HIST_NV = KP_NHD * KP_VPD            # 56
FCST_NV = KP_NPD * KP_VPD            # 16

# CSI-like samples taken suggests forecast starts at 03-06UT, not 00-03UT:
# skip 1 bin, then take 16 bins (pulling 1 bin from day3).
FCST_OFFSET_BINS = 1

# Optional historic lag in bins (0 = latest completed 3h bin)
LAG_BINS = 2


def floor_to_3h(dt_utc: datetime) -> datetime:
    dt_utc = dt_utc.astimezone(timezone.utc)
    hour = (dt_utc.hour // 3) * 3
    return dt_utc.replace(hour=hour, minute=0, second=0, microsecond=0)


def sanitize_series(vals, fallback=0.0):
    """Replace non-finite or negative values with last good (persistence)."""
    out = []
    last = None
    for v in vals:
        try:
            f = float(v)
        except Exception:
            f = float("nan")

        if math.isnan(f) or math.isinf(f) or f < 0:
            f = last if last is not None else float(fallback)
        else:
            last = f

        out.append(f)
    return out


def load_dgd_planetary_timeseries() -> pd.DataFrame:
    """
    Return DataFrame with columns:
      time_tag (UTC datetime)  kp (float)
    Built from DGD daily rows expanded into 8 x 3-hour bins per day.
    """
    txt = requests.get(DGD_URL, timeout=20).text

    data_lines = [ln for ln in txt.splitlines()
                  if len(ln) >= 5 and ln[:4].isdigit() and ln[4].isspace()]
    if not data_lines:
        raise RuntimeError("No DGD data rows found")

    df = pd.read_csv(StringIO("\n".join(data_lines)), sep=r"\s+", header=None, engine="python")
    df.columns = (
        ["year", "month", "day"] +
        ["mid_A"]  + [f"mid_K{i}"  for i in range(1, 9)] +
        ["high_A"] + [f"high_K{i}" for i in range(1, 9)] +
        ["plan_A"] + [f"plan_K{i}" for i in range(1, 9)]
    )
    df["date"] = pd.to_datetime(df[["year", "month", "day"]], utc=True)

    bins = []
    for _, r in df.sort_values("date").iterrows():
        day0 = r["date"].to_pydatetime()  # UTC midnight
        for i in range(1, 9):
            t = day0 + timedelta(hours=(i-1)*3)
            bins.append((t, float(r[f"plan_K{i}"])))

    ts = pd.DataFrame(bins, columns=["time_tag", "kp"]).sort_values("time_tag").reset_index(drop=True)
    ts["kp"] = sanitize_series(ts["kp"].tolist(), fallback=0.0)  # handle -1.00 days etc
    return ts


def load_forecast_16_bins(offset_bins: int = FCST_OFFSET_BINS) -> list[float]:
    """
    Parse NOAA 3-day geomag forecast Kp table and return 16 values as a contiguous
    slice from the 24-bin (3-day) sequence, starting at offset_bins.
    """
    txt = requests.get(GMF_URL, timeout=20).text
    lines = txt.splitlines()

    start_idx = None
    for i, ln in enumerate(lines):
        if ln.startswith("NOAA Kp index forecast"):
            start_idx = i
            break
    if start_idx is None:
        raise RuntimeError("No 'NOAA Kp index forecast' header found")

    row_re = re.compile(r"^\s*\d{2}-\d{2}UT\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*$")

    rows = []
    for ln in lines[start_idx+1:]:
        m = row_re.match(ln)
        if not m:
            continue
        rows.append((float(m.group(1)), float(m.group(2)), float(m.group(3))))
        if len(rows) == 8:
            break

    if len(rows) != 8:
        raise RuntimeError(f"Expected 8 Kp rows (00-03..21-00), got {len(rows)}")

    day1 = [r[0] for r in rows]
    day2 = [r[1] for r in rows]
    day3 = [r[2] for r in rows]

    seq24 = day1 + day2 + day3  # 24 bins total
    if offset_bins < 0 or offset_bins + FCST_NV > len(seq24):
        raise RuntimeError(f"Bad offset_bins={offset_bins}: need 0 <= offset <= {len(seq24)-FCST_NV}")

    fcst = seq24[offset_bins:offset_bins + FCST_NV]
    fcst = sanitize_series(fcst, fallback=0.0)
    return fcst


def build_kp72(lag_bins: int = LAG_BINS, fcst_offset_bins: int = FCST_OFFSET_BINS) -> list[float]:
    """
    Return exactly 72 values (56 historic + 16 forecast), oldest -> newest.
    """
    dgd_ts = load_dgd_planetary_timeseries()
    fcst16 = load_forecast_16_bins(offset_bins=fcst_offset_bins)

    now_utc = datetime.now(timezone.utc)
    hist_end = floor_to_3h(now_utc) - timedelta(hours=3 * lag_bins)

    hist = dgd_ts[dgd_ts["time_tag"] <= hist_end]
    if hist.empty:
        raise RuntimeError("No historic bins <= hist_end; check clock or DGD availability")

    hist56 = hist.tail(HIST_NV)["kp"].tolist()
    if len(hist56) < HIST_NV:
        pad = [hist56[0]] * (HIST_NV - len(hist56))
        hist56 = pad + hist56

    out = sanitize_series(hist56 + fcst16, fallback=hist56[-1] if hist56 else 0.0)

    if len(out) != KP_NV:
        raise RuntimeError(f"Internal error: expected {KP_NV} values, got {len(out)}")
    return out


def main():
    kp = build_kp72(lag_bins=LAG_BINS, fcst_offset_bins=FCST_OFFSET_BINS)
    print("\n".join(f"{v:.2f}" for v in kp))


if __name__ == "__main__":
    main()

