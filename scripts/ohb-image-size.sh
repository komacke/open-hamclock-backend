#!/usr/bin/env bash
# ohb-resize.sh — Update the OHB map size configuration
set -euo pipefail

CONF="/opt/hamclock-backend/etc/ohb-sizes.conf"
BASE="/opt/hamclock-backend"

# ---------- colors ----------
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

# ---------- helpers ----------
is_size() { [[ "$1" =~ ^[0-9]+x[0-9]+$ ]]; }

usage() {
  echo "Usage: $0 --size WxH [--size WxH ...] | --sizes WxH,WxH,..."
  echo ""
  echo "  --size   WxH       One size (repeatable)"
  echo "  --sizes  WxH,...   Comma-separated list of sizes"
  echo "  --show             Show the current configuration and exit"
  echo "  -h, --help         Show this help"
  echo ""
  echo "Examples:"
  echo "  $0 --size 660x330 --size 1320x660"
  echo "  $0 --sizes \"660x330,1320x660,1980x990\""
}

# ---------- show current ----------
show_current() {
  if [[ -f "$CONF" ]]; then
    local current
    current=$(grep '^OHB_SIZES=' "$CONF" | cut -d'"' -f2)
    echo -e "${BLU}Current OHB_SIZES:${NC} $current"
  else
    echo -e "${YEL}No config found at $CONF${NC}"
  fi
}

# ---------- no args ----------
if [[ $# -eq 0 ]]; then
  echo -e "${RED}ERROR: no arguments provided.${NC}"
  echo ""
  show_current
  echo ""
  usage
  exit 1
fi

# ---------- parse args ----------
OHB_SIZES=""
_SIZES_SET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)
      show_current; exit 0;;
    --sizes)
      shift; [[ $# -gt 0 ]] || { echo -e "${RED}ERROR: --sizes requires a value${NC}"; exit 1; }
      OHB_SIZES="$1"; shift;;
    --size)
      shift; [[ $# -gt 0 ]] || { echo -e "${RED}ERROR: --size requires a value${NC}"; exit 1; }
      if [[ -z "$_SIZES_SET" ]]; then _SIZES_SET=1; OHB_SIZES=""; fi
      OHB_SIZES+="${OHB_SIZES:+,}$1"; shift;;
    -h|--help) usage; exit 0;;
    *) echo -e "${RED}ERROR: unknown argument: $1${NC}"; usage; exit 1;;
  esac
done

# ---------- normalize + validate + dedupe ----------
OHB_SIZES="${OHB_SIZES//[[:space:]]/}"
IFS=',' read -r -a _tmp_sizes <<< "$OHB_SIZES"
declare -A _seen=()
_norm_sizes=()
for s in "${_tmp_sizes[@]}"; do
  [[ -n "$s" ]] || continue
  is_size "$s" || { echo -e "${RED}ERROR: invalid size '$s' (expected WxH e.g. 660x330)${NC}"; exit 1; }
  if [[ -z "${_seen[$s]:-}" ]]; then _seen[$s]=1; _norm_sizes+=("$s"); fi
done

[[ ${#_norm_sizes[@]} -gt 0 ]] || { echo -e "${RED}ERROR: empty size list${NC}"; exit 1; }
OHB_SIZES="$(IFS=','; echo "${_norm_sizes[*]}")"

if [[ "$OHB_SIZES" != *"660x330"* ]]; then
  echo -e "${YEL}WARN: size list does not include 660x330; some maps are tuned around that baseline.${NC}" >&2
fi

# ---------- show before/after ----------
echo ""
show_current
echo -e "${BLU}New OHB_SIZES:    ${NC} $OHB_SIZES"
echo ""

# ---------- confirm ----------
read -rp "$(echo -e "${YEL}Apply this change? [y/N]: ${NC}")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo -e "${YEL}Aborted. No changes made.${NC}"
  exit 0
fi

# ---------- write config ----------
if [[ ! -f "$CONF" ]]; then
  echo -e "${RED}ERROR: config file not found at $CONF${NC}"
  echo -e "${YEL}Has install_ohb.sh been run?${NC}"
  exit 1
fi

sudo sed -i "s|^OHB_SIZES=.*|OHB_SIZES=\"$OHB_SIZES\"|" "$CONF"
sudo chown www-data:www-data "$CONF"

echo -e "${GRN}[✓] Config updated: $CONF${NC}"
echo ""

# ---------- reload cron to pick up new sizes ----------
echo -e "${BLU}==> Restarting cron to apply new sizes...${NC}"
sudo systemctl restart cron
echo -e "${GRN}[✓] Cron restarted.${NC}"
echo ""

# ---------- verify ----------
echo -e "${BLU}==> Verified config:${NC}"
cat "$CONF"
echo ""
echo -e "${YEL}Note: map scripts run on their cron schedule and will use the new sizes automatically.${NC}"
echo -e "${YEL}To regenerate maps immediately, run: sudo -u www-data bash $BASE/scripts/update_cloud_maps.sh${NC}"
