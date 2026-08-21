#!/usr/bin/env perl
# A board where nothing is happening is a state somebody can see.
#
# His request, and it is the silence-is-not-compliance shape one level up. Every
# other rule here reports something wrong with a card. This one reports that
# there are no cards doing anything - which no per-card rule can express,
# because it has nothing to attach itself to. A board where every card sits in
# the backlog and none has moved for a day looks, to every rule that exists,
# exactly like a board with nothing wrong.
#
# His words: if there is no activity for a period the agent sets - nothing
# moving, everything sitting in backlog - police asks on the bridge why nothing
# has moved for so long.
#
# And his follow-up, which is the other half: the agent must be able to put it
# down for a while, with a reason, when he and the agent are working something
# out before anything can move. That half already exists - tira.rule.suspend
# takes a duration and a reason, has a ceiling, and comes back by itself - so
# this card adds no second way to do it, and asserts the existing one works
# here.
#
# What counts as movement is decided rather than assumed, and it had to be
# fixed before it could be used. A card created, a field written, a comment,
# an answer, a checklist tick and a column move all stamp last_updated - but
# until TKT-198 a column MOVE did not, because the column is which directory
# the file sits in rather than a field inside it. Built on that stamp before it
# was fixed, this rule would have called a board busy with moves completely
# still, which is the opposite of what he asked for.

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
    name => 'Still', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);

sub reported {
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    return [ grep { $_->{rule} eq 'board-still' } @{ $pass->{violations} } ];
}

# --- an empty board is not a stuck board ---------------------------------------------
#
# Nothing has moved because there is nothing to move. Reporting it would greet
# every new project with a complaint about work nobody has raised yet.

$tira->policy_add( project => $root, rule => 'board-still', age => '4h',
    action => 'bridge-reminder' );

$now = '2026-08-16T09:00:00Z';
is( scalar @{ reported() }, 0, 'a board with no cards at all is not reported' );

# --- a board that has stopped -----------------------------------------------------------

$now = '2026-08-15T09:00:00Z';
my $parked = $tira->create_record( project => $root, type => 'ticket',
    title => 'Raised and then nothing' )->{ref};

$now = '2026-08-15T12:00:00Z';
is( scalar @{ reported() }, 0, 'a board that moved within the period says nothing' );

$now = '2026-08-15T14:00:00Z';
my $found = reported();
is( scalar @{$found}, 1, 'a board where nothing has moved for longer than the period is reported' );
is( $found->[0]{ref}, '',
    'against the board rather than a card, because no card is the one at fault' );

# --- and says how long, and since when --------------------------------------------------
#
# "Nothing is happening" is not actionable on its own. The reader has to be able
# to tell a quiet afternoon from a board abandoned on Friday.

like( $found->[0]{detail}, qr/2026-08-15T09:00/, 'saying when the board last moved' );
like( $found->[0]{detail}, qr/\b5h\b/, 'and how long ago that was, not merely that it is over the limit' );

# --- anything at all counts as movement ---------------------------------------------------
#
# A field written is movement as much as a column change. Otherwise a board
# being worked hard on one card, without moving it, reads as abandoned.

{
    $now = '2026-08-15T14:30:00Z';
    $tira->record_update( project => $root, ref => $parked,
        description => 'somebody wrote something down' );
    is( scalar @{ reported() }, 0, 'writing a field is movement' );

    $now = '2026-08-15T20:00:00Z';
    is( scalar @{ reported() }, 1, 'and once that is old enough, it is reported again' );

    # The one that was not true until TKT-198.
    $now = '2026-08-15T20:30:00Z';
    $tira->record_move(author => 'claude',  project => $root, ref => $parked, column => 'implement' );
    is( scalar @{ reported() }, 0, 'moving a card is movement too' );
}

# --- a board still for days says days ---------------------------------------------------------
#
# The case he described - everything sitting in the backlog, nothing moving -
# is measured in days rather than hours by the time anybody notices. Reporting
# "127h" would be arithmetic rather than an answer.
#
# Added because a coverage run found the days branch of the elapsed formatter
# had never run: every case here was hours long, so the one shape the rule is
# most likely to report in practice was the one nothing exercised.

{
    $now = '2026-08-20T09:00:00Z';
    my $long = reported();
    is( scalar @{$long}, 1, 'a board untouched for days is still reported' );
    like( $long->[0]{detail}, qr/\b4d\b/,
        'and says days rather than counting the hours up' );
}

# --- the newest movement is what counts, not the oldest -------------------------------------
#
# The whole question is when the board LAST did anything, so one busy card keeps
# a board of forgotten ones quiet. Added because mutating the sort from newest
# to oldest changed no verdict: every case above had a single card, so the
# choice this rule is built on had never been asked.

