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
#  gen_xonta.pl -- "extra" xOTA spot aggregator (whatever Spothole actually
#                  has live beyond POTA/SOTA/WWFF/IOTA)
#
#  Part of the OHB project:
#  https://github.com/openhamclock/open-hamclock-backend/tree/main
#
#  Sibling to gen_iota.pl -- same idea (query Spothole, since these programmes
#  don't have their own dedicated per-programme scripts the way POTA/WWFF
#  do in gen_onta.pl), REWRITTEN after live testing against the public
#  spothole.app API on 2026-08-19 showed the original per-SIG-filtered-request
#  design (one ?sig=X call per programme) was unreliable in two different ways:
#
#  1. MOST CONFIGURED SIGS AREN'T ACTUALLY LIVE ON THIS SERVER.
#     Spothole's own README lists everything the *software* can connect to
#     (POTA, SOTA, WWFF, GMA, WWBOTA, HEMA, IOTA, MOTA, ARLHS, ILLW, SIOTA,
#     WCA, ZLOTA, KRMNPA, WAB, ...), but that's not the same as what the
#     public spothole.app instance has actually enabled. Sampling
#     unfiltered spots (?allow_qrt=false&max_age=86400&limit=2000, i.e. a
#     full day) on 2026-08-19 across two separate pulls showed only these
#     `source` values ever appearing: POTA, SOTA, WWFF, ParksNPeaks, GMA,
#     LLOTA, Towers. WWBOTA/HEMA/WCA/ARLHS/ILLW/SIOTA/ZLOTA/KRMNPA/WAB/MOTA
#     never appeared once across ~1400 combined spots. Rather than keep
#     silently polling nine dead endpoints every run, TARGET_ORGS below is
#     pruned to what's been observed live. Re-add entries here the moment
#     they're confirmed live (see the sampling command in the comment above
#     TARGET_ORGS) -- the matching logic doesn't care, it's generic.
#
#  2. THE `sig` FIELD ISN'T ALWAYS SET EVEN WHEN A PROGRAMME'S DATA IS
#     PRESENT. GMA is the clear example: unfiltered sampling found spots
#     with "source": "GMA" but "sig": "" (and the matching sig_refs[] entry
#     ALSO has "sig": ""), so a `?sig=GMA` filtered request finds nothing
#     even though GMA activity genuinely exists in the unfiltered feed.
#     ?sig=X filtering isn't reliable enough to build this around.
#
#  FIX: this version makes exactly ONE broad, unfiltered-by-sig request per
#  run (cheaper than before, too -- 1 call instead of N), then classifies
#  each spot locally:
#    - if any of its sig_refs[] entries has a non-empty "sig" matching a
#      configured org, trust that (the normal, well-behaved case);
#    - else, for orgs explicitly listed in %SOURCE_FALLBACK (currently just
#      GMA), fall back to matching on the spot's own top-level "source"
#      field and using whatever lone sig_refs[] entry is present, even
#      though its "sig" is blank.
#
#  CAVEAT ON THE GMA FALLBACK, READ BEFORE ENABLING SIMILAR FALLBACKS
#  ELSEWHERE: cqgma.org (Spothole's "GMA" source) is documented (see
#  gen_onta.pl's WWFF comment block) to carry WWFF spot traffic as well as
#  genuine Global Mountain Activity spots -- that's the whole reason
#  fetch_wwff_cache.pl exists, pointed at gma.rocks. Because the "sig" tag
#  that would normally distinguish "this GMA-sourced spot is actually WWFF"
#  from "this one is really GMA" is the exact field that's missing, the
#  GMA fallback below CANNOT reliably tell the two apart. A WWFF park spot
#  relayed through cqgma.org may get mislabeled org=GMA here. Given
#  gen_onta.pl already gets WWFF from its own dedicated, correctly-tagged
#  cqgma.org feed, the practical impact is a possible duplicate entry under
#  the wrong org label rather than a missing one -- annoying, not silent
#  data loss, but worth fixing properly (e.g. by asking Spothole's
#  maintainer whether the sig tag can be made reliable for GMA specifically)
#  rather than treating this fallback as a long-term solution.
#
#  2026-09-06 UPDATE -- SOTA, Towers (TOTA), and WWBOTA added:
#   - SOTA: added because the dedicated SOTAwatch API (api2.sota.org.uk)
#     that gen_onta.pl used to fetch SOTA from directly has been
#     deprecated. Manual sampling of 50 SOTA-sourced spots on 2026-09-06
#     found sig_refs[].sig == "SOTA" on all 50 (0 blank) -- no fallback
#     needed, unlike GMA. gen_onta.pl's own SOTA fetch has been removed to
#     match; this is now the sole SOTA source. Re-verify this sig
#     reliability holds if SOTA spots ever look sparse/missing -- one
#     sample isn't as strong evidence as the two-pull GMA finding above.
#
#     LOCATION SOURCE FOR SOTA IS THE STATIC SUMMIT CSV, NOT SPOTHOLE'S
#     OWN dx_grid/dx_latitude/dx_longitude: this mirrors what gen_onta.pl
#     did before it lost its SOTA block -- the old SOTAwatch spot payload
#     never carried lat/lng at all, so sota_summits.csv (built by
#     update_sota_cache.pl from storage.sota.org.uk/summitslist.csv, a
#     separate static reference endpoint unaffected by the api2.sota.org.uk
#     deprecation) was always the sole source of SOTA location, keyed by
#     the exact same "ASSOC/SUMMIT-NNN" reference format Spothole's own
#     sig_refs[].id uses. A summit's position is fixed -- it doesn't move
#     -- so that cached reference position is treated as authoritative and
#     preferred over Spothole's own per-spot dx_grid/dx_latitude/
#     dx_longitude (which are themselves reportedly derived per spot, see
#     "dx_location_source": "SPOT" in sampled records, not guaranteed to
#     be the actual summit coordinates). Spothole's own fields are used
#     only as a fallback, for a summit not yet in the cached CSV. No other
#     org here (GMA/LLOTA/TOWERS/WWBOTA) has an equivalent reference CSV,
#     so none of them get this treatment.
#   - Towers: this is what the "Towers" `source` seen in the original
#     2026-08-19 sampling turns out to be -- a sample record has
#     sig_refs[].sig == "Towers", ref_type "TOWER", and a comment
#     literally containing "TOTA" (Towers on the Air). Cleanly tagged, no
#     fallback needed. NOTE: matched sig comes back as "Towers" (mixed
#     case) from Spothole; the org-matching logic below uc()s everything
#     so this doesn't matter for matching, but it does mean rows get
#     written out with org=TOWERS -- the client's ontaOrgMarkerColor()
#     lookup is case-insensitive (strcasecmp) so this is fine as long as
#     that table has a "Towers"-or-any-case entry.
#   - WWBOTA (World Wide Bunkers On The Air): explicitly listed above as
#     NEVER appearing in the original 2026-08-19 sampling (0 across ~1400
#     spots) -- it's now live, confirmed via a 2026-09-06 sample with
#     sig_refs[].sig == "WWBOTA" and ref_type "BUNKER", cleanly tagged.
#     Volume is very low (2 spots in a ~1200-spot sample), so don't be
#     surprised if this org rarely shows anything -- that's expected
#     scarcity, not a bug. Reconfirm tagging stays clean on a broader
#     sample if it's ever suspected of going quiet or misbehaving.
#
#  STILL DELIBERATELY EXCLUDED:
#   - "ParksNPeaks" is a relay site, not a programme of its own -- it
#     re-shares POTA/SOTA/WWFF activity under those programmes' own,
#     correctly-set sig tags (confirmed again in the 2026-09-06 sample:
#     ParksNPeaks-sourced spots came through with sig="SOTA" and real
#     SOTA summit refs), so it needs no special handling here. Those
#     spots are already picked up automatically via the SOTA entry above
#     (matching is on sig_refs[].sig, not top-level "source") -- adding
#     "ParksNPeaks" itself as an org would double-count them under a
#     fake programme name.
#   - "Cluster" is the same pattern as ParksNPeaks: plain DX cluster spots
#     that Spothole auto-classified under a real programme's sig (WWFF, in
#     the 2026-09-06 sample). Not a programme itself, not added.
#   - "Tiles" appeared in the 2026-09-06 sample with sig_refs[].sig ==
#     "Tiles" but ref_type "GRID" and a bare 6-character grid locator as
#     the "id" (e.g. "FN42EL") -- not a park/summit/tower/bunker reference
#     tied to any identified award programme. Genuinely unclear whether
#     this is a real "chase the grid square" scheme or just Spothole's own
#     catch-all bucket for spots with a location but no recognized award
#     reference. Deliberately left out of TARGET_ORGS pending investigation
#     into what "Tiles" actually is -- same "unresolved, don't guess"
#     treatment Towers got in the original version of this file.
#   - LLOTA (lighthouses) IS in TARGET_ORGS below since it appeared live
#     and, per prior sig_refs testing patterns, had no reason to expect the
#     same blank-sig problem GMA has -- reconfirm this holds once real
#     LLOTA spots are checked for a non-empty sig field.
#
#  Writes xonta_spots.txt using the EXACT SAME line schema as onta.txt and
#  iota_spots.txt (call,Hz,unix,mode,grid,lat,lng,ref,org), so HamClock's
#  existing onta.txt parser can read it completely unmodified. Kept as a
#  separate, purely additive file -- same philosophy as iota_spots.txt and
#  onta_parks.txt -- so onta.txt itself and its consumers are undisturbed.
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
use Text::CSV_XS;
use File::Copy qw(move);

