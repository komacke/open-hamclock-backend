#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use XML::Feed;
use HTML::Entities;

# Ensure Unicode prints correctly
binmode(STDOUT, ':encoding(UTF-8)');

my $url = 'https://www.arnewsline.org/?format=rss';

my $ua = LWP::UserAgent->new(
    timeout => 10,
    agent   => 'Mozilla/5.0',
);

my $resp = $ua->get($url);
die "FETCH FAILED: " . $resp->status_line . "\n"
    unless $resp->is_success;

my $feed = XML::Feed->parse(\$resp->decoded_content)
    or die "RSS PARSE FAILED\n";

# Only the most recent report
my ($entry) = $feed->entries
    or die "NO ENTRIES FOUND\n";

my $html = $entry->content->body || '';

# Remove SCRIPT/AUDIO link paragraphs
$html =~ s{<p[^>]*>\s*<a[^>]*>.*?</a>\s*</p>}{}gis;

# Convert HTML line breaks to real newlines
$html =~ s/<br\s*\/?>/\n/gi;

# Strip remaining HTML tags
$html =~ s/<[^>]+>//g;

# Decode HTML entities (this is correct)
decode_entities($html);

# Extract bullet lines
for my $line (split /\n/, $html) {
    next unless $line =~ /^\s*-\s*(.+)$/;
    my $headline = $1;
    $headline =~ s/\s+$//;
    print "ARNewsLine.org: $headline\n";
}