{
    my $two = File::Spec->catdir( $tmp, 'two' );
    my $ledger = File::Spec->catdir( $tmp, 'police-two' );
    $tira->project_new(
        name => 'Two Cards', dir => $two, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'TWS', epic_prefix => 'TWE', ticket_prefix => 'TWT',
    );
    $tira->policy_add( project => $two, rule => 'board-still', age => '4h',
        action => 'bridge-reminder' );

    $now = '2026-08-15T09:00:00Z';
    $tira->create_record( project => $two, type => 'ticket', title => 'Forgotten weeks ago' );

    $now = '2026-08-15T20:00:00Z';
    $tira->create_record( project => $two, type => 'ticket', title => 'Raised just now' );

    my $pass = $tira->police_pass( project => $two, store => $ledger,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'board-still' } @{ $pass->{violations} } ], [],
        'one card moving keeps the board quiet, however long the others have sat' );

    # And when the busy one goes quiet too, the board is stuck on the newest of
    # them rather than on the oldest.
    $now = '2026-08-16T09:00:00Z';
    my $stuck = $tira->police_pass( project => $two, store => $ledger,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    my ($said) = grep { $_->{rule} eq 'board-still' } @{ $stuck->{violations} };
    ok( $said, 'and once the busiest card is old enough, the board is reported' );
    like( $said->{detail}, qr/2026-08-15T20:00/,
        'dated from the newest movement, not the oldest card on the board' );
}

# --- the agent can put it down, with a reason, and it comes back ----------------------------
#
# The half he asked for and the half that already existed. A stretch where he
# and the agent are working something out before anything can move is not a
# stuck board, and the agent says so rather than the rule being switched off.

{
    $now = '2026-08-16T09:00:00Z';
    is( scalar @{ reported() }, 1, 'the board is stuck again' );

    ok( eval {
            $tira->rule_suspend( store => $store, rule => 'board-still',
                seconds => 600, reason => 'planning is not finished, so nothing is meant to move yet' );
            1;
        },
        'the rule can be put down for a while, with a reason' ) or diag($@);

    is( scalar @{ reported() }, 0, 'and it goes quiet' );

    $now = '2026-08-16T09:20:00Z';
    is( scalar @{ reported() }, 1, 'and comes back by itself when the time runs out' );
}

# --- a board that has not declared it hears nothing -------------------------------------------

{
    my $quiet = File::Spec->catdir( $tmp, 'undeclared' );
    my $ledger = File::Spec->catdir( $tmp, 'police-undeclared' );
    $tira->project_new(
        name => 'Undeclared', dir => $quiet, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'UDS', epic_prefix => 'UDE', ticket_prefix => 'UDT',
    );
    $tira->policy_add( project => $quiet, rule => 'discard-unexplained',
        action => 'bridge-reminder' );
    $now = '2026-08-15T09:00:00Z';
    $tira->create_record( project => $quiet, type => 'ticket', title => 'Sitting here' );

    $now = '2026-08-20T09:00:00Z';
    my $pass = $tira->police_pass( project => $quiet, store => $ledger,
        world => { branches => [], worktrees => [], processes => [], containers => [] } );
    is_deeply( [ grep { $_->{rule} eq 'board-still' } @{ $pass->{violations} } ], [],
        'a board that has not declared the rule hears nothing, however long it sits' );
}

# --- and the period is required -------------------------------------------------------------
#
# There is no sensible default for how long a board may be quiet: an hour is
# nothing on a research board and a working day is a crisis on a delivery one.
# Guessing would make this fire wrongly everywhere, so the agent says.

ok( !eval {
        $tira->policy_add( project => $root, rule => 'board-still',
            action => 'bridge-reminder' );
        1;
    },
    'declaring it without a period is refused, because there is no right guess' );

done_testing;

__END__

=head1 NAME

182-a-board-that-has-not-moved.t - a board where nothing happens is visible

=head1 DESCRIPTION

C<board-still> reports a board where nothing has moved for the period the agent
set, saying when it last moved and how long ago. It is the one rule here that is
not about a card: every other rule needs something to attach to, and a board
where every card sits untouched looks to all of them like a board with nothing
wrong.

A card created, a field written or a column moved all count as movement - the
last of those only since TKT-198, which is why this card waited for it. An empty
board is not reported, because nothing has moved for want of anything to move.
The period is required, since an hour is nothing on a research board and a
working day is a crisis on a delivery one.

It can be put down with C<tira.rule.suspend> for the stretch where planning is
still happening and nothing is meant to move, and it comes back by itself.

=cut