# Spothole API v2. See https://spothole.app/apidocs for schema (JS-rendered
# page -- easier in practice to just sample the live API, see header above).
my $SPOTHOLE_BASE = 'https://spothole.app/api/v2/spots';

# ---------------------------------------------------------------------------
# Orgs we actually want out of this one broad fetch. CONFIRMED LIVE on the
# public spothole.app instance via manual sampling on 2026-08-19 (GMA,
# LLOTA) and 2026-09-06 (SOTA, TOWERS, WWBOTA) -- see header comment for
# the exact commands + results. Re-run that sampling periodically --
# Spothole's enabled sources are the server owner's choice and can change.
# ---------------------------------------------------------------------------
my @TARGET_ORGS = qw(GMA LLOTA SOTA TOWERS WWBOTA);

# ---------------------------------------------------------------------------
# Orgs where the primary "does any sig_refs[] entry say sig=X" match is
# known to fail (blank sig field) but the spot data itself is genuinely
# present under a matching top-level "source". See the big GMA caveat in
# the header comment before adding anything else here.
# ---------------------------------------------------------------------------
my %SOURCE_FALLBACK = (
    GMA => 'GMA',
);

my $OUT = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/xonta_spots.txt';
my $TMP = '/opt/hamclock-backend/htdocs/tmp/xonta_spots.txt.tmp';

