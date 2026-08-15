#!/usr/bin/env perl
# A bridge nobody is reading is a state somebody can see.
#
# This card is about a failure of mine, and the evidence is in this project's
# own logs. unpushed-work raised VIO-0005 at 17:58, escalated it to urgent, and
# it was still open at 19:42 while four commits - including a fix another
# project was waiting on - sat unreleased. He asked why a card said done when it
# was not. The answer had been on the bridge for two hours.
#
# The rule was not broken. The escalation was not broken. Police said it four
# times on the channel built for exactly this, in the words written for it, and
# nobody was listening.
#
# That is the sentence this whole subsystem rests on, turned around: a rule
# nobody reads is the same as a rule that never fired. A board with twenty-seven
# policies and an agent that does not tail the bridge is an unwatched board that
# looks watched, which is worse than no policies at all, because the policies
# read as cover.
#
# It cannot be fixed by resolving to do better, for the same reason
# priority-skipped exists: the party who would have to remember is the party who
# forgot. What can be built is the part that makes the state visible - nothing
# recorded that the bridge had been read, so "nobody is listening" was not a
# fact anybody could observe. Now it is.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-15T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Unheard', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'UNS', epic_prefix => 'UNE', ticket_prefix => 'UNT',
);

# Something for police to say, so the bridge has traffic to be unread.
$tira->policy_add( project => $root, rule => 'discard-unexplained',
    action => 'bridge-reminder' );
my $dropped = $tira->create_record( project => $root, type => 'ticket',
    title => 'Dropped in silence' )->{ref};
$tira->record_move( project => $root, ref => $dropped, column => 'discard' );

sub pass {
    my $result = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    $tira->bridge_write( store => $store, project => $root,
        violations => $result->{violations}, settled => $result->{settled} );
    return $result;
}

sub unread {
    my $result = pass();
    return [ grep { $_->{rule} eq 'bridge-unread' } @{ $result->{violations} } ];
}

# --- a board that has not asked hears nothing ---------------------------------------

is( scalar @{ unread() }, 0, 'a board that has not declared the rule hears nothing' );

$tira->policy_add( project => $root, rule => 'bridge-unread', age => '1h',
    action => 'bridge-reminder' );

# --- a bridge with traffic and nobody reading it --------------------------------------

$now = '2026-08-15T11:00:00Z';
my $found = unread();
is( scalar @{$found}, 1, 'a bridge with something on it and nobody reading is reported' );
is( $found->[0]{ref}, '', 'against the board, because no card is the one at fault' );
like( $found->[0]{detail}, qr/\bnever\b|\bnot been read\b/i,
    'saying the bridge has not been read' );
like( $found->[0]{detail}, qr/policy\.bridge/,
    'and naming the command that reads it, so the reader can act rather than agree' );

# --- reading it is what stops the complaint ---------------------------------------------
#
# Reading means reading. Not marking, not acknowledging, not a flag somebody
# sets - the agent asked for the backlog, which is what tailing the bridge does.

{
    $tira->bridge_backlog( store => $store, lines => 50 );
    is( scalar @{ unread() }, 0, 'once the bridge is read, it says nothing' );

    $now = '2026-08-15T11:30:00Z';
    is( scalar @{ unread() }, 0, 'and stays quiet while the reading is recent' );

    $now = '2026-08-15T13:00:00Z';
    my $again = unread();
    is( scalar @{$again}, 1, 'and returns when nobody has read it for the period again' );
    like( $again->[0]{detail}, qr/2026-08-15T11:00/,
        'saying when it was last read, rather than only that it is stale' );
}

# --- a tail that is running keeps it quiet ----------------------------------------------------
#
# The case that decides whether this rule is usable at all. An agent doing the
# right thing - leaving the bridge tailed while it works - must not be told off
# for it, and the tail polls rather than reading once, so the mark has to move
# with it. If it did not, every correctly-behaving agent would be reported the
# moment its tail outlived the period.

{
    require Tira::CLI;
    $now = '2026-08-15T14:00:00Z';
    is( scalar @{ unread() }, 1, 'the bridge is unread before anybody tails it' );

    # Three rounds of the real follow loop, with the waiting stubbed out and the
    # clock moving on between them, which is what a tail left running looks like.
    my @clock = ( '2026-08-15T15:00:00Z', '2026-08-15T16:00:00Z', '2026-08-15T17:00:00Z' );
    Tira::CLI::_bridge_follow( $tira, $store, rounds => 3,
        sleeper => sub { $now = shift @clock if @clock } );

    is( scalar @{ unread() }, 0,
        'while a tail is running, the bridge is not reported unread' );
}

# --- a bridge with nothing on it is not unread --------------------------------------------
#
# There is nothing to read. Complaining would tell an agent working a quiet
# board to go and look at an empty file, which teaches it to stop looking.

{
    my $quiet = File::Spec->catdir( $tmp, 'quiet' );
    my $ledger = File::Spec->catdir( $tmp, 'police-quiet' );
    $tira->project_new(
        name => 'Quiet', dir => $quiet, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'QTS', epic_prefix => 'QTE', ticket_prefix => 'QTT',
    );
    $tira->policy_add( project => $quiet, rule => 'bridge-unread', age => '1h',
        action => 'bridge-reminder' );

    $now = '2026-08-16T09:00:00Z';
    my $result = $tira->police_pass( project => $quiet, store => $ledger,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'bridge-unread' } @{ $result->{violations} } ], [],
        'a board with nothing on its bridge is not told to go and read it' );
}

# --- and the period is required -------------------------------------------------------------
#
# How long an agent may go without looking is a decision about how it works, not
# something Tira can guess: a minute is absurd on a board polled hourly and a day
# is useless on one being worked now.

ok( !eval {
        $tira->policy_add( project => $root, rule => 'bridge-unread',
            action => 'bridge-reminder' );
        1;
    },
    'declaring it without a period is refused' );

done_testing;

__END__

=head1 NAME

184-a-bridge-nobody-is-reading.t - an unread bridge is visible

=head1 DESCRIPTION

Police raised a violation, escalated it to urgent, and repeated it for two hours
while nobody read the channel it was written to. The rule worked; the reader did
not exist. A board with policies declared and an agent that does not tail the
bridge is an unwatched board that looks watched.

Nothing recorded that the bridge had been read, so "nobody is listening" was not
a fact anybody could observe. Reading it now leaves a mark, and C<bridge-unread>
reports a bridge that has something on it and has not been read for the period
the agent set - naming the command that reads it, and when it was last read.

A bridge with nothing on it is not reported: there is nothing to read, and
sending an agent to look at an empty file teaches it to stop looking.

=cut
