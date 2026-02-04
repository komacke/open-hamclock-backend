#!/usr/bin/perl
use strict;
use warnings;
use CGI;
use LWP::UserAgent;
use XML::LibXML;

# 1. Capture parameters from URL: test.pl?ofgrid=EM77&maxage=900
my $q = CGI->new;
my $ofgrid = $q->param('ofgrid') // '';
my $maxage = $q->param('maxage') // 900;

# Print header for web output
print $q->header('text/plain');

# Basic validation
if (!$ofgrid) {
    print "Error: ofgrid parameter is required.\n";
    exit;
}

# 2. Prepare the API URL
# Removed callback=doNothing to ensure we get XML instead of JSONP
my $flowStartSeconds = $maxage * -1;
my $url = "https://pskreporter.info/cgi-bin/pskquery5.pl?" .
          "noactive=1" .
          "&nolocator=1" .
          "&statistics=1" .
          "&flowStartSeconds=$flowStartSeconds" .
          "&modify=grid" .
          "&senderCallsign=$ofgrid";

# 3. Initialize User Agent
my $ua = LWP::UserAgent->new(
    agent   => 'HamClock-Compat/1.0',
    timeout => 20,
);

# 4. Execute Request
my $response = $ua->get($url);

if ($response->is_success) {
    my $xml_content = $response->decoded_content;

    my $parser = XML::LibXML->new();
    my $xml;
    eval { $xml = $parser->load_xml(string => $xml_content); };
    if ($@) {
        print "Error: PSKReporter returned invalid XML.\n";
        exit;
    }

    my $now = time();

    for my $node ($xml->findnodes('//receptionReport')) {
        my $t = $node->getAttribute('flowStartSeconds') || next;
        next if ($now - $t) > $maxage;

        # Get and format grid squares (Sender and Receiver)
        my $s_grid = uc($node->getAttribute('senderLocator')   // '');
        my $r_grid = uc($node->getAttribute('receiverLocator') // '');

        # Ensure they are exactly 6 characters if possible, otherwise empty
        $s_grid = (length($s_grid) >= 6) ? substr($s_grid, 0, 6) : $s_grid;
        $r_grid = (length($r_grid) >= 6) ? substr($r_grid, 0, 6) : $r_grid;

        # Output in the requested format
        printf "%d,%s,%s,%s,%s,%s,%d,%d\n",
            $t,
            $s_grid,
            ($node->getAttribute('senderCallsign')  // ''),
            $r_grid,
            ($node->getAttribute('receiverCallsign')// ''),
            ($node->getAttribute('mode')             // ''),
            ($node->getAttribute('frequency')        // 0),
            ($node->getAttribute('sNR')              // 0);
    }
} else {
    print "HTTP Error: " . $response->status_line . "\n";
}