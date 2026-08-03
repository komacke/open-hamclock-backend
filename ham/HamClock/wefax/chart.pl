#!/usr/bin/perl
# Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# chart.pl -- OHB FastCGI endpoint backing HamClock's wefax.cpp
#
#   GET /ham/HamClock/wefax/chart.pl?provider=P&region=R&product=Q
#
# Fetches the real chart image an agency already publishes on the web (the
# same image transmitted over HF WEFAX), converts it to a plain 24bpp
# uncompressed BMP (deliberately the simplest format HamClock's bmp.cpp
# readBMPHeader() accepts -- bpp must be 16 or 24, compression 0 or 3;
# 24bpp/BI_RGB needs no color-mask bitfields), zlib-deflates it, and serves
# it -- same /SDO/<file>.z convention SDO already uses.
#
# Runs under FastCGI: lighttpd keeps a small pool of these Perl processes
# alive across many requests, so unlike plain CGI there IS persistent memory
# to cache in. Two tiers:
#   - in-memory %MEM_CACHE, scoped per worker process -- the fast path, no
#     syscalls at all, but only shared with the ~N other requests this same
#     worker happens to handle
#   - the on-disk cache file, shared by every worker (and survives a worker
#     being recycled), still the source of truth
# flock() coalescing on the disk file still matters even with FastCGI:
# there's more than one worker process, so a cold key can still be raced by
# several workers at once. Whichever worker wins the lock fetches; the rest
# block, then just re-check the now-fresh disk (and repopulate their own
# memory cache from it) instead of re-fetching.
#

use strict;
use warnings;
use CGI::Fast;
use LWP::UserAgent;
use Fcntl qw(:flock);
use Compress::Zlib;
use File::Temp qw(tempfile);
use FindBin qw($RealBin);
use Time::Local qw(timegm);


# ------------------------------------------------------------------
# config
#
# URLs below were pulled from the live Atlantic/Pacific radiofax schedule
# pages (ocean.weather.gov/shtml/{atlsch,pacsch}.php), not guessed from the
# naming convention -- each one's row in those tables showed a recent
# "Last Update" timestamp (mid/late July 2026) confirming it's a real,
# actively-refreshed chart, not a dead or renamed link. 
# ------------------------------------------------------------------

my %SOURCES = (
    # Atlantic (NMF/Boston broadcast) -- confirmed against ocean.weather.gov/shtml/atlsch.php.
    # NOAA's "Surface Analysis" is actually two half-ocean panels, not one image:
    #   Part 1 = pyaa01.gif (15N-65N, 10E-45W -- east half, Europe/Africa side)
    #   Part 2 = pyaa02.gif (15N-65N, 40W-95W -- west half, US east coast/Caribbean side)
    # using Part 2 as the default since it's the half nearer North America; Part 1 is a
    # natural second "region" entry to add if east-Atlantic coverage if it matters later 
    "OPC/atl/sfcanal" => { url => "https://ocean.weather.gov/shtml/pyaa02.gif", ttl =>  6*3600 },
    "OPC/atl/wwave"   => { url => "https://ocean.weather.gov/shtml/pwaa88.gif", ttl =>  6*3600 },  # 00Z Wind&Wave (22N-51N,40W-98W)
    "OPC/atl/f24"     => { url => "https://ocean.weather.gov/shtml/pwae98.gif", ttl => 12*3600 },  # 24Hr Wind&Wave VT 00Z (15N-65N,10E-95W)

    # Pacific (NMC/Pt. Reyes broadcast) -- confirmed against ocean.weather.gov/shtml/pacsch.php.
    # Same two-panel situation:
    #   Part 1 = pyba01.gif (20N-70N, 115W-175W -- east half, US west coast side)
    #   Part 2 = pyba02.gif (20N-70N, 175W-135E -- west half, closer to Japan/Asia side)
    # using Part 1 as the default for the same reason as Atlantic above
    "OPC/pac/sfcanal" => { url => "https://ocean.weather.gov/shtml/pyba01.gif", ttl =>  6*3600 },
    "OPC/pac/wwave"   => { url => "https://ocean.weather.gov/shtml/pwbb88.gif", ttl =>  6*3600 },  # 06Z Wind&Wave (18N-62N,East of 157W)
    "OPC/pac/f24"     => { url => "https://ocean.weather.gov/shtml/pwbe98.gif", ttl => 12*3600 },  # 24Hr Wind&Wave VT 00Z (20N-70N,115W-135E)

    # UK Met Office (Northwood/GYA broadcast, N Atlantic + Europe coverage) -- confirmed live
    # against weather.metoffice.gov.uk/maps-and-charts/surface-pressure, whose page showed
    # today's real issue timestamp when I fetched it. Using the Black & White variant
    # deliberately, not Colour: it's the more traditionally-correct rendering for a WEFAX
    # feature -- real over-the-air WEFAX is inherently monochrome fax imagery, Colour is
    # just a modern web amenity the Met Office also happens to offer.
    #
    # Genuinely different from OPC here: OPC's filenames are fixed, only the file content
    # changes underneath. The Met Office bakes the chart's reference (valid) time directly
    # into the URL path (e.g. ".../2026-08-02T0000/..."), so there's no single fixed URL to
    # hardcode. ukmo_sfcanal_urls() below computes the expected current reference time from
    # the known ~00Z/12Z cycle schedule (charts become available roughly 7.5h after their
    # reference hour, per the page's "issued at 07:30 for the 00Z chart" timing) and returns
    # that PLUS the previous cycle as a fallback, in case a cycle is running late. Licensing:
    # Crown Copyright under the Open Government Licence v3.0, which requires attribution --
    # satisfied by wefax.cpp's region cycler showing "Met Office <region>" directly next to
    # the chart every time it's displayed (see wefax_providers[] on the client side).
    #
    # Only the surface analysis product is wired up. Checked directly (not guessed): the
    # Met Office's full "Maps & charts" menu (weather.metoffice.gov.uk/maps-and-charts) has
    # no marine wind/wave or forecast-step chart at all -- "Wind map"/"Wind gust map" there
    # are UK-domestic land products, not sea-state charts, and the site's marine content
    # ("Specialist forecasts > Coast and Sea") is text-only, not chart imagery. If Northwood
    # still broadcasts a wind/wave WEFAX product, it isn't published on this domain -- would
    # need a different source (eg a legacy fax-archive page) to add it, not a retry here.
    "UKMO/natl/sfcanal" => { url_builder => \&ukmo_sfcanal_urls, ttl => 6*3600 },
);