# ---------------------------------------------------------------------------
# Static SOTA summit reference data -- see the big SOTA comment in the
# header for why this exists and why it's preferred over Spothole's own
# per-spot location fields. Same file gen_onta.pl's SOTA block used to
# read, same generator script, just relocated here.
# ---------------------------------------------------------------------------
my $SOTA_CSV           = '/opt/hamclock-backend/cache/sota_summits.csv';
my $SOTA_CSV_GENERATOR = '/opt/hamclock-backend/scripts/update_sota_cache.pl';

# ---------------------------------------------------------------------------
# Load a reference lookup CSV into a hash keyed by reference string.
# Required columns: reference, latitude, longitude, grid. Ported verbatim
# from gen_onta.pl's load_lookup() (see that script if this ever needs to
# support a location/state column too -- sota_summits.csv doesn't have
# one, so that part is dead weight here, but kept for parity/low risk).
# ---------------------------------------------------------------------------
my @LOC_COLS = qw(locationDesc state region);

sub load_lookup {
    my ($path) = @_;
    my %park;

    return %park unless -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or do {
        warn "Cannot read $path: $!\n";
        return %park;
    };

    my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

    my $header = $csv->getline($fh);
    unless ($header && @$header) {
        warn "Empty or unreadable header in $path\n";
        close $fh;
        return %park;
    }

    my %idx;
    for my $i (0 .. $#$header) {
        my $k = $header->[$i] // next;
        $k =~ s/^"|"$//g;
        $idx{$k} = $i;
    }

    for my $need (qw(reference latitude longitude grid)) {
        unless (exists $idx{$need}) {
            warn "Missing '$need' column in $path\n";
            close $fh;
            return %park;
        }
    }

    my ($loc_col) = grep { exists $idx{$_} } @LOC_COLS;

    while (my $row = $csv->getline($fh)) {
        my $ref = $row->[$idx{reference}] // next;
        $ref =~ s/^"|"$//g;

        $park{$ref} = {
            lat  => ($row->[$idx{latitude}]  // ''),
            lng  => ($row->[$idx{longitude}] // ''),
            grid => ($row->[$idx{grid}]      // ''),
            loc  => ($loc_col ? ($row->[$idx{$loc_col}] // '') : ''),
        };
    }

    close $fh;
    return %park;
}

unless (-e $SOTA_CSV) {
    print "Missing $SOTA_CSV. Running $SOTA_CSV_GENERATOR...\n";
    system("perl $SOTA_CSV_GENERATOR");
    if ($? != 0 || !-e $SOTA_CSV) {
        print "Error: Failed to generate $SOTA_CSV using $SOTA_CSV_GENERATOR (Exit code: $?). Continuing.\n";
    }
}
my %sota_lookup = load_lookup($SOTA_CSV);

# ---------------------------------------------------------------------------
# Look up a SOTA summit's authoritative fixed position. Returns
# ('', undef, undef) if the summit isn't in the cached list -- caller
# falls back to Spothole's own per-spot location fields in that case.
# ---------------------------------------------------------------------------
sub resolve_sota_location {
    my ($ref) = @_;
    return ('', undef, undef) unless $ref && exists $sota_lookup{$ref};
    my $e = $sota_lookup{$ref};
    my $lat = $e->{lat};
    my $lng = $e->{lng};
    return (
        $e->{grid} // '',
        (defined($lat) && length($lat) ? $lat + 0 : undef),
        (defined($lng) && length($lng) ? $lng + 0 : undef),
    );
}

# HamClock rejects callsigns longer than 12 characters -- same bound gen_onta.pl/gen_iota.pl use
my $MAX_CALL = 12;

# Same reasoning as gen_onta.pl's MAX_AGE_S: HamClock's ONTA age selector maxes
# out at 60 min (10/20/40/60), so anything older is discarded client-side anyway.
# Bound the feed at 65 min so that selector stays the real filter, with ~5 min
# margin to cover this script's own run interval.
my $MAX_AGE_S = 3900;

# ---------------------------------------------------------------------------
# Sanitize a string field before it enters the output line. Same rules as
# gen_onta.pl's / gen_iota.pl's clean_field(): strip control chars, collapse
# whitespace, remove commas (they'd break the CSV-style output), trim edges.
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
    timeout => 20,
    agent   => 'OHB/1.1 (+https://github.com/openhamclock/open-hamclock-backend)',
);

my $now = time();
my %best;                 # dedup key -> row hashref, same pattern as gen_iota.pl's %best
my %counts;                # org -> count, for the summary print at the end
my %sig_hits;              # org -> count matched via sig_refs (the "good" path)
my %fallback_hits;         # org -> count matched via source fallback (the "iffy" path)
my ($sota_csv_hits, $sota_spot_hits) = (0, 0);  # SOTA location source breakdown

# ---------------------------------------------------------------------------
# One broad request: no ?sig= filter at all, since that's the exact thing
# that silently drops GMA (and possibly others -- see header). We filter
# and classify locally instead.
# ---------------------------------------------------------------------------
my $uri = URI->new($SPOTHOLE_BASE);
$uri->query_form(
    needs_sig_ref       => 'true',   # still require SOME resolved sig_ref -- we just don't
                                      # trust its "sig" label alone anymore for every org
    needs_good_location => 'true',   # skip anything Spothole itself flags as poorly located
    allow_qrt           => 'false',  # drop spots already known to be QRT
    max_age             => $MAX_AGE_S,
    limit               => 2000,     # generous safety cap, not expected to be hit
);

my $resp = $ua->get($uri);
if (!$resp->is_success) {
    warn "xONTA fetch failed: " . $resp->status_line . "\n";
    exit 1;
}

my $spots = eval { decode_json($resp->decoded_content) };
if ($@) {
    warn "xONTA JSON parse failed: $@\n";
    exit 1;
}
unless (ref $spots eq 'ARRAY') {
    warn "xONTA response was not a JSON array\n";
    exit 1;
}

my %is_target = map { uc($_) => 1 } @TARGET_ORGS;

for my $s (@$spots) {
    next unless ref $s eq 'HASH';

    next if $s->{qrt};   # belt and suspenders, in case allow_qrt=false is ever loosened

    my $refs = $s->{sig_refs} // [];
    next unless ref $refs eq 'ARRAY' && @$refs;

    # Primary path: does any sig_refs[] entry carry a non-empty sig matching
    # one of our target orgs? If so that's an unambiguous, well-tagged match.
    my ($org, $sig_ref, $via_fallback);
    for my $r (@$refs) {
        next unless ref $r eq 'HASH';
        my $rsig = uc(clean_field($r->{sig}));
        if (length($rsig) && $is_target{$rsig}) {
            $org     = $rsig;
            $sig_ref = $r;
            last;
        }
    }

    # Fallback path: no sig_refs[] entry had a usable sig, but this org is
    # explicitly configured to trust top-level "source" instead (see the
    # GMA caveat in the header -- this is a deliberately narrow allowance,
    # not a general substitute for proper sig tagging).
    if (!$org) {
        my $source = uc(clean_field($s->{source}));
        if (length($source) && exists $SOURCE_FALLBACK{$source} && @$refs == 1
                && ref $refs->[0] eq 'HASH') {
            $org          = $SOURCE_FALLBACK{$source};
            $sig_ref      = $refs->[0];
            $via_fallback = 1;
        }
    }

    next unless $org;

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

    my $ref = clean_field($sig_ref->{id});
    next unless length $ref;

    # For SOTA, the fixed summit position from sota_summits.csv is treated
    # as authoritative and preferred over Spothole's own per-spot location
    # fields -- see the big SOTA comment in the header for why. Falls back
    # to Spothole's own dx_grid/dx_latitude/dx_longitude (or the sig_ref's
    # own location) if the summit isn't in the cached list yet.
    my ($grid, $lat, $lng);
    if ($org eq 'SOTA') {
        my ($csv_grid, $csv_lat, $csv_lng) = resolve_sota_location($ref);
        if (length($csv_grid) || (defined($csv_lat) && defined($csv_lng))) {
            ($grid, $lat, $lng) = ($csv_grid, $csv_lat, $csv_lng);
            $sota_csv_hits++;
        }
    }
    if (!defined $grid) {
        # prefer the spot's own resolved dx_grid/lat/lng (what a map pane should use),
        # falling back to the sig_ref's own location if those are somehow blank
        $grid = clean_field($s->{dx_grid} // $sig_ref->{grid} // '');
        $lat  = $s->{dx_latitude}  // $sig_ref->{latitude};
        $lng  = $s->{dx_longitude} // $sig_ref->{longitude};
        $sota_spot_hits++ if $org eq 'SOTA';
    }

    # HamClock's onta.txt reader requires a grid OR a non-zero lat/lng pair
    next unless length($grid) || (defined($lat) && defined($lng) && ($lat != 0 || $lng != 0));
    $lat //= 0;
    $lng //= 0;

    my $key = join('|', $call, $ref, $mode, $hz, $org);

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
            org   => $org,
        };
        $counts{$org}++;
        $via_fallback ? $fallback_hits{$org}++ : $sig_hits{$org}++;
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
for my $org (@TARGET_ORGS) {
    printf "%-8s records: %d  (via sig: %d, via source fallback: %d)\n",
        $org, ($counts{$org} // 0), ($sig_hits{$org} // 0), ($fallback_hits{$org} // 0);
}
printf "SOTA location source: %d from sota_summits.csv, %d from Spothole's own fields\n",
    $sota_csv_hits, $sota_spot_hits;
print "Total unique spots written to $OUT: " . scalar(@out) . "\n";
