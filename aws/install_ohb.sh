#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/BrianWilkinsFL/open-hamclock-backend.git"
BASE="/opt/hamclock-backend"

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

STEPS=6
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
jq \
perl \
lighttpd \
imagemagick \
libwww-perl \
libjson-perl \
libxml-rss-perl \
libxml-feed-perl \
libhtml-parser-perl \
libeccodes-dev \
libpng-dev \
libtext-csv-xs-perl \
librsvg2-bin \
ffmpeg \
python3 \
python3-pip \
python3-pyproj \
python3-dev \
build-essential \
gfortran \
gcc \
make \
libc6-dev \
libx11-dev \
libxaw7-dev \
libxmu-dev \
libxt-dev \
libmotif-dev \
wget >/dev/null &
spinner $!

# ---- pip AFTER apt ----

# ---------- python venv ----------
echo -e "${BLU}==> Creating Python virtualenv${NC}"

sudo apt-get install -y python3-venv >/dev/null

VENV=/opt/hamclock-backend/venv

sudo -u www-data python3 -m venv $VENV

sudo -u www-data $VENV/bin/pip install --upgrade pip

sudo -u www-data $VENV/bin/pip install \
numpy \
pygrib \
matplotlib >/dev/null &
spinner $!

# ---------- clone ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Fetching OHB${NC}"

if [ ! -d "$BASE" ]; then
  sudo git clone "$REPO" "$BASE" >/dev/null &
  spinner $!
else
  sudo git -C "$BASE" pull >/dev/null &
  spinner $!
fi

echo -e "${BLU}==> Relocating ham content into htdocs${NC}"

sudo mkdir -p $BASE/htdocs

if [ -d "$BASE/ham" ]; then
    sudo rm -rf $BASE/htdocs/ham
    sudo mv $BASE/ham $BASE/htdocs/
fi

sudo chown -R www-data:www-data "$BASE"

# ---------- dirs ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Creating directories${NC}"

sudo mkdir -p \
 /opt/hamclock-backend/tmp \
 /opt/hamclock-backend/logs \
 /opt/hamclock-backend/cache \
 /opt/hamclock-backend/data \
 /opt/hamclock-backend/htdocs/ham/HamClock

sudo chown -R www-data:www-data /opt/hamclock-backend

# ---------- lighttpd ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Configuring lighttpd${NC}"

sudo ln -sf \
 $BASE/50-hamclock.conf \
 /etc/lighttpd/conf-enabled/50-hamclock.conf

sudo systemctl restart lighttpd

# ---------- cron ----------
STEP=$((STEP+1)); progress $STEP $STEPS

echo -e "${BLU}==> Installing www-data crontab${NC}"

sudo chmod 644 $BASE/scripts/crontab

sudo -u www-data crontab $BASE/scripts/crontab

sudo systemctl restart cron

# ---------- initial gen ----------
STEP=$((STEP+1)); progress $STEP $STEPS
echo -e "${BLU}==> Initial artifact generation${NC}"

sudo chmod +x $BASE/scripts/*

sudo -u www-data bash <<EOF
cd $BASE/scripts || exit 1
for f in gen_ssn.pl gen_kp.pl gen_aurora.pl update_all_sdo.sh; do
  [ -f "\$f" ] && ./"\$f" || echo "Skipping \$f"
done
EOF

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
