#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $store = File::Spec->catdir( $tmp, 'police-state' );

sub log_lines {
    my $path = $tira->bridge_log_path( store => $store );
    return () if !-f $path;
    open my $fh, '<:raw', $path or die "$path: $!";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}

sub say_it {
    my (@violations) = @_;
    return $tira->bridge_write( store => $store, violations => \@violations );
}

sub violation {
    my (%args) = @_;
    return {
        id => 'VIO-0001', rule => 'card-stalled', ref => 'TKT-005',
        detail => 'every checklist item is done but the card is still in implement',
        action => 'bridge-reminder', tone => 'note', seen => 1, %args,
    };
}

# --- the log is police's own ----------------------------------------------

# The agent reaches it through the bridge and nowhere else. It is not in the
# project, because police never writes to the board.
my $path = $tira->bridge_log_path( store => $store );
like( $path, qr/\Q$store\E/, 'the log lives in police\'s own store' );
unlike( $path, qr/\.tira/, 'and nowhere near the project' );

# --- what police says -----------------------------------------------------

say_it( violation() );
my @said = log_lines();
is( scalar @said, 1, 'a violation is written as one line' );
like( $said[0], qr/VIO-0001/, 'carrying its number' );
like( $said[0], qr/TKT-005/, 'and the card' );
like( $said[0], qr/still in implement/, 'and what is wrong' );
like( $said[0], qr/2026-08-11T09:00:00Z/, 'and when it was said' );

# An LLM reads this, so it has to be one line and machine-readable. A
# paragraph costs tokens on every pass and gets skimmed rather than parsed.
unlike( $said[0], qr/\n/, 'on a single line, because an agent parses these' );
like( $said[0], qr/fix:/, 'and it says what to do rather than only what is wrong' );

# --- only what was asked for ----------------------------------------------

# An action of log-only is for a rule being tuned: recorded, but not put in
# front of anybody.
say_it( violation( id => 'VIO-0002', action => 'log-only' ) );
my @after_quiet = log_lines();
is( scalar @after_quiet, 1, 'a log-only violation is not written to the bridge' );

# print-reminder is for the owner's terminal, not the agent's bridge.
say_it( violation( id => 'VIO-0003', action => 'print-reminder' ) );
is( scalar( log_lines() ), 1, 'and neither is one meant for the owner\'s terminal' );

say_it( violation( id => 'VIO-0004' ) );
is( scalar( log_lines() ), 2, 'while a bridge-reminder is' );

# --- the tone shows -------------------------------------------------------

# One problem getting louder has to LOOK louder, or the ladder is bookkeeping
# nobody sees.
say_it( violation( id => 'VIO-0005', tone => 'critical', seen => 5 ) );
my @loud = log_lines();
like( $loud[-1], qr/critical/i, 'the tone appears in the line' );
like( $loud[-1], qr/\b5\b/, 'and so does how many times it has been said' );

# --- the agent's own message ----------------------------------------------

say_it( violation( id => 'VIO-0006',
    message => 'this card has been in implement for more than ten minutes' ) );
like( ( log_lines() )[-1], qr/more than ten minutes/,
    'a policy\'s own message is used rather than one Tira invented' );

# --- nothing to say -------------------------------------------------------

my $quiet_before = scalar log_lines();
say_it();
is( scalar( log_lines() ), $quiet_before,
    'a pass with nothing wrong writes nothing at all, rather than saying it is fine' );

# --- police speaking about itself -----------------------------------------

# When police cannot work out which policy applies, it says so rather than
# guessing. A wrong police is worse than a hesitant one.
$tira->bridge_write( store => $store, notices => [
    { kind => 'unresolved', detail => 'POL-003 names a column that is not on this board' } ] );
like( ( log_lines() )[-1], qr/POL-003/, 'police can say when it is unsure' );
like( ( log_lines() )[-1], qr/unresolved/i, 'and says that is what it is' );

# --- surviving the log being replaced -------------------------------------

# The bridge follows the file by name, so a rotated or recreated log does not
# silently stop the stream - which would leave the agent believing all is well.
unlink $path;
say_it( violation( id => 'VIO-0007' ) );
my @after_rotation = log_lines();
is( scalar @after_rotation, 1, 'police recreates the log if it is taken away' );
like( $after_rotation[0], qr/VIO-0007/, 'and carries on saying what it has to say' );

# --- what the bridge shows on arrival -------------------------------------

# Starting the bridge after something has already gone wrong must show what is
# outstanding, not only what happens next. Otherwise an agent that restarts its
# bridge is blind to everything already said.
say_it( violation( id => 'VIO-0008' ), violation( id => 'VIO-0009' ) );
my $backlog = $tira->bridge_backlog( store => $store, lines => 2 );
is( scalar @{$backlog}, 2, 'the bridge can show what was already said' );
like( $backlog->[-1], qr/VIO-0009/, 'ending with the most recent' );

done_testing;

__END__

=head1 NAME

83-policy-bridge.t - TKT-018 the one-way channel from police to the agent

=head1 DESCRIPTION

Police writes to a log it owns; the agent tails it and acts. One way: police
speaks, the agent listens, nothing comes back. It is the shape of the Telegram
bridge, which is the pattern that already works here.

Every line is one line, because an LLM reads them and a paragraph costs tokens
on every pass and gets skimmed rather than parsed. Each carries the number, the
card, what is wrong, when, how loudly, and what to do about it - the last of
those matters most, since a warning without a fix is a warning that gets
deferred.

Only what was asked for reaches the bridge. A rule set to log-only is being
tuned and stays out of the way; one set to print-reminder belongs in the
owner's terminal instead. A pass with nothing wrong writes nothing at all,
rather than announcing that everything is fine - silence is the signal.

The log is recreated if it is taken away, because a stream that stops silently
leaves the agent believing all is well, which is the worst failure this channel
could have.

=cut
