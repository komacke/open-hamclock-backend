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
#  gen_iota.pl -- IOTA on-the-air spot aggregator
#
#  Part of the OHB project:
#  https://github.com/openhamclock/open-hamclock-backend/tree/main
#
#  Sibling to gen_onta.pl, but sourced entirely from the Spothole API
#  (https://spothole.app/api/v2/spots) rather than a per-SIG API, since
#  IOTA has no live "who's activating what" feed of its own -- Spothole
#  already resolves IOTA references it finds in DX Cluster/RBN spot
#  comments into a full SIGRef (name, grid, lat/lng) server-side, via
#  its ?sig=IOTA filter. That does all the work gen_onta.pl otherwise
#  has to do itself with the POTA/SOTA/WWFF park-CSV lookups.
#
#  Writes iota_spots.txt using the EXACT SAME line schema as onta.txt
#  (call,Hz,unix,mode,grid,lat,lng,ref,org) so HamClock's existing
#  onta.txt parser can read it completely unmodified. Kept as a
#  separate, purely additive file -- same philosophy as onta_parks.txt
#  -- so onta.txt itself and its consumers are undisturbed.
#
#  NOTE: this is unrelated to fetchIOTA.py / iota.txt, which feeds the
#  lightweight ref->name cache HamClock's Live Spots pane uses to
#  annotate ordinary Cluster spots on the ESP32 client. That stays as
#  is; this script feeds the On The Air pane instead.
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

# Spothole API v2. See https://spothole.app/api/v2/openapi.yml for schema.
my $SPOTHOLE_BASE = 'https://spothole.app/api/v2/spots';

my $OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/iota_spots.txt';
my $TMP = '/opt/hamclock-backend/htdocs/tmp/iota_spots.txt.tmp';

# HamClock rejects callsigns longer than 12 characters -- same bound gen_onta.pl uses
my $MAX_CALL = 12;

# Same reasoning as gen_onta.pl's MAX_AGE_S: HamClock's ONTA age selector maxes
# out at 60 min (10/20/40/60), so anything older is discarded client-side anyway.
# Bound the feed at 65 min so that selector stays the real filter, with ~5 min
# margin to cover this script's own run interval.
my $MAX_AGE_S = 3900;

# ---------------------------------------------------------------------------
# Sanitize a string field before it enters the output line. Same rules as
# gen_onta.pl's clean_field(): strip control chars, collapse whitespace,
# remove commas (they'd break the CSV-style output), trim edges.
# ---------------------------------------------------------------------------
sub clean_field {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/[\x00-\x1F\x7F]+/ /g;
    $v =~ s/,+/ /g;
    $v =~ s/\s+/ /g;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

my $ua = LWP::UserAgent->new(
    timeout => 15,
    agent   => 'OHB/1.1 (+https://github.com/openhamclock/open-hamclock-backend)',
);

my $uri = URI->new($SPOTHOLE_BASE);
$uri->query_form(
    sig                 => 'IOTA',
    needs_sig_ref       => 'true',   # guarantee a resolved SIGRef (name/grid/lat/lng) is present
    needs_good_location => 'true',   # skip anything Spothole itself flags as poorly located
    allow_qrt           => 'false',  # drop spots already known to be QRT
    max_age             => $MAX_AGE_S,
    limit               => 2000,     # generous safety cap, not expected to be hit
);

my $now = time();
my %best;          # dedup key -> row hashref, same pattern as gen_onta.pl's %best
my $n_in = 0;

my $resp = $ua->get($uri);
if (!$resp->is_success) {
    warn "IOTA (Spothole) fetch failed: " . $resp->status_line . "\n";
} else {
    my $spots = eval { decode_json($resp->decoded_content) };
    if ($@) {
        warn "IOTA (Spothole) JSON parse failed: $@\n";
    } elsif (ref $spots eq 'ARRAY') {
        for my $s (@$spots) {
            next unless ref $s eq 'HASH';
            $n_in++;

            next if $s->{qrt};   # belt and suspenders, in case allow_qrt=false is ever loosened

            my $call = clean_field($s->{dx_call});
            next unless length $call;
            next if length($call) > $MAX_CALL;

            my $freq = $s->{freq};                # already in Hz per Spothole's Spot schema
            next unless defined $freq && $freq > 0 && $freq <= 1_300_000_000;
            my $hz = int($freq);

            my $mode = clean_field($s->{mode});

            my $time = $s->{time};                # unix epoch seconds
            next unless defined $time;
            my $epoch = int($time);
            next if ($now - $epoch) > $MAX_AGE_S;

            # find the IOTA reference among this spot's sig_refs -- there should be
            # exactly one given we filtered sig=IOTA, but don't assume array order
            my $refs = $s->{sig_refs} // [];
            my ($iota_ref) = grep { ref $_ eq 'HASH' && ($_->{sig} // '') eq 'IOTA' } @$refs;
            next unless $iota_ref && length($iota_ref->{id} // '');
            my $ref = clean_field($iota_ref->{id});

            # prefer the spot's own resolved dx_grid/lat/lng (what a map pane should use),
            # falling back to the sig_ref's own location if those are somehow blank
            my $grid = clean_field($s->{dx_grid} // $iota_ref->{grid} // '');
            my $lat  = $s->{dx_latitude}  // $iota_ref->{latitude};
            my $lng  = $s->{dx_longitude} // $iota_ref->{longitude};

            # HamClock's onta.txt reader requires a grid OR a non-zero lat/lng pair
            next unless length($grid) || (defined($lat) && defined($lng) && ($lat != 0 || $lng != 0));
            $lat //= 0;
            $lng //= 0;

            my $key = join('|', $call, $ref, $mode, $hz);

            if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
                $best{$key} = {
                    call  => $call,
                    hz    => $hz,
                    epoch => $epoch,
                    mode  => $mode,
                    grid  => $grid,
                    lat   => $lat,
                    lng   => $lng,
                    ref   => $ref,
                    org   => 'IOTA',
                };
            }
        }
    } else {
        warn "IOTA (Spothole) response was not a JSON array\n";
    }
}

my @out = sort { $b->{epoch} <=> $a->{epoch} } values %best;

open my $fh, '>', $TMP or die "Cannot write temp file $TMP: $!\n";
print $fh "#call,Hz,unix,mode,grid,lat,lng,park,org\n";
for my $r (@out) {
    print $fh join(',',
        $r->{call},
        $r->{hz},
        $r->{epoch},
        $r->{mode},
        $r->{grid},
        $r->{lat},
        $r->{lng},
        $r->{ref},
        $r->{org},
    ), "\n";
}
close $fh;

move $TMP, $OUT or die "move failed $TMP -> $OUT: $!\n";

print "--- Processing Complete ---\n";
print "IOTA source spots received : $n_in\n";
print "IOTA records written       : " . scalar(@out) . "\n";
print "Output                     : $OUT\n";
