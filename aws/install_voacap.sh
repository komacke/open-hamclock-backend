#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/hamclock-backend"
VENV="$BASE/venv"

echo "==> Downloading dvoacap-python..."
if [ ! -d "$BASE/dvoacap-python" ]; then
  sudo curl -fsSL \
    https://github.com/skyelaird/dvoacap-python/archive/refs/heads/main.tar.gz \
    | sudo tar -xz -C "$BASE"
  sudo mv "$BASE/dvoacap-python-main" "$BASE/dvoacap-python"
else
  echo "    already present, skipping"
fi

echo "==> Patching Python version constraint..."
sudo sed -i 's/requires-python = ">=3\.11"/requires-python = ">=3.10"/' \
  "$BASE/dvoacap-python/pyproject.toml"

echo "==> Installing dvoacap into venv..."
sudo "$VENV/bin/pip" install --quiet "$BASE/dvoacap-python"

echo "==> Creating voacap cache dir..."
sudo mkdir -p "$BASE/cache/voacap-cache"


echo "==> Fixing ownership..."
sudo chown -R www-data:www-data "$BASE/dvoacap-python"
sudo mkdir -p "$BASE/cache/voacap-cache"
sudo chown -R www-data:www-data "$BASE/cache/voacap-cache"
sudo chown www-data:www-data "$BASE/scripts/voacap_bandconditions.py"
sudo chown www-data:www-data "$BASE/htdocs/ham/HamClock/fetchBandConditions.pl"

echo "==> Verifying install..."
sudo -u www-data "$VENV/bin/python" -c "import dvoacap; print('    dvoacap OK')"
sudo -u www-data "$VENV/bin/python" "$BASE/scripts/voacap_bandconditions.py" \
  --year 2026 --month 1 --utc 14 \
  --txlat 28.154 --txlng -80.644 \
  --rxlat 37.7749 --rxlng -122.4194 \
  --path 0 --pow 100 --mode 19 --toa 3.0 --ssn 39 \
  --cache-dir "$BASE/tmp/voacap-cache" --cache-ttl 0 \
  && echo "    voacap_bandconditions.py OK"

echo "Done."
