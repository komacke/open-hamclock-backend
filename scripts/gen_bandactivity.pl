#!/usr/bin/env perl
# =============================================================================
#
#   #####   #     #  ######
#  #     #  #     #  #     #
#  #     #  #     #  #     #
#  #     #  #######  ######
#  #     #  #     #  #     #
#  #     #  #     #  #     #
#   #####   #     #  ######
#
#  Open HamClock Backend (OHB)
#  gen_bandactivity.pl
#
#  Part of the OHB project:
#  https://github.com/openhamclock/open-hamclock-backend/tree/main
#
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
# =============================================================================

use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use URI;
use File::Copy qw(move);

# Spothole API v2. See https://spothole.app/apidocs for schema (JS-rendered
# page -- easier in practice to just sample the live API; see gen_xonta.pl's
# header for how that sampling was actually done).
my $SPOTHOLE_BASE = 'https://spothole.app/api/v2/spots';

my $OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/band_activity.txt';
my $TMP = '/opt/hamclock-backend/htdocs/tmp/band_activity.txt.tmp';

my $MAX_AGE_S = 1800;

my $ua = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'OHB/1.1 (+https://github.com/openhamclock/open-hamclock-backend)',
);

my $uri = URI->new($SPOTHOLE_BASE);
$uri->query_form(
    allow_qrt => 'false',    # drop spots already known to be QRT
    max_age   => $MAX_AGE_S,
    limit     => 5000,       # generous -- a busy contest weekend can produce a lot of raw spots
                              # in 30 minutes across every source Spothole aggregates
);

my $resp = $ua->get($uri);
if (!$resp->is_success) {
    warn "band_activity fetch failed: " . $resp->status_line . "\n";
    exit 1;
}

my $spots = eval { decode_json($resp->decoded_content) };
if ($@) {
    warn "band_activity JSON parse failed: $@\n";
    exit 1;
}
unless (ref $spots eq 'ARRAY') {
    warn "band_activity response was not a JSON array\n";
    exit 1;
}

my $now = time();
my %seen;              # "band|continent|call" -> 1, so a station spotted repeatedly only
                        # counts once (see header comment for why)
my %counts;             # "band|continent" -> distinct station count
my $n_considered = 0;
my $n_skipped_noband = 0;
my $n_skipped_nocontinent = 0;

for my $s (@$spots) {
    next unless ref $s eq 'HASH';
    next if $s->{qrt};                          # belt and suspenders, same as gen_xonta.pl

    my $call = $s->{dx_call};
    next unless defined $call && length $call;

    my $band = $s->{band};                       # Spothole's own string, eg "20m", "70cm" --
                                                   # passed through as-is rather than remapped
                                                   # through HamBandSetting, so any band Spothole
                                                   # reports (including ones outside HamClock's
                                                   # own curated band-filter list, eg 160m/80m/2m)
                                                   # still shows up here rather than being silently
                                                   # dropped
    if (!defined $band || !length $band) {
        $n_skipped_noband++;
        next;
    }

    my $continent = $s->{dx_continent};           # 2-letter code, eg "EU", "NA" -- also passed
                                                   # through as-is; this is the DX (spotted)
                                                   # station's continent, ie "where the activity
                                                   # is", not the spotter's
    if (!defined $continent || !length $continent) {
        $n_skipped_nocontinent++;
        next;
    }

    $n_considered++;

    my $seen_key = join ('|', $band, $continent, uc ($call));
    next if $seen{$seen_key};                     # already counted this station on this
                                                    # band/continent this run
    $seen{$seen_key} = 1;

    my $bucket_key = join ('|', $band, $continent);
    $counts{$bucket_key}++;
}

open my $fh, '>', $TMP or die "Cannot write temp file $TMP: $!\n";
print $fh "#band_activity v1 generated=$now window_secs=$MAX_AGE_S\n";
print $fh "#band,continent,count\n";
for my $bucket_key (sort keys %counts) {
    my ($band, $continent) = split (/\|/, $bucket_key);
    print $fh "$band,$continent,$counts{$bucket_key}\n";
}
close $fh;

move $TMP, $OUT or die "move failed $TMP -> $OUT: $!\n";

print "--- Processing Complete ---\n";
print "Considered: $n_considered (skipped: $n_skipped_noband no band, ".
        "$n_skipped_nocontinent no continent)\n";
print "Distinct band/continent buckets written: " . scalar (keys %counts) . "\n";
print "Total distinct stations counted: " . scalar (keys %seen) . "\n";
