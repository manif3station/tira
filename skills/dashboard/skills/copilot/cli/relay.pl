#!/usr/bin/env perl

use strict;
use warnings;
use DateTime;

# ============================================================================
# D2TG -> GitHub Copilot CLI live relay
#
# PURPOSE
#   Terminal 1:
#       Run Copilot CLI interactively inside tmux.
#
#   Terminal 2:
#       Run this relay.
#
#   Every qualifying line produced by:
#       d2 tira.dashboard
#
#   is typed into the EXISTING Copilot CLI running in Terminal 1.
#
#   The relay uses Ctrl+Q after typing the message. In Copilot CLI this queues
#   the message as the next turn instead of steering the currently-running turn.
#
# REQUIREMENTS
#   - Perl
#   - DateTime Perl module
#   - tmux
#   - Copilot CLI
#
# TERMINAL 1 EXAMPLE
#
#   tmux new-session -A -s copilot
#   copilot
#
# If exactly one tmux pane is currently running "copilot", this script finds it
# automatically.
#
# If you have more than one Copilot pane, set the pane explicitly in Terminal 2:
#
#   tmux list-panes -a -F '#{pane_id}  #{session_name}:#{window_index}.#{pane_index}  #{pane_current_command}'
#   export D2TG_COPILOT_TMUX_PANE='%3'
#   ./d2tg-copilot-relay.pl
#
# Optional, for logging only:
#
#   export D2TG_COPILOT_SESSION_ID='...'
#
# ============================================================================

$| = 1;

my $session_id = $ENV{D2TG_COPILOT_SESSION_ID} // '';
my $target_pane =
  $ENV{D2TG_COPILOT_TMUX_PANE} // find_single_tmux_pane('copilot');

validate_tmux_pane($target_pane);

print "[Bridge] Agent: Copilot CLI\n";
print "[Bridge] Target tmux pane: $target_pane\n";
print "[Bridge] Session ID: $session_id\n" if length $session_id;
print "[Bridge] Submit mode: Ctrl+Q queue\n";
print "[Bridge] Starting dashboard relay...\n";

open my $fh, '-|', qw(d2 tira.dashboard)
  or die "Error: unable to run 'd2 tira.dashboard': $!\n";

while ( my $line = <$fh> ) {
    chomp $line;
    $line =~ s/\r$//;

    # Skip empty lines.
    next if $line =~ /^\s*$/;

    # Dashboard records are expected to begin with / contain:
    #     YYYY-MM-DDTHH
    #
    # Ignore anything that does not contain that timestamp shape.
    my ( $year, $month, $day, $hour ) =
      $line =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2})/;

    if ( !defined $year ) {
        print "[Bridge] Skipping line without timestamp: $line\n";
        next;
    }

    # Recalculate London time for every line so a long-running relay continues
    # to behave correctly when the hour/day changes.
    my $dt = DateTime->now( time_zone => 'Europe/London' );

    # Preserve the behaviour of the original Codex bridge:
    #   - record must be from today
    #   - record hour must be the current hour or later
    next
      if $year  != $dt->year
      || $month != $dt->month
      || $day   != $dt->day
      || $hour  <  $dt->hour;

    print "[Bridge] Queueing to Copilot: $line\n";

    send_literal_to_pane( $target_pane, $line );

    # Copilot CLI:
    #   Ctrl+Q = queue this input as the next turn.
    #
    # This is deliberately NOT Enter. While Copilot is already working,
    # Enter is a steering message and can be folded into the current turn.
    send_key_to_pane( $target_pane, 'C-q' );
}

close $fh;

if ( $? != 0 ) {
    my $exit = $? >> 8;
    die "[Bridge] 'd2 tira.dashboard' exited with status $exit\n";
}

exit 0;

sub find_single_tmux_pane {
    my ($wanted_command) = @_;

    my @matches;

    open my $tmux, '-|',
      'tmux', 'list-panes', '-a',
      '-F', '#{pane_id}\t#{pane_current_command}'
      or die "Error: unable to run tmux. Is tmux installed and running? $!\n";

    while ( my $row = <$tmux> ) {
        chomp $row;

        my ( $pane, $command ) = split /\t/, $row, 2;
        next if !defined $pane || !defined $command;

        $command =~ s!.*/!!;

        push @matches, $pane
          if lc($command) eq lc($wanted_command);
    }

    close $tmux;

    if ( !@matches ) {
        die <<"ERROR";
Error: no tmux pane running '$wanted_command' was found.

Start Copilot in Terminal 1 inside tmux, for example:

    tmux new-session -A -s copilot
    copilot

Then run this relay from Terminal 2.

If Copilot is already running in tmux, inspect the panes with:

    tmux list-panes -a -F '#{pane_id}  #{session_name}:#{window_index}.#{pane_index}  #{pane_current_command}'

Then set:

    export D2TG_COPILOT_TMUX_PANE='%N'

ERROR
    }

    if ( @matches > 1 ) {
        die "Error: multiple Copilot tmux panes found: "
          . join( ', ', @matches )
          . "\nSet D2TG_COPILOT_TMUX_PANE to the required pane, e.g. '%3'.\n";
    }

    return $matches[0];
}

sub validate_tmux_pane {
    my ($pane) = @_;

    system(
        'tmux', 'display-message',
        '-p', '-t', $pane,
        '#{pane_id}'
    );

    if ( $? != 0 ) {
        die "Error: tmux pane '$pane' does not exist or is not accessible.\n";
    }
}

sub send_literal_to_pane {
    my ( $pane, $text ) = @_;

    # -l means literal text: tmux will not interpret text such as "Enter",
    # "C-c", etc. as key names.
    system( 'tmux', 'send-keys', '-t', $pane, '-l', $text );
    sleep 3;
    system( 'tmux', 'send-keys', '-t', $pane, 'C-q' );
    sleep 3;
    system( 'tmux', 'send-keys', '-t', $pane, 'Enter' );

    if ( $? != 0 ) {
        my $exit = $? >> 8;
        die "[Bridge] tmux failed while sending text; exit status $exit\n";
    }
}

sub send_key_to_pane {
    my ( $pane, $key ) = @_;

    system( 'tmux', 'send-keys', '-t', $pane, $key );

    if ( $? != 0 ) {
        my $exit = $? >> 8;
        die "[Bridge] tmux failed while sending key '$key'; exit status $exit\n";
    }
}
