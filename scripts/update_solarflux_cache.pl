#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;

my $URL = 'https://services.swpc.noaa.gov/text/daily-solar-indices.txt';
my $CACHE = '/opt/hamclock-backend/data/solarflux-cache.txt';
my $MAX_DAYS = 90;

my $ua = LWP::UserAgent->new(timeout => 10);

my $resp = $ua->get($URL);
die "Fetch failed\n" unless $resp->is_success;

# Load existing cache
my %seen;
my @cache;

if (open my $fh, '<', $CACHE) {
    while (<$fh>) {
        chomp;
        my ($d, $v) = split;
        next unless defined $d && defined $v;
        push @cache, [$d, $v];
        $seen{$d} = 1;
    }
    close $fh;
}

# Parse NOAA file
for my $line (split /\n/, $resp->decoded_content) {

    next if $line =~ /^[:#]/;
    next unless $line =~ /^\d{4}\s+\d{2}\s+\d{2}/;

    my ($Y,$m,$d,$flux) = (split /\s+/, $line)[0,1,2,3];
    next unless defined $flux;

    my $date = sprintf '%04d-%02d-%02d', $Y, $m, $d;

    next if $seen{$date};

    push @cache, [$date, $flux];
    $seen{$date} = 1;
}

# Sort and trim
@cache = sort { $a->[0] cmp $b->[0] } @cache;
@cache = splice(@cache, -$MAX_DAYS) if @cache > $MAX_DAYS;

# Write back
open my $out, '>', $CACHE or die "Write cache failed\n";
for my $e (@cache) {
    print $out "$e->[0] $e->[1]\n";
}
close $out;

