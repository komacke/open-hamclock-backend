#!/usr/bin/env python3
"""
Build HamClock MUF-RT maps:

  - fetch KC2G station observations from https://prop.kc2g.com/api/stations.json
  - filter stations active within last hour (+ optional confidence filter)
  - interpolate MUF globally (IDW on sphere)
  - build a semi-transparent heatmap layer
  - draw KC2G-like station markers (colored filled dots + MUF number; fades with confidence)
  - composite overlay onto Day and/or Night Countries base maps
  - write BMPv4 RGB565 top-down + zlib-compressed .bmp.z

Dependencies: python3, pillow
Optional: numpy (strongly recommended for speed)
"""

import argparse
import datetime as dt
import json
import os
import struct
import sys
import time
import zlib
from collections import deque
from io import BytesIO
from urllib.request import Request, urlopen

try:
    import numpy as np
except ImportError:
    np = None

from PIL import Image, ImageDraw, ImageFont, ImageFilter


KC2G_STATIONS_JSON = "https://prop.kc2g.com/api/stations.json"


def http_get(url: str, timeout: int = 20) -> bytes:
    req = Request(url, headers={"User-Agent": "OHB-MUF-RT/1.0"})
    with urlopen(req, timeout=timeout) as r:
        return r.read()


def parse_kc2g_time(ts) -> float:
    if ts is None:
        return 0.0
    if isinstance(ts, (int, float)):
        return float(ts)
    s = str(ts).strip()
    if s.isdigit():
        return float(s)
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return dt.datetime.strptime(s, fmt).replace(tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            pass
    return 0.0


def lonlat_to_xy(lon_deg: float, lat_deg: float, w: int, h: int) -> tuple[int, int]:
    # Equirectangular: lon [-180,180], lat [-90,90]
    x = int(round((lon_deg + 180.0) / 360.0 * (w - 1)))
    y = int(round((90.0 - lat_deg) / 180.0 * (h - 1)))
    x = max(0, min(w - 1, x))
    y = max(0, min(h - 1, y))
    return x, y


def haversine_rad(lon1, lat1, lon2, lat2):
    dlon = lon2 - lon1
    dlat = lat2 - lat1
    a = np.sin(dlat / 2.0) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin(dlon / 2.0) ** 2
    c = 2.0 * np.arcsin(np.minimum(1.0, np.sqrt(a)))
    return c


def muf_colormap(mhz: float) -> tuple[int, int, int]:
    """
    Approximate HamClock-like palette: low=blue, mid=green/yellow, high=red/purple.
    """
    stops = [
        (0.0,  (0, 0, 80)),
        (5.0,  (0, 40, 180)),
        (8.0,  (0, 140, 255)),
        (10.0, (0, 220, 120)),
        (14.0, (220, 220, 0)),
        (18.0, (255, 140, 0)),
        (22.0, (255, 60, 0)),
        (28.0, (200, 0, 120)),
        (35.0, (120, 0, 160)),
    ]
    if mhz <= stops[0][0]:
        return stops[0][1]
    if mhz >= stops[-1][0]:
        return stops[-1][1]
    for i in range(len(stops) - 1):
        x0, c0 = stops[i]
        x1, c1 = stops[i + 1]
        if x0 <= mhz <= x1:
            t = (mhz - x0) / (x1 - x0) if x1 > x0 else 0.0
            r = int(round(c0[0] + t * (c1[0] - c0[0])))
            g = int(round(c0[1] + t * (c1[1] - c0[1])))
            b = int(round(c0[2] + t * (c1[2] - c0[2])))
            return (r, g, b)
    return stops[-1][1]


def load_base_map(path: str) -> Image.Image:
    if path.endswith(".bmp.z"):
        raw = open(path, "rb").read()
        bmp = zlib.decompress(raw)
        return Image.open(BytesIO(bmp)).convert("RGB")
    return Image.open(path).convert("RGB")


def _rgb888_to_rgb565_le_bytes(img_rgb: Image.Image) -> bytes:
    if img_rgb.mode != "RGB":
        img_rgb = img_rgb.convert("RGB")
    w, h = img_rgb.size
    data = img_rgb.tobytes()
    row_bytes = w * 2
    pad = (4 - (row_bytes % 4)) % 4
    out = bytearray((row_bytes + pad) * h)

    oi = 0
    di = 0
    for _y in range(h):
        for _x in range(w):
            r = data[di]
            g = data[di + 1]
            b = data[di + 2]
            di += 3
            v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            out[oi] = v & 0xFF
            out[oi + 1] = (v >> 8) & 0xFF
            oi += 2
        if pad:
            out[oi:oi + pad] = b"\x00" * pad
            oi += pad
    return bytes(out)


def write_bmpv4_rgb565_topdown_and_z(img_rgb: Image.Image, out_bmp: str, out_bmp_z: str, zlevel: int = 9) -> None:
    if img_rgb.mode != "RGB":
        img_rgb = img_rgb.convert("RGB")

    w, h = img_rgb.size
    pixel_bytes = _rgb888_to_rgb565_le_bytes(img_rgb)
    row_bytes = w * 2
    pad = (4 - (row_bytes % 4)) % 4
    image_size = (row_bytes + pad) * h

    bfType = b"BM"
    bfOffBits = 14 + 108
    bfSize = bfOffBits + image_size

    file_header = struct.pack("<2sIHHI", bfType, bfSize, 0, 0, bfOffBits)

    # BITMAPV4HEADER (108 bytes)
    bV4Size = 108
    bV4Width = w
    bV4Height = -h           # top-down
    bV4Planes = 1
    bV4BitCount = 16
    BI_BITFIELDS = 3
    bV4Compression = BI_BITFIELDS
    bV4SizeImage = image_size

    bV4RedMask = 0xF800
    bV4GreenMask = 0x07E0
    bV4BlueMask = 0x001F
    bV4AlphaMask = 0x0000

    bV4CSType = 0x73524742    # 'sRGB'
    endpoints = b"\x00" * 36
    gamma0 = gamma1 = gamma2 = 0

    v4_header = struct.pack(
        "<IiiHHIIiiII"
        "IIII"
        "I"
        "36s"
        "III",
        bV4Size,
        bV4Width,
        bV4Height,
        bV4Planes,
        bV4BitCount,
        bV4Compression,
        bV4SizeImage,
        0, 0,           # XPelsPerMeter, YPelsPerMeter
        0, 0,           # ClrUsed, ClrImportant
        bV4RedMask,
        bV4GreenMask,
        bV4BlueMask,
        bV4AlphaMask,
        bV4CSType,
        endpoints,
        gamma0, gamma1, gamma2
    )

    bmp_bytes = file_header + v4_header + pixel_bytes

    with open(out_bmp, "wb") as f:
        f.write(bmp_bytes)

    comp = zlib.compress(bmp_bytes, level=zlevel)
    with open(out_bmp_z, "wb") as f:
        f.write(comp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)

    # Day/night bases:
    ap.add_argument("--base-day", help="Countries Day base (.bmp|.bmp.z|.png)")
    ap.add_argument("--base-night", help="Countries Night base (.bmp|.bmp.z|.png)")

    ap.add_argument("--outdir", required=True)
    ap.add_argument("--product", default="MUF-RT")

    ap.add_argument("--alpha", type=float, default=0.55, help="heatmap opacity 0..1")
    ap.add_argument("--active-seconds", type=int, default=3600)
    ap.add_argument("--min-confidence", type=float, default=0.0)
    ap.add_argument("--k", type=int, default=24)
    ap.add_argument("--p", type=float, default=2.0)
    ap.add_argument("--muf-min", type=float, default=0.0)
    ap.add_argument("--muf-max", type=float, default=35.0)
    ap.add_argument("--stations-url", default=KC2G_STATIONS_JSON)
    ap.add_argument("--debug-png", action="store_true")
    args = ap.parse_args()

    if np is None:
        print("ERROR: numpy is required for reasonable performance. Try: apt install python3-numpy", file=sys.stderr)
        return 2

    w, h = args.width, args.height
    os.makedirs(args.outdir, exist_ok=True)

    if not args.base_day and not args.base_night:
        print("ERROR: Provide at least one of --base-day or --base-night", file=sys.stderr)
        return 2

    # Fetch stations
    stations = json.loads(http_get(args.stations_url).decode("utf-8", errors="replace"))
    now = time.time()

    pts = []
    for row in stations:
        st = row.get("station") or {}
        lon = st.get("longitude")
        lat = st.get("latitude")
        mufd = row.get("mufd") or row.get("mufD") or row.get("muf")
        conf = row.get("confidence", 1.0)
        t = parse_kc2g_time(row.get("time"))

        if lon is None or lat is None or mufd is None:
            continue
        try:
            lon = float(lon)
            lat = float(lat)
            mufd = float(mufd)
            conf = float(conf) if conf is not None else 1.0
        except Exception:
            continue

        # Option A: Normalize longitude to [-180, 180]
        if lon > 180.0:
            lon -= 360.0
        elif lon < -180.0:
            lon += 360.0

        if (now - t) > args.active_seconds:
            continue
        if conf < args.min_confidence:
            continue

        code = (st.get("code") or "").strip()
        pts.append((lon, lat, mufd, conf, code))

    if len(pts) < 4:
        print(f"ERROR: only {len(pts)} active stations found; refusing to render.", file=sys.stderr)
        return 2

    # Prepare arrays for interpolation
    lons = np.array([p[0] for p in pts], dtype=np.float64)
    lats = np.array([p[1] for p in pts], dtype=np.float64)
    vals = np.array([p[2] for p in pts], dtype=np.float64)
    confs = np.array([p[3] for p in pts], dtype=np.float64)

    lons_r = np.deg2rad(lons)
    lats_r = np.deg2rad(lats)

    xs = np.linspace(-180.0, 180.0, w, dtype=np.float64)
    ys = np.linspace(90.0, -90.0, h, dtype=np.float64)
    grid_lon, grid_lat = np.meshgrid(xs, ys)
    grid_lon_r = np.deg2rad(grid_lon)
    grid_lat_r = np.deg2rad(grid_lat)

    k = max(4, min(args.k, len(pts)))
    pwr = float(args.p)
    eps = 1e-6

    out_muf = np.empty((h, w), dtype=np.float32)
    chunk_rows = 40

    for y0 in range(0, h, chunk_rows):
        y1 = min(h, y0 + chunk_rows)
        glon = grid_lon_r[y0:y1, :, None]
        glat = grid_lat_r[y0:y1, :, None]

        d = haversine_rad(glon, glat, lons_r[None, None, :], lats_r[None, None, :])
        idx = np.argpartition(d, kth=k - 1, axis=2)[:, :, :k]
        d_k = np.take_along_axis(d, idx, axis=2)

        w_k = 1.0 / (np.power(d_k + eps, pwr))
        w_k = w_k * confs[idx]

        v_k = vals[idx]
        muf = np.sum(w_k * v_k, axis=2) / (np.sum(w_k, axis=2) + eps)
        muf = np.clip(muf, args.muf_min, args.muf_max)
        out_muf[y0:y1, :] = muf.astype(np.float32)

    # Build overlay RGBA: heatmap + station marks (no base yet)
    overlay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = overlay.load()
    a = int(round(max(0.0, min(1.0, args.alpha)) * 255))

    for y in range(h):
        row = out_muf[y, :]
        for x in range(w):
            r, g, b = muf_colormap(float(row[x]))
            px[x, y] = (r, g, b, a)

    draw = ImageDraw.Draw(overlay)
    try:
        font = ImageFont.load_default()
    except Exception:
        font = None

    # KC2G-like markers (colored filled dots + MUF number; alpha fades with confidence)
    for lon, lat, mufd, conf, code in pts:
        x, y = lonlat_to_xy(lon, lat, w, h)

        # Dot radius: slightly smaller than the earlier outline circle
        rad = max(3, int(round(min(w, h) / 140)))

        # Color keyed to MUF value
        fill_r, fill_g, fill_b = muf_colormap(float(mufd))

        # Confidence -> alpha. If confidence is 0..100, scale to 0..1.
        c = conf
        if c > 1.0:
            c = c / 100.0
        c = max(0.0, min(1.0, c))
        alpha = int(round(80 + c * 175))  # keep visible even if low confidence

        fill = (fill_r, fill_g, fill_b, alpha)
        outline = (0, 0, 0, 220)

        draw.ellipse(
            (x - rad, y - rad, x + rad, y + rad),
            fill=fill,
            outline=outline,
            width=1
        )

        muf_i = int(round(mufd))
        label = str(muf_i)

        try:
            bbox = draw.textbbox((0, 0), label, font=font)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        except Exception:
            tw, th = (6, 8)

        tx = x - tw // 2
        ty = y - th // 2

        draw.text((tx + 1, ty + 1), label, fill=(0, 0, 0, 255), font=font)
        draw.text((tx, ty), label, fill=(255, 255, 255, 255), font=font)

    def render_variant(prefix: str, base_path: str):
        base = load_base_map(base_path)
        if base.size != (w, h):
            base = base.resize((w, h), resample=Image.BILINEAR)

        comp = Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB")

        size_tag = f"{w}x{h}"
        out_bmp = os.path.join(args.outdir, f"{prefix}-{size_tag}-{args.product}.bmp")
        out_bmp_z = out_bmp + ".z"
        write_bmpv4_rgb565_topdown_and_z(comp, out_bmp, out_bmp_z, zlevel=9)

        if args.debug_png:
            comp.save(os.path.join(args.outdir, f"{prefix}-{size_tag}-{args.product}.png"), format="PNG")

        print(f"OK: {out_bmp_z} (stations used: {len(pts)})")

    if args.base_day:
        render_variant("map-D", args.base_day)
    if args.base_night:
        render_variant("map-N", args.base_night)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

