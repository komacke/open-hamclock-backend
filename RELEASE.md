# Open HamClock Backend (OHB) Release Process

This document describes how to build images locally for development/testing and how to trigger and monitor releases via GitHub Actions using the GitHub CLI (`gh`).

---

## 1. Local Development & Testing ("edge" Image)

For local development and testing, you can build a local Docker image tagged with `edge`:

```bash
# From the repository root:
./docker/build-image.sh

# Or from inside the docker/ directory:
cd docker && ./build-image.sh
```

- When not on a Git tag, the script automatically falls back to the `edge` tag and builds `komacke/open-hamclock-backend:edge`.
- **Maps Download**: The build script automatically downloads the pre-packaged offline maps archive (`ohb-maps.tar.zst`) from GitHub Releases if it is not already present locally.
- **Options & Environment Variables**:
  - `-n`: Build with `--no-cache`.
  - `-m`: Multi-platform build (`linux/amd64`, `linux/arm64`) using Buildx and pushes to Docker Hub.
  - `FORCE=true`: Bypass the uncommitted local edits check during local builds (GitHub Actions automatically bypasses this via `CI=true`).
  - `TAG`: Override the image tag manually (e.g., `TAG=test-build ./docker/build-image.sh`).

---

## 2. Tag Naming Convention

This repository uses Semantic Versioning with a `v` prefix (e.g., `v2.0.15`, `v2.1.0`).
- **Always include the `v` prefix** (use `v2.0.15`, not `2.0.15`).
- The build script checks for tags matching `^v[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$` and automatically tags them with `:latest` on Docker Hub in addition to the version tag.

---

## 3. Release Assets

When a release is created by the GitHub Actions workflow, the following assets are automatically generated, stamped with the release tag, and attached to the GitHub Release:

| Asset | Description |
|---|---|
| `manage-ohb-docker-vX.Y.Z.sh` | Installer and container manager script with `OHB_MANAGER_VERSION` stamped to this release. |
| `verify_firmware_integrity-vX.Y.Z.pl` | Perl firmware verification utility with `$VERSION` stamped. |
| `OHB-vX.Y.Z.tar.gz` | Clean source code tarball generated via `git archive`. |
| `OHB-vX.Y.Z.zip` | Clean source code zip archive generated via `git archive`. |
| `CHECKSUMS` | SHA-256 checksums of all release assets. |

---

## 4. Triggering a Release via GitHub CLI (`gh`)

### Prerequisites

Ensure the GitHub CLI is authenticated:

```bash
gh auth status
```

### Triggering the Release Workflow

Trigger the release workflow manually using `workflow_dispatch`:

```bash
# Trigger release build for version v2.0.16:
gh workflow run release.yml -f tag_name=v2.0.16

# Optional: create as a draft release:
gh workflow run release.yml -f tag_name=v2.0.16 -f draft=true

# Optional: skip Docker Hub image build/push:
gh workflow run release.yml -f tag_name=v2.0.16 -f build_docker=false

# Optional: draft release without Docker build:
gh workflow run release.yml -f tag_name=v2.0.16 -f draft=true -f build_docker=false

# Interactive mode (prompts for inputs):
gh workflow run
```

#### Workflow Inputs (`workflow_dispatch`)

| Input | Type | Default | Description |
|---|---|---|---|
| `tag_name` | string | `v0.0.0` | Version tag to release (e.g., `v2.0.16`). |
| `draft` | boolean | `false` | When `true`, creates the GitHub Release as a draft. |
| `build_docker` | boolean | `true` | When `true`, builds and pushes the multi-platform Docker image. |

Alternatively, pushing a signed git tag matching `v*` will trigger the workflow automatically:

```bash
git tag -s v2.0.16 -m "Release v2.0.16"
git push origin v2.0.16
```

---

## 5. Monitoring the Workflow

```bash
# Watch the latest workflow run in real time:
gh run watch

# List recent runs for the release workflow:
gh run list --workflow=release.yml -L 5

# View run details or logs:
gh run view <RUN_ID>
gh run view <RUN_ID> --log
gh run view <RUN_ID> --log-failed
```

---

## 6. Required Repository Secrets

The Docker build job requires the following GitHub repository secrets:

| Secret Name | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username (e.g., `komacke`) |
| `DOCKERHUB_TOKEN` | Docker Hub Personal Access Token (PAT) with write permissions |

---

## 7. Verified Commits & Tags (SSH Signing Keys)

If your local git environment is configured to sign commits or tags with SSH (`commit.gpgsign=true` / `tag.gpgsign=true`), GitHub requires that your public key be registered specifically as a **Signing Key** (rather than only an Authentication Key):

1. Check your public key:
   ```bash
   cat ~/.ssh/git-signing.pub
   ```
2. Go to **GitHub Settings -> [SSH and GPG keys](https://github.com/settings/keys)**.
3. Click **New SSH Key**.
4. In the **Key type** dropdown, select **Signing Key**.
5. Paste your public key and save.

*(Alternatively, run `gh auth refresh -h github.com -s admin:ssh_signing_key` and then `gh ssh-key add ~/.ssh/git-signing.pub --type signing`)*.

Once added as a signing key, GitHub will mark your releases, tags, and commits with the green **Verified** badge.

---

## 8. License

Copyright (C) 2026 Open HamClock Backend (OHB) Contributors

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the [GNU Affero General Public License](LICENSE) for more details.

You should have received a copy of the GNU Affero General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
