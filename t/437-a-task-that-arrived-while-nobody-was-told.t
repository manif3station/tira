#!/usr/bin/env perl
# The owner adds tasks as his main way of handing the agent work, and police says
# nothing when one appears.
#
# He asked on 2026-08-27: "why police didn't announce any new task created?
# broken? missing policy?" Neither - task-changed is declared and firing. And he
# asked again on 2026-08-29 about TSK-318, because the card raised off the first
# question was still in the backlog. Filing is not answering.
#
# THE BRANCH DOES NOT EXIST. lib/Tira.pm:8834:
#
#     my $was = $seen->{ $item->{id} };
#     if ($was) { ...report changes... }
#     $next_seen{ $item->{id} } = $now_state;
#
# No $was means no report, and the last line writes the item into the baseline
# anyway. The first pass after an addition adopts it silently; every later pass
# compares against that adopted state and finds nothing changed. A new task is
# not announced late - it is unannounceable.
#
# WHY THIS IS NOT ONE MISSING else. On a board with an existing tasklist and an
# empty ledger, EVERY item is a first sighting, so the naive fix announces a
# hundred at once - and a rule that does that is declined and never re-enabled,
# which is worse than the silence. The ledger already carries what separates the
# two cases: _violation_ledger returns { counter => 0, open => {} } for a store
# nothing has written, with NO task_seen key, and _task_changed_mark_seen is the
# only thing that sets one. So a missing key means "no baseline, adopt once" and
# a present key means "an unknown id is genuinely new". The `// {}` at line 8825
# flattens those two into one and is what has to change.
#
# t/399 ALREADY ASSERTS THE FIRST HALF and stays green: "a freshly-added item is
# not reported - no prior state to differ from" is a first pass on a fresh store,
# which is exactly the case that must keep adopting silently. This file is about
# the second half, which nothing tests because nothing does it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-08-29T09:00:00Z'} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police-store' );

$tira->project_new(
    name => 'Arrived', dir => $root, members => ['claude'],
    columns    => ['backlog, implement, done'],
    sow_prefix => 'AS', epic_prefix => 'AE', ticket_prefix => 'AT',
);
$tira->policy_add( project => $root, rule => 'task-changed', action => 'bridge-reminder' );

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'task-changed' } @{ $pass->{violations} } ];
}

# --- the first pass on a board that already has tasks stays quiet -------------
#
# The trap, asserted before the fix it constrains. Three tasks exist and no pass
# has ever run, so all three are first sightings. A rule that announced them
# would be right about the data and useless in practice.

$tira->tasklist_add( project => $root, text => 'one that was already here' );
$tira->tasklist_add( project => $root, text => 'and another' );
$tira->tasklist_add( project => $root, text => 'and a third' );

is( scalar @{ findings() }, 0,
    'the first pass on a board that already has tasks announces none of them - '
      . 'a rule that reported a hundred at once would be declined and never '
      . 're-enabled' );

# --- and a second pass, with nothing added, stays quiet -----------------------

is( scalar @{ findings() }, 0,
    'and a second pass with nothing new says nothing' );

# --- THE CARD. A task added after that IS announced ---------------------------

my $arrived = $tira->tasklist_add( project => $root, text => 'the one he just added' );
my @after = @{ findings() };

is( scalar @after, 1,
    'a task added to a board police has already seen is announced - which is '
      . 'the question he asked twice' );
like( ( $after[0]{detail} // '' ), qr/\Q$arrived->{id}\E|new|added/i,
    'and the finding names it, so the agent can go and look at it - said: '
      . ( $after[0]{detail} // '(nothing)' ) );

# --- it is announced once, not on every pass afterwards -----------------------
#
# The control that stops the fix becoming a different noise problem: an
# announcement that repeats every thirty seconds is the shape card-duration wore
# when it fired sixty-three times with no action available.

# Guarded on the arrival having been announced at all. Without that, this is
# satisfied by a rule that never announces anything - which is the state being
# fixed, passing a test about the fix.
ok( scalar(@after) == 1 && scalar @{ findings() } == 0,
    'and only once - the pass that announced it recorded it, so the next pass '
      . 'has nothing new to say' );

# --- a task that DISAPPEARS is announced too ----------------------------------
#
# The other half, found while re-diagnosing this card: %still_here is declared at
# lib/Tira.pm:8826 and populated at 8829 and never read anywhere in the file. The
# removal check was written and abandoned, so a task vanishing is unannounced by
# the same silence that swallows a new one.

$tira->tasklist_remove( project => $root, id => $arrived->{id} );
my @gone = @{ findings() };

is( scalar @gone, 1, 'a task that disappears is announced' );
like( ( $gone[0]{detail} // '' ), qr/\Q$arrived->{id}\E|remov|gone|disappear/i,
    'and names which one, since a list that is one shorter says nothing on its '
      . 'own - said: ' . ( $gone[0]{detail} // '(nothing)' ) );

# --- and the change reporting that already worked still works -----------------
#
# The control. This rule's existing job is to report edits to items it knows, and
# a fix that reported arrivals while losing edits would be a trade, not a fix.

my $known = $tira->tasklist_add( project => $root, text => 'something to edit' );
findings();    # let the arrival be announced and recorded
$tira->tasklist_update( project => $root, id => $known->{id}, text => 'edited wording' );
my @edited = @{ findings() };

is( scalar @edited, 1, 'an edit to a known task is still reported' );
like( ( $edited[0]{detail} // '' ), qr/text/i,
    'and still says what changed about it - said: '
      . ( $edited[0]{detail} // '(nothing)' ) );

done_testing();

__END__

=head1 NAME

t/437-a-task-that-arrived-while-nobody-was-told.t - police must announce a task
that appears, and one that disappears

=head1 DESCRIPTION

C<task-changed> reports edits to tasklist items it has already seen. A brand-new
item has nothing to compare against, so the branch is skipped - and the line
after it writes the item into the baseline anyway, so every later pass finds
nothing changed. A new task is not announced late; it is unannounceable.

The owner asked why on 2026-08-27 and again on 2026-08-29, because the card
raised off the first question was still in the backlog.

=head2 The trap this file constrains

On a board with an existing tasklist and an empty ledger, every item is a first
sighting. A rule that announced them all would be declined and never re-enabled,
which is worse than the silence. So the first assertion here is that a first pass
says nothing, and it must stay green.

What separates the two cases already exists: a store nothing has written has no
C<task_seen> key at all, and C<_task_changed_mark_seen> is the only thing that
sets one. A missing key means adopt once; a present key means an unknown id is
genuinely new.

=head2 The removal half

C<%still_here> is declared and populated in the same rule and never read. The
check was written and abandoned, so a task vanishing is unannounced by the same
silence. Both halves are asserted here because both are one idea: the tasklist
changed and nobody was told.

=cut
