# OHB - Open HamClock Backend
Open Source and Faithful HamClock Backend Replacement. This is a community project and no relation to the creator of HamClock Elwood Downey, WB0OEW, ecdowney@clearskyinstitute.com SK

I wish the Downey family my deepest condolences

This is a WIP.

## License
MIT

## Vision
The goal is to make this as a drop-in replacement for the HamClock backend by replicating the same client/server responses with Perl CGI scripting and static files. We don't have access to the backend server source code so this is completely created by looking at the interfaces. To allow existing HamClock's running on Arduino to continue to work, we will setup a local DNS sinkhole to redirect to your local backend running at your home or office. Or, the HamClock client may be modified to point to a new central server permanently or use the built-in -b option

## Interoperability
This project generates map and data artifacts in the same formats expected by the HamClock client (e.g. zlib compressed BMP RGB565 map tiles) to support interoperability. This project is not affiliated with or endorsed by the original HamClock project or any third party. Data products are derived from public upstream sources such as NOAA SWPC and NASA

## Compatibility
- [ ] Ubuntu 22.x LTS
- [ ] Raspberry Pi
- [ ] Windows Subsystem for Linux
- [ ] Inovato Quadro
- [ ] Mac 

## Project Completion Status

HamClock requests about 40+ artifacts. I have locally replicated all of them that I could find.

