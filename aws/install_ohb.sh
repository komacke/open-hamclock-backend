#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/BrianWilkinsFL/open-hamclock-backend.git"
BASE="/opt/hamclock-backend"
VENV="$BASE/venv"

# ---------- colors ----------
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

# ---------- spinner ----------
spinner() {
  local pid=$1
  local spin='-\|/'
  local i=0
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r${YEL}[%c] Working...${NC}" "${spin:$i:1}"
    sleep .1
  done
  printf "\r${GRN}[✓] Done           ${NC}\n"
}

# ---------- progress ----------
progress() {
  local step=$1
  local total=$2
  local pct=$(( step * 100 / total ))
  printf "${BLU}[%-50s] %d%%${NC}\n" "$(printf '#%.0s' $(seq 1 $((pct/2))))" "$pct"
}

clear

cat <<'EOF'

   ██████╗ ██╗  ██╗██████╗
  ██╔═══██╗██║  ██║██╔══██╗
  ██║   ██║███████║██████╔╝
  ██║   ██║██╔══██║██╔══██╗
  ╚██████╔╝██║  ██║██████╔╝
   ╚═════╝ ╚═╝  ╚═╝╚═════╝

   OPEN HAMCLOCK BACKEND
          (OHB)

EOF

echo -e "${GRN}RF • Space • Propagation • Maps${NC}"
echo

STEPS=8
STEP=0

# ---------- sanity ----------
if ! command -v systemctl >/dev/null; then
  echo -e "${RED}ERROR: systemd required (enable in WSL2)${NC}"
  exit 1
fi

# ---------- packages ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Installing packages${NC}"

sudo apt-get update >/dev/null &
spinner $!

sudo apt-get install -y \
git jq curl perl lighttpd imagemagick \
libwww-perl libjson-perl libxml-rss-perl libxml-feed-perl libhtml-parser-perl \
libeccodes-dev libpng-dev libtext-csv-xs-perl librsvg2-bin ffmpeg \
python3 python3-venv python3-dev build-essential gfortran gcc make libc6-dev \
libx11-dev libxaw7-dev libxmu-dev libxt-dev libmotif-dev wget >/dev/null &
spinner $!

# ---------- forced redeploy ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Fetching OHB (forced redeploy)${NC}"

sudo mkdir -p "$BASE"

if [ -d "$BASE/.git" ]; then
  sudo git -C "$BASE" reset --hard HEAD >/dev/null
  sudo git -C "$BASE" clean -fd >/dev/null
  sudo git -C "$BASE" pull >/dev/null &
  spinner $!
