#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use Time::Piece;

my $URL = 'https://spaceweather.gc.ca/solar_flux_data/daily_flux_values/fluxtable.txt';
my $URL_PREDICT = 'https://services.swpc.noaa.gov/text/45-day-ap-forecast.txt';
my $CACHE = '/opt/hamclock-backend/data/solarflux-cache.txt';
my $MAX_HISTORY_VALUES = 90;
my $MAX_PREDICT_VALUES = 9;
my $MAX_VALUES = $MAX_HISTORY_VALUES + $MAX_PREDICT_VALUES;

my $ua = LWP::UserAgent->new(timeout => 10);

# Get SFI history
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
    # remove the predict values
    splice(@cache, -$MAX_PREDICT_VALUES);
    close $fh;
}


# Parse spaceweather canada file
for my $line (split /\n/, $resp->decoded_content) {

    next if $line =~ /^[a-zA-Z-]/;
    next unless $line =~ /^\d{8}\s+\d{6}/;

    my ($Ymd,$time,$flux) = (split /\s+/, $line)[0,1,4];
    next unless defined $flux;

    $Ymd =~ s/(\d{4})(\d{2})(\d{2})/$1-$2-$3/;

    next if $seen{$Ymd."T".$time};

    push @cache, [$Ymd."T".$time, sprintf('%d', $flux) ];
    $seen{$Ymd."T".$time} = 1;
}

# Get SFI predictions
$resp = $ua->get($URL_PREDICT);
die "Fetch failed\n" unless $resp->is_success;

# Parse NOAA file
# hardcoded to find the one line with 3 entries and pull those entries
my @lines = split /\n/, $resp->decoded_content;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /45-DAY F10.7 CM FLUX FORECAST/) {
        # Grab the immediate next line of data
        my $data_row = $lines[$i+1];

        # Split the row into individual tokens
        my @fields = split ' ', $data_row;

        # values are date sfi data sfi ...
        # (Assuming format: Date Value Date Value Date Value)
        for my $j (0 .. 2) {
            for my $k (0 .. 2) {
                my ($Ymdtime,$flux) = (
                        Time::Piece->strptime($fields[$j*2]." ".$k, "%d%b%y %H")->strftime("%Y-%m-%dT%H%M%S"), $fields[$j*2+1]
                    ) if defined $fields[$j] && defined $fields[$j+1];
                push @cache, [$Ymdtime, sprintf('%d', $flux) ];
            }
        }
    }
}

# Sort and trim
@cache = sort { $a->[0] cmp $b->[0] } @cache;
@cache = splice(@cache, -$MAX_VALUES) if @cache > $MAX_VALUES;

# Write back
open my $out, '>', $CACHE or die "Write cache failed\n";
for my $e (@cache) {
    print $out "$e->[0] $e->[1]\n";
}
close $out;