# UK Met Office reference-time URL construction -- see the SOURCES comment above for why
# this needs a builder instead of a fixed URL.

sub ukmo_latest_reftime
{
    my ($epoch) = @_;
    my @gmt = gmtime($epoch);
    my ($mday, $mon, $year) = @gmt[3,4,5];
    my $min_of_day = $gmt[2]*60 + $gmt[1];

    if ($min_of_day >= 19*60+30) {
        return sprintf("%04d-%02d-%02dT1200", $year+1900, $mon+1, $mday);       # today's 12Z is out
    } elsif ($min_of_day >= 7*60+30) {
        return sprintf("%04d-%02d-%02dT0000", $year+1900, $mon+1, $mday);       # today's 00Z is out
    } else {
        my @y = gmtime($epoch - 86400);                                        # fall back to
        return sprintf("%04d-%02d-%02dT1200", $y[5]+1900, $y[4]+1, $y[3]);      # yesterday's 12Z
    }
}

sub ukmo_prev_reftime
{
    my ($reftime) = @_;
    my ($y, $mo, $d, $h) = $reftime =~ /^(\d+)-(\d+)-(\d+)T(\d{2})/;
    my $epoch = timegm(0, 0, $h, $d, $mo-1, $y-1900);
    my @p = gmtime($epoch - 12*3600);
    return sprintf("%04d-%02d-%02dT%02d00", $p[5]+1900, $p[4]+1, $p[3], $p[2]);
}

sub ukmo_sfcanal_urls
{
    my $now = ukmo_latest_reftime(time());
    my $prev = ukmo_prev_reftime($now);
    return map { "https://data.consumer-digital.api.metoffice.gov.uk/v1/surface-pressure/bw/$_/0000_ASXX_Assistant_FC000.gif" }
               ($now, $prev);
}

my $CACHE_DIR        = $ENV{WEFAX_CACHE_DIR} || "$RealBin/cache";
                        # override with WEFAX_CACHE_DIR to point at OHB's real
                        # cache location/volume; defaults to a "cache" directory
                        # next to this script so it works out of the box for
                        # local testing without needing that decided first
my $MAX_SOURCE_BYTES = 8 * 1024 * 1024;    # sanity cap on upstream image size
my $MAX_LONG_EDGE    = 1200;               # cap chart's long edge -- client resizes to fit anyway

unless (-d $CACHE_DIR) {
    require File::Path;
    eval { File::Path::make_path($CACHE_DIR) };
    if ($@ || !-d $CACHE_DIR) {
        die "can't create cache dir $CACHE_DIR: $@\n"
          . "(set WEFAX_CACHE_DIR to a writable path if this default doesn't fit your deployment)\n";
    }
}

# created once per worker process, reused across every request it handles --
# no reason to pay LWP::UserAgent's setup cost per-request under FastCGI
my $UA = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'OHB-WEFAX/1.0 (+https://ohb.hamclock.app)',
);