else
  sudo rm -rf "$BASE"/*
  sudo git clone "$REPO" "$BASE" >/dev/null &
  spinner $!
fi

# git housekeeping
sudo rm -f "$BASE/.git/gc.log" || true
sudo git -C "$BASE" prune >/dev/null || true
sudo git -C "$BASE" gc --prune=now >/dev/null || true

sudo chown -R www-data:www-data "$BASE"

# ---------- python venv ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Creating Python virtualenv${NC}"

sudo -u www-data mkdir -p "$BASE/tmp/pip-cache"

sudo -u www-data env HOME="$BASE/tmp" XDG_CACHE_HOME="$BASE/tmp" PIP_CACHE_DIR="$BASE/tmp/pip-cache" \
python3 -m venv "$VENV"

sudo -u www-data env HOME="$BASE/tmp" XDG_CACHE_HOME="$BASE/tmp" PIP_CACHE_DIR="$BASE/tmp/pip-cache" \
"$VENV/bin/pip" install --upgrade pip

sudo -u www-data env HOME="$BASE/tmp" XDG_CACHE_HOME="$BASE/tmp" PIP_CACHE_DIR="$BASE/tmp/pip-cache" \
"$VENV/bin/pip" install numpy pygrib matplotlib >/dev/null &
spinner $!

# ---------- relocate ham ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Relocating ham content into htdocs${NC}"

sudo mkdir -p "$BASE/htdocs"

if [ -d "$BASE/ham" ]; then
  sudo rm -rf "$BASE/htdocs/ham"
  sudo mv "$BASE/ham" "$BASE/htdocs/"
fi

sudo chown -R www-data:www-data "$BASE"

# ---------- dirs ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Creating directories${NC}"

sudo mkdir -p \
 "$BASE/tmp" \
 "$BASE/logs" \
 "$BASE/cache" \
 "$BASE/data" \
 "$BASE/htdocs/ham/HamClock"

sudo chown -R www-data:www-data "$BASE"

# ---------- lighttpd ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Configuring lighttpd${NC}"

sudo ln -sf "$BASE/50-hamclock.conf" /etc/lighttpd/conf-enabled/50-hamclock.conf
sudo lighttpd -t -f /etc/lighttpd/lighttpd.conf
sudo systemctl daemon-reload
sudo systemctl restart lighttpd

# ---------- cron ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Installing www-data crontab${NC}"

sudo chmod 644 "$BASE/scripts/crontab"
sudo -u www-data crontab "$BASE/scripts/crontab"
sudo systemctl restart cron

# ---------- initial gen ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Initial artifact generation${NC}"

sudo chmod +x "$BASE/scripts/"*

#sudo -u www-data bash <<EOF
#cd "$BASE/scripts" || exit 1
#for f in gen_ssn.pl gen_kp.pl gen_aurora.pl update_all_sdo.sh; do
#  [ -f "\$f" ] && ./"\$f" || echo "Skipping \$f"
#done
#EOF

# ---------- initial pre-seed ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Initial backend pre-seed${NC}"

sudo mkdir -p "$BASE/logs"
sudo chown -R www-data:www-data "$BASE/logs"

echo "Pre-seed running as:"
sudo -u www-data id

seed_spinner() {
  local pid=$1
  local spin='-\|/'
  local i=0
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r${YEL}[%c] Working...${NC}" "${spin:$i:1}"
    sleep .1
  done
  printf "\r${GRN}[✓] Done           ${NC}\n"
}
run_perl() {
  local f=$1
  local log="$BASE/logs/${f%.pl}.log"
  echo -e "${YEL}Running perl $f${NC}"
  sudo -u www-data perl "$BASE/scripts/$f" >> "$log" 2>&1 &
  seed_spinner $!
}

run_sh() {
  local f=$1
  local log="$BASE/logs/${f%.sh}.log"
  echo -e "${YEL}Running bash $f${NC}"
  sudo -u www-data bash "$BASE/scripts/$f" >> "$log" 2>&1 &
  seed_spinner $!
}

run_flock_sh() {
  local f=$1
  local log="$BASE/logs/${f%.sh}.log"
  echo -e "${YEL}Running flocked $f${NC}"
  sudo -u www-data flock -n /tmp/update_sdo.lock bash "$BASE/scripts/$f" >> "$log" 2>&1 &
  seed_spinner $!
}


# ---- ordered execution ----

run_sh  gen_solarflux-history.sh
run_perl gen_swind_24hr.pl
run_perl gen_ssn.pl
run_sh  update_pota_parks_cache.sh
run_perl update_solarflux_cache.pl
run_sh  update_wx_mb_maps.sh
run_perl publish_solarflux_99.pl
run_perl gen_dxnews.pl
run_perl gen_ng3k.pl
run_perl merge_dxpeditions.pl
run_sh  gen_contest-calendar.sh
run_perl gen_kindex.pl
run_perl build_esats.pl
run_sh  update_cloud_maps.sh
run_sh  update_drap_maps.sh
run_sh  gen_dst.sh
run_sh  gen_aurora.sh
run_sh  gen_noaaswx.sh
run_sh  update_sdo_304.sh
run_sh  update_aurora_maps.sh
run_perl gen_onta.pl
run_sh  bzgen.sh
run_sh  gen_drap.sh
run_perl genxray.pl

# ---------- footer ----------
VERSION=$(git -C "$BASE" describe --tags --dirty --always 2>/dev/null || echo "unknown")
HOST=$(hostname)
IP=$(hostname -I | awk '{print $1}')

echo
echo -e "${GRN}===========================================${NC}"
echo -e "${GRN} OHB Version : ${VERSION}${NC}"
echo -e "${GRN} Hostname    : ${HOST}${NC}"
echo -e "${GRN} IP Address : ${IP}${NC}"
echo -e "${GRN} URL        : http://${IP}/ham/HamClock/${NC}"
echo -e "${GRN}===========================================${NC}"
echo
echo -e "${YEL}If using WSL2 ensure systemd=true in /etc/wsl.conf${NC}"
echo

