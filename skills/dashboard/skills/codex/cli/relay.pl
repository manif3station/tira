#!/usr/bin/env perl

use strict;
use warnings;
use DateTime;

# 1. Retrieve the Session ID
my $session_id = $ENV{D2TG_CODEX_SESSION_ID};

die "Error: D2TG_CODEX_SESSION_ID environment variable is not set.\n"
  if !defined $session_id && length $session_id;

print "[Bridge] Session ID: $session_id\n";

# 2. Enable autoflush for the script's own output (optional log)
$| = 1;

open my $fh, '-|', qw(d2 tira.dashboard) or die "Error: $!";

my $dt = DateTime->now( time_zone => 'Europe/London' );

while ( my $line = <$fh> ) {
    chomp($line);

    # Skip empty lines to prevent spamming empty prompts
    next if $line =~ /^\s*$/;

    my ( %record_date, %now );

    @record_date{qw(year month day hour)} =
      $line =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2})/;

    @now{qw(year month day hour minute second)} =
      ( $dt->year, $dt->month, $dt->day, $dt->hour );

# Skip lines if record not today in this hour or less than this hour. equal is fine.
    next
      if $record_date{year} != $now{year}
      || $record_date{month} != $now{month}
      || $record_date{day} != $now{day}
      || $record_date{hour} < $now{hour};

    # Optional: Print feedback to Terminal 2
    print "[Bridge] Forwarding: $line\n";

    # 4. Execute the command securely
    # usage: system(program, arg1, arg2, ...)
    system( 'codex', 'queue', '--thread', $session_id, '--message', $line );
}
