#!/usr/bin/perl
# HamClock Diagnostic Receiver
# Copyright (C) 2026 OHB Team
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# Accepts POST /ham/HamClock/diagnostic-logs/dl-<ts>-<ip>-<chip>.txt
# and saves the body to /opt/hamclock-backend/upload-diags/

use strict;
use warnings;
use File::Spec;
use File::Basename;

# --- Configuration ---
my $UPLOAD_DIR = '/opt/hamclock-backend/upload-diags';
my $MAX_FILE_SIZE = 1024 * 1024;    # 1 MB limit per file
my $MIN_FREE_KB   = 2048;           # Keep at least 2 MB free as a buffer

# Matches: HamClock-[id]/[n].[n] OR HamClock-[id]/[n].[n]b[dd]
my $user_agent = $ENV{'HTTP_USER_AGENT'} || '';
unless ($user_agent =~ /^HamClock-.*\/(\d+)\.(\d+)(b\d{2})?(\s+|$)/i) {
    print "Status: 404 Not Found\n";
    print "Content-Type: text/html\n\n";
    print "<html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>";
    exit;
}

# 1. Extract filename from the request
my $request_uri = $ENV{'REQUEST_URI'} || '';
my $filename = basename((split(/\?/, $request_uri))[0]);

# Validation: ensure it looks like a HamClock log
if (!$filename || $filename !~ /^dl-.*\.txt$/) {
    print "Status: 404 Not Found\n";
    print "Content-Type: text/html\n\n";
    print "<html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>";
    exit;
}

# 2. Pre-check file size from Headers
my $content_length = $ENV{'CONTENT_LENGTH'} || 0;
if ($content_length > $MAX_FILE_SIZE) {
    print "Status: 413 Request Entity Too Large\n\nFile exceeds 1MB limit";
    exit;
}

# 3. Clean up tmpfs if space is low
manage_storage($content_length);

# 4. Save the file
my $filepath = File::Spec->catfile($UPLOAD_DIR, $filename);
open(my $fh, '>', $filepath) or die "Status: 500 Internal Error\n\nCould not open file: $!";
binmode $fh;

my $buffer;
while (read(STDIN, $buffer, 4096)) {
    print $fh $buffer;
}
close($fh);

# 5. Success response for HamClock
print "Status: 201 Created\n";
print "Content-Type: text/plain\n\n";
print "Stored $filename";

# --- Helper Functions ---

sub manage_storage {
    my ($incoming_bytes) = @_;
    my $incoming_kb = int($incoming_bytes / 1024) + 1;
    
    while (1) {
        # Get available KB on the tmpfs mount
        # 'df -k' returns size in 1024-byte blocks
        my @df_out = `df -k $UPLOAD_DIR`;
        my (undef, undef, undef, $avail) = split(/\s+/, $df_out[1]);

        # Stop deleting if we have enough space for the new file + our safety buffer
        last if ($avail > ($incoming_kb + $MIN_FREE_KB));

        # Identify oldest files: sort by modified time (mtime)
        my @files = sort { (stat($a))[9] <=> (stat($b))[9] } 
                    glob(File::Spec->catfile($UPLOAD_DIR, 'dl-*.txt'));

        if (@files) {
            unlink $files[0]; 
        } else {
            last; # No more files left to delete
        }
    }
}
