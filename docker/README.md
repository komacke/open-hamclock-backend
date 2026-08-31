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

# Run OHB in a docker container

We always recommend using one of the cloud-based backends. There is load created on the many services hamclock uses to populate it's data. The OHB caches that data and serves it up to the many hamclock deployments.

But if you want to run your own OHB (for example you are an early adopter and don't want to wait for the cloud-based backends to be deployed), then install your own OHB.

OHB is supported exclusively as a containerized deployment using the `manage-ohb-docker.sh` management script. This ensures all microservices (VOACAP, PSKReporter cache, WSPR live cache) and system dependencies run reliably without conflicting with your host distribution.

You haven't used docker before? Now's your chance! It's not hard and it's great experience.

## What's a docker deployment?

To get OHB to run in docker on your machine, you'll need to:
- install docker on your machine (some distributions like Ubuntu 24.04 install very old docker so you might need to set up the docker repository)
- get the OHB manager for docker
- launch the docker container using the OHB manager

## Where are the docker images?

We maintain docker images for the releases in Docker Hub. When you launch your container it will automatically pull the image from Docker Hub. If you built the image yourself (with the build scripts), it will use yours.

The build scripts let you create your own image. You might want to do this if you want to run bleeding edge code. Or maybe you just want to host your own.

## Install docker
We'll consider installing docker a little outside the scope of this readme. It can be os dependent so look up instructions for your distribution.

The main consideration is that you have a recent version and you have docker compose installed.

At the time of this writing my docker and docker compose versions are:
```
$ docker -v
Docker version 29.2.0, build 1.fc43
$ docker compose version
Docker Compose version 5.0.2
```

Your version could be a little bit older. However a clue that your version is very old (too old!) is, for example, docker compose version in the 1.x range.

Be sure you have a recent docker and docker compose installed before proceeding.

## Install jq
Some Linux distributions install jq by default and some don't. We'll need this command, also.

Check if it's installed:
```
jq --version
```
Most any version should be fine. If not installed, use your distribution's package manager to install it.

# Install OHB with official images
## The steps if I want to use the official image from Docker Hub

Either get the source tree from GitHub or download the manage-ohb-docker.sh script. Getting the source tree is only necessary if you plan to build your own custom image, which is covered down below.

### option 1: download the manager:
You can query GitHub for the latest release tag and download the manager script in a single copy/paste block:
```bash
TAG=$(curl -sL https://api.github.com/repos/openhamclock/open-hamclock-backend/releases/latest | jq -r .tag_name)
curl -sL -o manage-ohb-docker.sh "https://github.com/openhamclock/open-hamclock-backend/releases/download/${TAG}/manage-ohb-docker-${TAG}.sh"
chmod +x manage-ohb-docker.sh
```

### option 2: get the GitHub source tree
The git clone command below should have the right URL but you can check it by visiting https://github.com/openhamclock/open-hamclock-backend, click on the green "Code" button and copy the https url.

On your computer, clone the repository:
```
git clone https://github.com/openhamclock/open-hamclock-backend.git
```

Go into the project's docker directory:
```
cd open-hamclock-backend/docker
```

Ensure you are on the release you want to build. For example:
```
git fetch
git tag # lists the available tags
git checkout v2.0.15
```

## Run the manager
Check out options with help:
```
# the help outputs options
./manage-ohb-docker.sh help
```

Double check your docker version:
```
./manage-ohb-docker.sh check-docker
```

Do an install. Note that if you are running it from a git checkout, it will use the git tag or branch name. If you are running it standalone you should provide it the tag you want to install. It defaults to ```edge```:

```
# put in the version you want or set to 'edge'
./manage-ohb-docker.sh install -t <insert version here>
```

When the script is done, you should have a running install of OHB! Try this:
```
# insert your ip address:
curl -s http://127.0.0.1/ham/HamClock/version.pl
```

If it's the first time you've run it, it can take a while to populate the data. Nearly all of the current data should be ready in around 60 minutes depending on internet speed. In some cases history has to accumulate for all the graphs to look right which could take days. But while you wait days, you'll have a fully functioning hamclock with your own custom OHB.

You can track the data seeding process like this:
```
# ^C to get out
docker logs -f open-hamclock-backend
```


## Point your hamclock to your new back end

Go to the project readme and look for information about the '-b' otion to hamclock. This will make your hamclock pull its data from your OHB.

# Install OHB with your own image
## The steps if you want to create your own image
You'll need a git checkout of the version you want to build. See above for getting a git clone and checkout.

The build-image.sh utility will create an image for you based on the git branch you have checked out. If you aren't on a git tag, the resulting image will be tagged 'edge':
```
./build-image.sh
```

# Upgrades
Upgrading OHB is easy.

Check your manager version:
```bash
./manage-ohb-docker.sh version
```

First, self-upgrade the manager utility:
```bash
./manage-ohb-docker.sh upgrade-me
```

If it shows the latest version at the end, then use it to upgrade OHB:
```bash
./manage-ohb-docker.sh upgrade
```

The data is persisted in the storage space you created in the first install. It will persist across your upgrade. If there are new features, possibly those could take a while to populate. It just depends on the feature.

# Your hamclock
Ok, so you have a back end. But does your hamclock know about it? Go to the project readme and look for information about the '-b' otion to hamclock.


# API Keys
OHB supports optional API keys for external services (see `.env.example`):
- `OPEN_WEATHER_API_KEY`: for api.openweathermap.org (HamClock falls back to open-meteo.com if not provided)
- `IPGEOLOC_API_KEY`: for app.ipgeolocation.io (initial location lookup for new HamClock setups)
- `TIMEZONEDB_API_KEY`: for api.timezonedb.com (computes DST and timezone info)
- `CQGMA_API_KEY`: for WWFF spots from cqgma.org
- `FIRMS_MAP_KEY`: for NASA FIRMS active fire map resources

If you have these keys, you can provide them to OHB by creating a file named `.env` in the directory where you run `manage-ohb-docker.sh`:
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
Replace \<insert key here\> with your respective key.

Upon a fresh install or upgrade, the file will be used automatically. To add the keys to an existing install use the add-env-file command:
```
./manage-ohb-docker.sh add-env-file
./manage-ohb-docker.sh restart
```
