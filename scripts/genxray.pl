#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use File::Temp qw(tempfile);

# NOAA GOES X-ray source (primary satellite)
my $URL = 'https://services.swpc.noaa.gov/json/goes/primary/xrays-3-day.json';

# Output file expected by HamClock
my $OUT = 'xray.txt';

# Fetch JSON
my $ua = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'HamClock-xray-backend/1.0'
);

my $resp = $ua->get($URL);
die "ERROR: fetch failed: " . $resp->status_line . "\n"
    unless $resp->is_success;

my $rows = decode_json($resp->decoded_content);
die "ERROR: JSON root is not an array\n"
    unless ref $rows eq 'ARRAY';

# Group records by timestamp
my %by_time;

for my $r (@$rows) {

    next unless defined $r->{time_tag};
    next unless defined $r->{energy};
    next unless defined $r->{flux};

    my $time   = $r->{time_tag};
    my $energy = $r->{energy};
    my $flux   = $r->{flux};

    # Flux must be numeric and positive
    next unless $flux =~ /^[0-9.eE+-]+$/;
    next unless $flux > 0;

    if ($energy eq '0.05-0.4nm') {
        $by_time{$time}{short} = $flux;
    }
    elsif ($energy eq '0.1-0.8nm') {
        $by_time{$time}{long}  = $flux;
    }
}

# Write atomically so HamClock never sees partial output
my ($fh, $tmp) = tempfile('xrayXXXX', UNLINK => 0);

for my $time (sort keys %by_time) {

    # Require both bands for the timestamp
    next unless exists $by_time{$time}{short}
             && exists $by_time{$time}{long};

    # Parse ISO8601 UTC timestamp
    if ($time =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/) {
        my ($Y,$M,$D,$h,$m) = ($1,$2,$3,$4,$5);
        my $hhmm = sprintf("%02d%02d", $h, $m);

        printf $fh
            "%4d %2d %2d  %4s   00000  00000  %12.2e  %12.2e\n",
            $Y, $M, $D, $hhmm,
            $by_time{$time}{short},
            $by_time{$time}{long};
    }
}

close $fh;

rename $tmp, $OUT
    or die "ERROR: rename failed: $!\n";

