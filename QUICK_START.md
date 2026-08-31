## 🚀 Quick Start

OHB is distributed and deployed as a Docker container. The only supported installation method is via Docker using the `manage-ohb-docker.sh` management script.

### Install with Docker

Download the manager utility that masks all the Docker details. Visit the releases page:

👉 [Releases](https://github.com/openhamclock/open-hamclock-backend/releases/latest)
and download the asset: **Manage Docker installs** (`manage-ohb-docker-<version>.sh`), or query the latest release tag and download directly in a single block:

```bash
TAG=$(curl -sL https://api.github.com/repos/openhamclock/open-hamclock-backend/releases/latest | jq -r .tag_name)
curl -sL -o manage-ohb-docker.sh "https://github.com/openhamclock/open-hamclock-backend/releases/download/${TAG}/manage-ohb-docker-${TAG}.sh"
chmod +x manage-ohb-docker.sh
```

Run the install command:
```bash
./manage-ohb-docker.sh install
```
*(To install a specific version, pass `-t <version>`, e.g., `./manage-ohb-docker.sh install -t v2.0.15`)*.

### Upgrading OHB

Upgrading is a two-step process:

1. First, upgrade the manager script itself:
```bash
./manage-ohb-docker.sh upgrade-me
```

2. Then, upgrade the OHB container:
```bash
./manage-ohb-docker.sh upgrade
```

### Verify Installation

Verify the endpoint and core feeds:

```bash
curl -s http://127.0.0.1/ham/HamClock/version.pl
curl -s http://127.0.0.1/ham/HamClock/solarflux/solarflux-history.txt | tail
curl -s http://127.0.0.1/ham/HamClock/geomag/kindex.txt | tail
```

If you see data, OHB is running.

### Detailed Instructions
- Full installation & configuration guide: 👉 [Detailed Installation Instructions](INSTALL.md)
- Custom image builds & release workflow: 👉 [Release Process Guide](RELEASE.md)
