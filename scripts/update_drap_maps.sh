#!/usr/bin/env bash
set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
W=660
H=330

# NOAA SWPC DRAP global browse image
SRC_URL="https://services.swpc.noaa.gov/images/d-rap/global.png"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
need curl
need convert
need python3
need install

mkdir -p "$OUTDIR"

src_png="$TMPDIR/drap_global.png"
crop_png="$TMPDIR/drap_crop.png"
norm_png="$TMPDIR/drap_${W}x${H}.png"
raw_rgb="$TMPDIR/drap_${W}x${H}.rgb"

curl -fsS "$SRC_URL" -o "$src_png"

# --- Hard crop to map-only interior ------------------------------------------
# Measured in ImageMagick display:
#   bottom-right corner of map interior = +543,+266
# Therefore crop from top-left +0+0 with:
#   width  = 543+1 = 544
#   height = 266+1 = 267
convert "$src_png" -crop "660x330+0+0" +repage "$crop_png"

# --- Resize to HamClock map dimensions ---------------------------------------
convert "$crop_png" -resize "${W}x${H}!" "$norm_png"

# --- Emit raw RGB888 bytes (W*H*3) -------------------------------------------
# Produces a top-down raster: RGBRGB...
convert "$norm_png" -alpha off -colorspace sRGB -depth 8 "rgb:$raw_rgb"

# --- Write BMP V4 RGB565 exactly as HamClock expects -------------------------
# Forces:
#   - BITMAPV4HEADER (108 bytes), bfOffBits=122
#   - 16bpp RGB565, BI_BITFIELDS, masks f800/07e0/001f
#   - negative height (top-down)
make_bmp_v4_rgb565_topdown() {
  local inraw="$1"
  local outbmp="$2"

  python3 - <<'PY' "$inraw" "$outbmp" "$W" "$H"
import struct, sys

inraw, outbmp, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

raw = open(inraw, "rb").read()
exp = W*H*3
if len(raw) != exp:
    raise SystemExit(f"RAW size {len(raw)} != expected {exp}")

# Pack RGB888 -> RGB565 little-endian, in top-down order
pix = bytearray(W*H*2)
j = 0
for i in range(0, len(raw), 3):
    r = raw[i]
    g = raw[i+1]
    b = raw[i+2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    pix[j:j+2] = struct.pack("<H", v)
    j += 2

# BITMAPFILEHEADER (14 bytes)
bfType = b"BM"
bfOffBits = 14 + 108  # 122
bfSize = bfOffBits + len(pix)
filehdr = struct.pack("<2sIHHI", bfType, bfSize, 0, 0, bfOffBits)

# BITMAPV4HEADER (108 bytes)
biSize = 108
biWidth = W
biHeight = -H              # NEGATIVE = top-down
biPlanes = 1
biBitCount = 16
biCompression = 3          # BI_BITFIELDS
biSizeImage = len(pix)

# RGB565 masks
bV4RedMask   = 0xF800
bV4GreenMask = 0x07E0
bV4BlueMask  = 0x001F
bV4AlphaMask = 0x0000

# 'sRGB' color space type (optional)
bV4CSType = 0x73524742      # 'sRGB'

endpoints = b"\x00" * 36
gamma = b"\x00" * 12

v4hdr = struct.pack(
    "<IiiHHIIIIII",
    biSize, biWidth, biHeight, biPlanes, biBitCount, biCompression,
    biSizeImage, 0, 0, 0, 0
) + struct.pack("<IIII", bV4RedMask, bV4GreenMask, bV4BlueMask, bV4AlphaMask) \
  + struct.pack("<I", bV4CSType) + endpoints + gamma

if len(v4hdr) != 108:
    raise SystemExit(f"V4 header length {len(v4hdr)} != 108")

with open(outbmp, "wb") as f:
    f.write(filehdr)
    f.write(v4hdr)
    f.write(pix)

# Validate key header fields (must match mapmanage expectations)
with open(outbmp, "rb") as f:
    if f.read(2) != b"BM":
        raise SystemExit("BAD: signature")
    f.seek(2); fsize = struct.unpack("<I", f.read(4))[0]
    f.seek(10); off = struct.unpack("<I", f.read(4))[0]
    f.seek(14); dib = struct.unpack("<I", f.read(4))[0]
    w = struct.unpack("<i", f.read(4))[0]
    h = struct.unpack("<i", f.read(4))[0]
    planes = struct.unpack("<H", f.read(2))[0]
    bpp = struct.unpack("<H", f.read(2))[0]
    comp = struct.unpack("<I", f.read(4))[0]
    f.seek(14+40); r,g,b = struct.unpack("<III", f.read(12))

exp_size = 122 + W*H*2
errs = []
if off != 122: errs.append(f"bfOffBits={off}")
if dib != 108: errs.append(f"DIB={dib}")
if w != W or h != -H: errs.append(f"W,H={w},{h}")
if planes != 1: errs.append(f"planes={planes}")
if bpp != 16: errs.append(f"bpp={bpp}")
if comp != 3: errs.append(f"comp={comp}")
if (r,g,b) != (0xF800,0x07E0,0x001F): errs.append(f"masks={hex(r)},{hex(g)},{hex(b)}")
if fsize != exp_size: errs.append(f"size={fsize} expected={exp_size}")

if errs:
    raise SystemExit("BAD BMP:\n  " + "\n  ".join(errs))

print("OK BMP V4 RGB565 top-down")
PY
}

day_tmp="$TMPDIR/map-D-${W}x${H}-DRAP-S.bmp"
night_tmp="$TMPDIR/map-N-${W}x${H}-DRAP-S.bmp"

make_bmp_v4_rgb565_topdown "$raw_rgb" "$day_tmp"
cp -f "$day_tmp" "$night_tmp"   # Keep N identical unless you later apply a terminator mask.

install -m 0644 "$day_tmp"   "$OUTDIR/map-D-${W}x${H}-DRAP-S.bmp"
install -m 0644 "$night_tmp" "$OUTDIR/map-N-${W}x${H}-DRAP-S.bmp"

# --- Raw zlib compression to .bmp.z (NOT gzip) -------------------------------
zlib_compress() {
  python3 -c '
import zlib, sys
data=open(sys.argv[1],"rb").read()
open(sys.argv[2],"wb").write(zlib.compress(data,9))
' "$1" "$2"
}

zlib_compress "$OUTDIR/map-D-${W}x${H}-DRAP-S.bmp" "$OUTDIR/map-D-${W}x${H}-DRAP-S.bmp.z"
zlib_compress "$OUTDIR/map-N-${W}x${H}-DRAP-S.bmp" "$OUTDIR/map-N-${W}x${H}-DRAP-S.bmp.z"

