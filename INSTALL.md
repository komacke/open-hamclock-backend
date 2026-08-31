<!--
  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU Affero General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU Affero General Public License for more details.

  You should have received a copy of the GNU Affero General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
-->

## Overview

OHB is distributed and deployed as a Docker container. The only supported installation method is via Docker using the `manage-ohb-docker.sh` management script. This ensures all dependencies and supporting microservices (VOACAP service, PSKReporter/MQTT cache, and WSPR live cache) are cleanly managed and isolated.

## Prerequisites

- **Docker and Docker Compose**: Ensure you have a recent version installed. In particular, Docker Compose must be v2+ (verified with `docker compose version`), rather than legacy 1.x (`docker-compose`).
- **jq**: Command-line JSON processor used by the management script to query releases. Install via your package manager if not present (`apt install jq`, `dnf install jq`, etc.).

Verify your prerequisites:
```bash
docker -v
docker compose version
jq --version
```

## Installation

### Step 1: Download the Manager Script

You can download the standalone manager script from GitHub Releases or from a repository clone:

**Option A: Download standalone script**
Query GitHub for the latest release tag and download the manager script in a single copy/paste block:

```bash
TAG=$(curl -sL https://api.github.com/repos/openhamclock/open-hamclock-backend/releases/latest | jq -r .tag_name)
curl -sL -o manage-ohb-docker.sh "https://github.com/openhamclock/open-hamclock-backend/releases/download/${TAG}/manage-ohb-docker-${TAG}.sh"
chmod +x manage-ohb-docker.sh
```

**Option B: From git repository**
```bash
git clone https://github.com/openhamclock/open-hamclock-backend.git
cd open-hamclock-backend/docker
chmod +x manage-ohb-docker.sh
```

### Step 2: Run the Install

Verify Docker environment using the script:
```bash
./manage-ohb-docker.sh check-docker
```

Run the installation:
```bash
./manage-ohb-docker.sh install
```

To install a specific version tag instead of `edge` or latest, pass the `-t` option:
```bash
./manage-ohb-docker.sh install -t v2.0.15
```

When installation completes, OHB will be running. Verify the endpoint:
```bash
curl -s http://127.0.0.1/ham/HamClock/version.pl
```

### Initial Data Seeding
When started for the first time, OHB begins populating its cache and data feeds immediately. Nearly all current data will be ready within ~60 minutes, though historical graphs will accumulate over days. You can monitor the data seeding process in real time:
```bash
docker logs -f open-hamclock-backend
```

## Selecting map image sizes during install

By default, OHB supports `all` map sizes. You can limit the map resolutions generated to save CPU and RAM on resource-constrained devices (e.g., Raspberry Pi) using the `-r` option:

> [!WARNING]
> Generating maps for all resolutions on low-power devices like a Raspberry Pi 3B+ can cause high CPU load or overheating. Consider selecting a specific resolution matching your screen.

Supported resolutions for `-r`: `all`, `1600x960`, `3200x1920`, `2400x1440`, `800x480`.

Example installing with a single resolution:
```bash
./manage-ohb-docker.sh install -r 1600x960
```

## Upgrades

Upgrading OHB is a simple two-step process:

1. **First, upgrade the manager script** itself using `upgrade-me` to ensure you have the latest tooling and release definitions:
   ```bash
   ./manage-ohb-docker.sh upgrade-me
   ```
2. **Then, upgrade the OHB container** using `upgrade`:
   ```bash
   ./manage-ohb-docker.sh upgrade
   ```

Your persistent data (cached feeds, history, logs) is preserved across upgrades in Docker volumes.

## Starting HamClock with OHB Install

HamClock is hard-coded to use clearskyinstitute.com. Point HamClock to your new backend using the `-b` option when starting HamClock:

### Localhost (if running OHB on the same host as the HamClock client)
```bash
hamclock -b localhost:80
```

### Central Server
```bash
hamclock -b <central-server-ip-or-host>:80
```

## Managing OHB (Start, Stop, Restart)

Use `manage-ohb-docker.sh` to control the container lifecycle:

```bash
# Stop OHB:
./manage-ohb-docker.sh down

# Start OHB:
./manage-ohb-docker.sh up

# Restart OHB:
./manage-ohb-docker.sh restart

# Check installation status and versions:
./manage-ohb-docker.sh check-ohb-install

# Follow logs in real time:
docker logs -f open-hamclock-backend
```

## API Keys

OHB supports several optional external API keys to enhance data feeds (see `.env.example`):

- **OpenWeatherMap** (`OPEN_WEATHER_API_KEY`): Weather data for the world weather display and map hover. If not provided, HamClock falls back to Open-Meteo.
- **IPGeolocation** (`IPGEOLOC_API_KEY`): Automatic location lookup for new HamClock client setups.
- **TimeZoneDB** (`TIMEZONEDB_API_KEY`): Computes DST and timezone information.
- **CQGMA** (`CQGMA_API_KEY`): Pulls WWFF spots directly from cqgma.org.
- **NASA FIRMS** (`FIRMS_MAP_KEY`): Active fire satellite resources for map overlays.

To supply API keys, create a `.env` file in the directory where you run `manage-ohb-docker.sh`:

```
# for the api.openweathermap.org API
OPEN_WEATHER_API_KEY=<insert key here>

# for the app.ipgeolocation.io API
IPGEOLOC_API_KEY=<insert key here>

# for api.timezonedb.com which computes DST
TIMEZONEDB_API_KEY=<insert key here>

# for WWFF spots that are pulled from cqgma.org
CQGMA_API_KEY=<insert key here>

# for FIRMS fire resources
FIRMS_MAP_KEY=<insert key here>
```

Inject the keys into the running container and restart:
```bash
./manage-ohb-docker.sh add-env-file
./manage-ohb-docker.sh restart
```

## Custom Image Builds

To build your own Docker images locally (for testing or development) rather than pulling official images from Docker Hub, see [RELEASE.md](RELEASE.md).