# resolve once per worker: prefer ImageMagick 7's 'magick', fall back to the
# IM6-style 'convert' binary. Shelling out avoids Image::Magick.pm (the Perl
# binding), which is compiled against a specific installed libMagick version
# and routinely breaks the next time imagemagick gets upgraded via apt --
# the CLI tools don't have that problem.
my $MAGICK_BIN = do {
    my ($bin) = grep { chomp(my $p = `which $_ 2>/dev/null`); $p } qw(magick convert);
    die "neither 'magick' nor 'convert' found in PATH -- install the imagemagick package\n"
        unless $bin;
    $bin;
};

# per-worker in-memory cache: key => { data => deflated bytes, expires_at => epoch }
# deliberately just a plain hash, not shared across workers -- the disk
# cache is the cross-worker source of truth, this is only a fast path for
# whichever requests happen to land on the same worker while it's still warm
my %MEM_CACHE;


# ------------------------------------------------------------------
# main FastCGI loop -- one process, many requests
# ------------------------------------------------------------------

while (my $q = CGI::Fast->new) {

    # every request handled inside eval{} on purpose: an uncaught die() here
    # would otherwise kill this worker process mid-service, taking down
    # whatever other requests lighttpd was about to route to it -- not just
    # failing the one response that triggered it
    eval {
        handle_request($q);
    };
    if ($@) {
        my $err = $@;
        warn "wefax_chart.pl: unhandled error: $err";
        eval {
            send_headers("500 Internal Server Error", "Content-Type" => "text/plain");
            print "internal error\n";
        };
    }

    # CGI::Fast finalizes/flushes this request's response when the loop
    # comes back around to $q->new -- nothing else to do here
}


# ------------------------------------------------------------------
# raw header emission
#
# deliberately NOT using CGI.pm's header() here: HamClock's client-side
# httpSkipHeader() (wifi.cpp) does a case-SENSITIVE strstr() for the exact
# literal "Content-Length: " -- if it doesn't match exactly, httpSkipHeader()
# still returns true (per its own contract) but leaves the value empty,
# atol("") is 0, and HamClock ends up calling zinfWiFiFILE() for zero bytes,
# which surfaces client-side as "unzip error: incorrect header check" --
# a confusing error far from its actual cause. CGI.pm's header() doesn't
# guarantee the wire casing (and lighttpd may not either); printing the
# header block ourselves removes that ambiguity entirely.
# ------------------------------------------------------------------

sub send_headers
{
    my ($status_line, %hdrs) = @_;
    print "Status: $status_line\r\n" if $status_line;
    print "$_: $hdrs{$_}\r\n" for sort keys %hdrs;
    print "\r\n";
}


# ------------------------------------------------------------------
# per-request logic
# ------------------------------------------------------------------

sub handle_request
{
    my ($q) = @_;

    my $provider = $q->param('provider') // '';
    my $region   = $q->param('region')   // '';
    my $product  = $q->param('product')  // '';
    my $key      = "$provider/$region/$product";

    my $src = $SOURCES{$key};
    if (!$src) {
        send_headers("404 Not Found", "Content-Type" => "text/plain");
        print "no such chart: $key\n";
        return;
    }

    my $body = get_chart_bytes($key, $src);

    send_headers(undef,
        "Content-Type"   => "application/octet-stream",
        "Content-Length" => length($body),
        "Cache-Control"  => "public, max-age=$src->{ttl}",
    );
    binmode(STDOUT);
    print $body;
}

# return deflated BMP bytes for $key, using memory cache, then disk cache,
# then fetching (under a cross-worker flock) as a last resort
sub get_chart_bytes
{
    my ($key, $src) = @_;

    my $now = time();

    # tier 1: this worker's own memory -- no syscalls at all
    my $m = $MEM_CACHE{$key};
    if ($m && $now < $m->{expires_at}) {
        return $m->{data};
    }

    (my $safe_key = $key) =~ s{[^A-Za-z0-9]}{_}g;
    my $cache_file = "$CACHE_DIR/$safe_key.bmp.z";
    my $lock_file  = "$CACHE_DIR/$safe_key.lock";

    # tier 2: disk, shared across every worker
    if (cache_fresh($cache_file, $src->{ttl})) {
        my $data = read_file_raw($cache_file);
        $MEM_CACHE{$key} = { data => $data, expires_at => $now + $src->{ttl} };
        return $data;
    }

    # tier 3: fetch -- but only one worker should actually do it per key
    open(my $lock_fh, '>>', $lock_file) or die "lock open failed: $!\n";
    flock($lock_fh, LOCK_EX);        # blocks here until we're the only fetcher for this key

    # re-check inside the lock: another worker may have just refreshed the
    # disk cache while we were waiting for it
    unless (cache_fresh($cache_file, $src->{ttl})) {
        eval { fetch_and_convert($src, $cache_file) };
        if ($@) {
            my $err = $@;
            flock($lock_fh, LOCK_UN);
            close($lock_fh);
            # tolerate a stale-but-present file rather than fail outright,
            # same fallback spirit as the client's own wefaxCachePresent()
            die $err unless -f $cache_file;
            my $data = read_file_raw($cache_file);
            # don't cache a known-stale read in memory with a fresh TTL --
            # let the next request retry the real fetch instead of papering
            # over an upstream outage for a full TTL window
            return $data;
        }
    }

    flock($lock_fh, LOCK_UN);
    close($lock_fh);

    my $data = read_file_raw($cache_file);
    $MEM_CACHE{$key} = { data => $data, expires_at => $now + $src->{ttl} };
    return $data;
}

