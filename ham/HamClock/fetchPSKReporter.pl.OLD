#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use CGI qw(param);
use XML::LibXML;

print "Content-Type: text/plain; charset=ISO-8859-1\r\n\r\n";

my $grid   = param('ofgrid')  || '';
my $maxage = param('maxage') || 1800;

$grid =~ s/[^A-Z0-9]//gi;
$grid = uc($grid);

if (!$grid || $maxage !~ /^\d+$/) {
    print "ERROR=Invalid parameters\n";
    exit;
}

my $url = sprintf(
    "https://pskreporter.info/cgi-bin/pskquery5.pl?" .
    "statistics=1&noactive=1&nolocator=1&modify=grid" .
    "&senderCallsign=%s&flowStartSeconds=-%d&lastDuration=%d",
    $grid, $maxage, $maxage
);

my $ua = LWP::UserAgent->new(
    timeout => 10,
    agent   => 'HamClock-Compat/1.0',
);

my $resp = $ua->get($url);
if (!$resp->is_success) {
    print "ERROR=PSK Reporter fetch failed\n";
    exit;
}

my $xml;
eval {
    my $parser = XML::LibXML->new(no_network => 1);
    $xml = $parser->load_xml(string => $resp->decoded_content);
};
if ($@) {
    print "ERROR=Bad XML\n";
    exit;
}

my $now = time();

for my $node ($xml->findnodes('//receptionReport')) {

    my $t = $node->getAttribute('flowStartSeconds') || next;
    next if ($now - $t) > $maxage;

    printf "%d,%s,%s,%s,%s,%s,%d,%d\n",
        $t,
        ($node->getAttribute('senderLocator')   // ''),
        ($node->getAttribute('senderCallsign')  // ''),
        ($node->getAttribute('receiverLocator') // ''),
        ($node->getAttribute('receiverCallsign')// ''),
        ($node->getAttribute('mode')             // ''),
        ($node->getAttribute('frequency')        // 0),
        ($node->getAttribute('sNR')               // 0);
}

