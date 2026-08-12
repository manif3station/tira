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

# Police keeps its own state, outside the project it is watching. That is not
# tidiness: a ledger inside the board would make police a second writer, and
# two writers on one board is what destroyed this project's board on the day
# this was designed.
my $store = File::Spec->catdir( $tmp, 'police-state' );

sub seen {
    my (@violations) = @_;
    return $tira->violation_record( store => $store, violations => \@violations );
}

sub condition {
    my (%args) = @_;
    return {
        rule => 'card-stalled', policy => 'POL-001', ref => 'TKT-001',
        detail => 'every checklist item is done but the card is still in implement',
        action => 'bridge-reminder', %args,
    };
}

# --- a violation gets a number -------------------------------------------

my $first = seen( condition() );
is( scalar @{$first}, 1, 'one condition makes one violation' );
like( $first->[0]{id}, qr/\AVIO-\d{4}\z/, 'which is given a number of its own' );
is( $first->[0]{seen}, 1, 'seen once' );
is( $first->[0]{first_seen}, '2026-08-11T09:00:00Z', 'and remembers when it started' );

# --- the same problem again keeps its number ------------------------------

# One persistent problem must read as one problem getting louder. Fifty
# numbers for one condition is noise, and noise is what gets ignored.
at('2026-08-11T09:01:00Z');
my $again = seen( condition() );
is( $again->[0]{id}, $first->[0]{id}, 'the same condition keeps its number' );
is( $again->[0]{seen}, 2, 'and counts the repeat' );
is( $again->[0]{first_seen}, '2026-08-11T09:00:00Z', 'while still remembering when it started' );
is( $again->[0]{last_seen}, '2026-08-11T09:01:00Z', 'and when it was last true' );

my $other = seen( condition(), condition( ref => 'TKT-002' ) );
my %ids = map { $_->{ref} => $_->{id} } @{$other};
isnt( $ids{'TKT-002'}, $ids{'TKT-001'}, 'a different card is a different violation' );

my $other_rule = seen( condition(), condition( rule => 'orphan-card' ) );
is( scalar @{$other_rule}, 2, 'and so is a different rule on the same card' );

# --- the tone rises -------------------------------------------------------

my $fresh_store = File::Spec->catdir( $tmp, 'tone' );
my @tones;
for my $pass ( 1 .. 6 ) {
    at( sprintf '2026-08-11T10:%02d:00Z', $pass );
    my $view = $tira->violation_record( store => $fresh_store, violations => [ condition() ] );
    push @tones, $view->[0]{tone};
}
is( $tones[0], 'note', 'the first time is only a note' );
isnt( $tones[3], $tones[0], 'by the fourth it is not being said the same way' );
is( $tones[5], 'critical', 'and by the sixth it is critical' );
is_deeply( [ @tones[ 0 .. 5 ] ], [ sort { _rank($a) <=> _rank($b) } @tones[ 0 .. 5 ] ],
    'the tone only ever climbs, so a problem never quietly softens' );

sub _rank {
    my %order = ( note => 0, warning => 1, urgent => 2, critical => 3 );
    return $order{ $_[0] } // -1;
}

# --- past five, it reaches the owner --------------------------------------

my $escalating = File::Spec->catdir( $tmp, 'escalate' );
my @escalated;
for my $pass ( 1 .. 6 ) {
    at( sprintf '2026-08-11T11:%02d:00Z', $pass );
    my $view = $tira->violation_record( store => $escalating, violations => [ condition() ] );
    push @escalated, $view->[0]{escalate} ? 1 : 0;
}
is_deeply( \@escalated, [ 0, 0, 0, 0, 1, 0 ],
    'the fifth repeat is the one that reaches the terminal, and it is said once' );

my $view = $tira->violation_record( store => $escalating, violations => [ condition() ] );
my $notice = $view->[0];
like( $notice->{terminal}, qr/\Q$notice->{id}\E/, 'the terminal notice carries the issue number' );
like( $notice->{terminal}, qr/TKT-001/, 'and the card' );
like( $notice->{terminal}, qr/2026-08-11/, 'and when' );
like( $notice->{terminal}, qr/still in implement/, 'and what happened' );
like( $notice->{terminal}, qr/d2 tira\./,
    'and a command the owner can hand on, rather than a description of one' );

# --- fixed means silent, with nothing to dismiss --------------------------

# Anything an agent has to remember to dismiss becomes something an agent
# dismisses without reading.
at('2026-08-11T12:00:00Z');
my $cleared = seen();
is_deeply( $cleared, [], 'a condition that is no longer true stops being reported at once' );

# --- and if it comes back, it is the same problem -------------------------

at('2026-08-11T12:30:00Z');
my $returned = seen( condition() );
is( $returned->[0]{id}, $first->[0]{id},
    'the same problem returning reopens its original number' );
ok( $returned->[0]{seen} > 1, 'keeping the history of how often it has happened' );
is( $returned->[0]{returned}, 1, 'and saying that it came back rather than pretending it is new' );

# --- surviving a restart --------------------------------------------------

# Police is meant to be left running for days. If a restart reset the counts,
# a persistent problem would never reach five and the escalation would be
# decoration.
{
    my $restarted = Tira->new( clock => sub {$now} );
    at('2026-08-11T12:31:00Z');
    my $after = $restarted->violation_record( store => $store, violations => [ condition() ] );
    is( $after->[0]{id}, $first->[0]{id}, 'a new process knows the violation by its old number' );
    ok( $after->[0]{seen} > 2, 'and continues the count rather than starting over' );
}

# --- numbers are never reused --------------------------------------------

my $counted = File::Spec->catdir( $tmp, 'numbers' );
my $one = $tira->violation_record( store => $counted, violations => [ condition() ] );
$tira->violation_record( store => $counted, violations => [] );
my $two = $tira->violation_record( store => $counted,
    violations => [ condition( ref => 'TKT-009' ) ] );
isnt( $two->[0]{id}, $one->[0]{id},
    'a different problem after one closed takes a new number, never a freed one' );

# --- the ledger is police's own, not the board's -------------------------

ok( -d $store, 'police keeps its state where it said it would' );
my $project = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Watched', dir => $project, members => ['michael'],
    columns => ['backlog, implement'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);
my @inside = glob File::Spec->catfile( $project, '.tira', '*violation*' );
is( scalar @inside, 0, 'and nothing about violations is written into the project' );

done_testing;

__END__

=head1 NAME

81-violations.t - TKT-016 one problem getting louder, rather than fifty problems

=head1 DESCRIPTION

The owner's shape: every violation carries a number, the same condition keeps
that number and accumulates on it, the tone rises as it persists, and past five
repeats it reaches his own terminal with everything he needs to act - including
a command he can paste straight to the agent.

The reason it matters is that a warning system dies by repetition. Fifty
numbers for one condition is noise, and noise is what gets ignored; one number
getting louder is a fact. So the tone is checked to only ever climb, and the
terminal notice is checked to arrive once rather than on every pass after the
fifth.

Fixing the cause silences it immediately, with nothing to acknowledge and
nothing to clear by hand - anything an agent must remember to dismiss becomes
something an agent dismisses without reading. If the same problem returns it
reopens its original number and says that it came back, because a recurring
problem is worth seeing as recurring.

The ledger lives in police's own store rather than in the project. That is not
tidiness: a ledger inside the board would make police a second writer, and two
writers on one board is what destroyed this project's own board on the day this
was designed.

=cut