### Dynamic Text Files
- [x] Bz/Bz.txt
- [x] aurora/aurora.txt
- [x] xray/xray.txt
- [ ] worldwx/wx.txt
- [x] esats/esats.txt
- [x] solarflux/solarflux-history.txt
- [x] ssn/ssn-history.txt
- [x] solar-flux/solarflux-99.txt (this requires a local cache to be built up - I made a bootstrap script)
- [x] geomag/kindex.txt
- [x] dst/dst.txt
- [x] drap/stats.txt
- [x] solar-wind/swind-24hr.txt
- [x] ssn/ssn-31.txt
- [x] ONTA/onta.txt
- [ ] contests/contests311.txt (this may stay broken until an agreement is made based on the site's ToS https://www.contestcalendar.com/terms.php)
- [x] dxpeds/dxpeditions.txt
- [ ] NOAASpaceWX/noaaswx.txt

### Dynamic Map Files
- [x] maps/map-D-2640x1320-Countries.bmp.z - this is just a static map of the world, won't change often
- [x] maps/map-N-2640x1320-Countries.bmp.z - this is just a static map of the world, won't change often
- [x] maps/map-D-660x330-Clouds.bmp.z
- [x] maps/map-N-660x330-Clouds.bmp.z
- [x] maps/map-D-660x330-Terrain.bmp.z - this is just a static map of the world, won't change often
- [x] maps/map-N-660x330-Terrain.bmp.z - this just a static map of the world, won't change often
- [x] maps/map-D-660x330-DRAP-S.bmp.z
- [x] maps/map-N-660x330-DRAP-S.bmp.z
- [ ] maps/map-N-660x330-MUF-RT.bmp.z
- [ ] maps/map-D-660x330-MUF-RT.bmp.z
- [x] maps/map-D-660x330-Aurora.bmp.z
- [x] maps/map-N-660x330-Aurora.bmp.z
- [x] maps/map-D-660x330-Wx-mB.bmp.z
- [x] maps/map-N-660x330-Wx-mB.bmp.z
- [x] SDO/f_304_170.bmp.z
- [ ] SDO/f_211_193_171_170.bmp.z
- [ ] SDO/latest_170_HMIB.bmp.z

### Dynamic Web Endpoints
- [x] ham/HamClock/RSS/web15rss.pl
- [x] ham/HamClock/version.pl
- [x] ham/HamClock/wx.pl
- [x] ham/HamClock/fetchIPGeoloc.pl - requires free tier 1000 req per day account and API key
- [ ] ham/HamClock/fetchBandConditions.pl
- [ ] ham/HamClock/fetchVOACAPArea.pl
- [ ] ham/HamClock/fetchVOACAP-MUF.pl?YEAR=2026&MONTH=1&UTC=17&TXLAT=&TXLNG=&PATH=0&WATTS=100&WIDTH=660&HEIGHT=330&MHZ=0.00&TOA=3.0&MODE=19&TOA=3.0
- [ ] ham/HamClock/fetchVOACAP-TOA.pl?YEAR=2026&MONTH=1&UTC=17&TXLAT=&TXLNG=&PATH=0&WATTS=100&WIDTH=660&HEIGHT=330&MHZ=14.10&TOA=3.0&MODE=19&TOA=3.0
- [x] ham/HamClock/fetchPSKReporter.pl?ofgrid=XXYY&maxage=1800
- [ ] ham/HamClock/fetchWSPR.pl
- [ ] ham/HamClock/fetchRBN.pl

### Static Files
- [x] ham/HamClock/cities2.txt - static city file - no urgency to update this for maybe 5 years or more
- [x] ham/HamClock/cty/cty_wt_mod-ll-dxcc.txt - Country/prefix database with lat/lon
- [x] ham/HamClock/NOAASpaceWx/rank2_coeffs.txt

### Miscellaneous
- [x] zlib decompress utilty script
- [ ] VOACAP map generator

## Integration Testing Status
- [x] GOES-16 X-Ray Pane
- [x] Countries map
- [x] Terrain map
- [x] DRAP map
- [ ] MUF-RT sort of working - needs shrinking and cropping
- [x] Weather map
- [x] Clouds map
- [x] Aurora day
- [ ] Aurora night - not working
- [ ] ONTA - works, needs more de-duping; update 0.4 will have updated cache file and generation script
- [x] 304a solar image
- [ ] SSN data - invalid - fixed in next version. Need new script to test
- [x] Solar wind
- [ ] DRAP data - invalid
- [ ] Planetary k - invalid
- [x] Solar flux

## Image Notes
- SDO/f_304_170.bmp.z : This is a zlib compressed bitmap. It comes from here most likely: https://umbra.nascom.nasa.gov/images/latest.html and https://umbra.nascom.nasa.gov/images/latest_aia_304.gif
- maps/Clouds : ftp://public.sos.noaa.gov/rt/sat/linear/raw/
  
Decompressing the images for viewing can be done using $ zlib-flate -uncompress < filename.bmp.z > newfilename.bmp

Images with N means Night and D means Day

## Requirements and Install

### Dependency Install
- sudo apt install -y jq
- sudo apt install -y perl
- sudo apt install -y lighttpd
- sudo apt install -y imagemagick
- sudo apt install -y libwww-perl
- sudo apt install -y libjson-perl
- sudo apt install -y libxml-rss-perl
- sudo apt install -y libxml-feed-perl
- sudo apt install -y libhtml-parser-perl
- sudo apt install -y libeccodes-dev
- sudo apt install -y libg2c-dev
- sudo apt install -y libpng-dev
- sudo apt install -y libg2c-dev
- sudo apt install -y libeccodes-dev
- sudo apt install -y libtext-csv-xs-perl
- sudo apt install -y librsvg2-bin
- sudo apt install -y python3
- sudo apt install -y python3-pip
- sudo apt install -y python3-pyproj
- sudo apt install -y python3-dev
- sudo apt install -y build-essential gfortran gcc make libc6-dev \\\
libx11-dev libxaw7-dev libxmu-dev libxt-dev libmotif-dev wget (needed for VOACAPL)
- pip install numpy
- pip install pygrib
- pip install matplotlib
- sudo wget https://downloads.sourceforge.net/project/voacap/vocap/voacapl-0.7.6.tar.gz
  Note: VOACAPL install instructions in work

### Install:
```bash
  sudo tar xzf hamclock-backend.tar.gz -C /opt
  sudo chown -R www-data:www-data /opt/hamclock-backend
  sudo chmod +x /opt/hamclock-backend/htdocs/ham/HamClock/*.pl
  sudo cp 50-hamclock.conf /etc/lighttpd/conf-available/50-hamclock.conf

  # Update the server modules inside your lighttpd configuration file located at: /etc/lighttpd/lighttpd.conf
  # Only change should be the "mod_cgi" module at the end:
      server.modules = (
          "mod_indexfile",
          "mod_access",
          "mod_alias",
          "mod_redirect",
          "mod_cgi",
      )

  sudo lighttpd -tt -f /etc/lighttpd/lighttpd.conf
  sudo lighttpd-enable-mod hamclock
  sudo systemctl restart lighttpd
  # add crontab as user www-data and described in scripts/crontab
```

## Prerequisites

This backend is designed to be lightweight and portable. It relies on a standard web server with CGI support and a small set of Perl modules.

You will need:

- Perl 5.10 or newer
- `lighttpd` (recommended) or Apache httpd with CGI enabled
- Cron (for scheduled data generation)
  
## Testing

After install, you can verify any script is working by using sudo -u www-data /opt/hamclock/scripts/<scriptname> <optional-param>

Most cron-jobs will log to /opt/hamclock-backend/logs

## Automated Pulls
- Once per month: /opt/hamclock-backend/scripts/gen_solarflux-history.sh
- Once per day at 12:10am: /opt/hamclock-backend/scripts/gen_swind_24hr.pl
- Once per day at 12:15am: /opt/hamclock-backend/scripts/update_solarflux_cache.pl
- Once per day at 12:20am: /opt/hamclock-backend/scripts/publish_solarflux_99.pl
- Once per dat at 12:25am: /opt/hamclock-backend/scripts/gen_dxnews.pl
- Once per day at 12:30am: /opt/hamclock-backend/scripts/gen_ng3k.pl
- Once per day at 12:35am: /opt/hamclock-backend/scripts/merge_dxpeditions.pl
- Every 12 hours: /opt/hamclock-backend/scripts/gen_kindex.pl
- Every 3 hours: /opt/hamclock-backend/scripts/build_esats.pl
- Every hour: /opt/hamclock-backend/scripts/update_clouds_maps.sh
- Every hour: /opt/hamclock-backend/scripts/update_drap_maps.sh
- Every hour: /opt/hamclock-backend/scripts/gen_dst.sh
- Every 30 minutes: /opt/hamclock-backend/scripts/gen_aurora.sh
- Every 5 minutes: /opt/hamclock-backend/scripts/gen_onta.pl
- Every 5 minutes: /opt/hamclock-backend/scripts/bzgen.sh
- Every 3 minutes: /opt/hamclock-backend/scripts/gen_drap.sh
- Once per minute: /opt/hamclock-backend/scripts/genxray.pl