sub cache_fresh
{
    my ($path, $ttl) = @_;
    return -f $path && (time() - (stat($path))[9]) < $ttl;
}

sub read_file_raw
{
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}


# ------------------------------------------------------------------
# fetch source image, convert to 24bpp BMP, deflate, write to cache_file
# ------------------------------------------------------------------

sub fetch_and_convert
{
    my ($src, $out_path) = @_;

    # most sources (OPC) have one fixed URL; UKMO's URL depends on the current
    # reference-time cycle, so url_builder returns an ordered list of candidates
    # (current cycle, then the previous one as a fallback) -- try each in turn
    my @candidates = $src->{url} ? ($src->{url}) : $src->{url_builder}->();

    my $resp;
    my @errs;
    for my $url (@candidates) {
        $resp = $UA->get($url);
        last if $resp->is_success;
        push @errs, "$url: " . $resp->status_line;
        $resp = undef;
    }
    $resp or die join("; ", @errs) . "\n";

    my $raw = $resp->decoded_content(charset => 'none');
    die "source image too large\n" if length($raw) > $MAX_SOURCE_BYTES;

    my ($src_fh, $src_path) = tempfile(SUFFIX => '.src', UNLINK => 1);
    binmode($src_fh);
    print $src_fh $raw;
    close($src_fh);

    my (undef, $bmp_path) = tempfile(SUFFIX => '.bmp', UNLINK => 1);

    # -type TrueColor forces 24bpp, no palette/alpha surprises -- readBMPHeader()
    # requires bpp 16 or 24. -resize WxH> only shrinks if larger, never upscales
    # a source that's already smaller than MAX_LONG_EDGE. BMP3: forces classic
    # BITMAPINFOHEADER/BI_RGB, same format the old Image::Magick.pm path wrote.
    my @cmd = ($MAGICK_BIN, $src_path,
               '-type', 'TrueColor',
               '-resize', "${MAX_LONG_EDGE}x${MAX_LONG_EDGE}>",
               "BMP3:$bmp_path");

    # critical: our own STDOUT *is* the CGI/FastCGI response stream. If the
    # child process writes anything at all to its inherited stdout/stderr --
    # an ImageMagick policy warning, a deprecation notice, anything -- it
    # lands directly in the middle of what's supposed to be a clean binary
    # HTTP response, corrupting the header/body framing HamClock parses.
    # Redirect the child's fds away from ours for the duration of the call.
    my $cmd_ok = do {
        open(my $old_stdout, '>&', \*STDOUT) or die "can't dup STDOUT: $!\n";
        open(my $old_stderr, '>&', \*STDERR) or die "can't dup STDERR: $!\n";
        open(STDOUT, '>', '/dev/null')       or die "can't redirect STDOUT: $!\n";
        open(STDERR, '>', '/dev/null')       or die "can't redirect STDERR: $!\n";

        my $rc = system(@cmd);

        open(STDOUT, '>&', $old_stdout) or die "can't restore STDOUT: $!\n";
        open(STDERR, '>&', $old_stderr) or die "can't restore STDERR: $!\n";

        $rc == 0;
    };

    unless ($cmd_ok) {
        unlink($src_path, $bmp_path);
        die "'@cmd' failed (exit $?)\n";
    }

    open(my $out_fh, '<:raw', $bmp_path) or die "read $bmp_path: $!\n";
    local $/;
    my $bmp = <$out_fh>;
    close($out_fh);
    unlink($src_path, $bmp_path);

    my $deflated = Compress::Zlib::compress($bmp, Z_BEST_COMPRESSION);

    # write-then-rename so a concurrent reader on cache_file never sees a
    # half-written file -- same reasoning as cachefile.cpp's tmp-then-rename
    # on the HamClock client side
    my $tmp_path = "$out_path.tmp.$$";
    open(my $cache_fh, '>:raw', $tmp_path) or die "write $tmp_path: $!\n";
    print $cache_fh $deflated;
    close($cache_fh);
    rename($tmp_path, $out_path) or die "rename $tmp_path -> $out_path: $!\n";
}
