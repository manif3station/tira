#!/usr/bin/env perl
# TKT-682. tasklist_task_ref_link stored whatever --ref string it was given,
# with no check that a record by that name actually exists on the board - a
# typo'd or invented ref was accepted silently, and read back afterwards as
# if it were a real link. That is worse than an unlinked task: task-unlinked
# falls silent the moment ANY ref is stored, whether or not the ref means
# anything, so a bad ref does not just fail to help - it actively hides the
# gap it was meant to close.
#
# link_add already refuses this the same way, via _record_data - this gives
# tasklist_task_ref_link the same guarantee.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $now  = '2026-08-31T14:00:00+0100';
my $tira = Tira->new( clock => sub {$now} );
$tira->project_new(
    name => 'Linked', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'working' ],
    sow_prefix => 'LKS', epic_prefix => 'LKE', ticket_prefix => 'LKT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Real card' );
my $task = $tira->tasklist_add( project => $root, text => 'Needs linking' );

# --- the bug: a ref to nothing is accepted and stored -----------------------

my $ok = eval {
    $tira->tasklist_task_ref_link( project => $root, id => $task->{id}, refs => ['LKT-999'] );
    1;
};
ok( !$ok, 'linking a task to a ref that does not exist is refused' );
like( $@, qr/LKT-999/, 'the refusal names the ref that was not found' );

my $unchanged = $tira->tasklist_list( project => $root )->[0];
is_deeply( $unchanged->{refs}, [], 'the task is left unchanged - no partial link was written' );

# --- ref validation never outranks the session-ownership check -------------
# (caught in review by t/397/TKT-538: linking a bogus ref onto ANOTHER
# session's item must still fail with "No task", not a ref-not-found error -
# the caller was never entitled to touch the item at all, so what the ref
# names is not this refusal's business.)

$ok = eval {
    $tira->tasklist_task_ref_link(
        project => $root, id => $task->{id}, refs => ['LKT-777'], session => 'somebody-else' );
    1;
};
ok( !$ok, 'linking onto a different session\'s item is refused' );
like( $@, qr/\ANo task/, 'as a session problem, not a ref problem - even though the ref is also bogus' );

# --- a real ref still links normally ----------------------------------------

$tira->tasklist_task_ref_link( project => $root, id => $task->{id}, refs => [ $card->{ref} ] );
my $linked = $tira->tasklist_list( project => $root )->[0];
is_deeply( $linked->{refs}, [ $card->{ref} ], 'a ref to a real card links exactly as before' );

# --- task-unlinked now names the command that actually exists --------------

$tira->policy_add( project => $root, rule => 'task-unlinked', age => '1m', action => 'bridge-reminder' );
my $unlinked_task = $tira->tasklist_add( project => $root, text => 'Still needs a home' );
$now = '2026-08-31T14:05:00+0100';
my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'store' ), world => {} );
my ($finding) = grep { ( $_->{rule} // '' ) eq 'task-unlinked' } @{ $pass->{violations} };
like( $finding->{detail}, qr/tira\.tasklist\.task\.ref\.link --id \Q$unlinked_task->{id}\E --ref REF/,
    "task-unlinked names the command that links it, not just 'link it to one'" );


# --- one bad ref among several good ones refuses the whole call, nothing ----
# partially applied - "the task is unchanged" means all of it, not most of it.

my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Second real card' );
my $task2 = $tira->tasklist_add( project => $root, text => 'Mixed refs' );
$ok = eval {
    $tira->tasklist_task_ref_link(
        project => $root, id => $task2->{id}, refs => [ $card2->{ref}, 'LKT-404' ] );
    1;
};
ok( !$ok, 'a mix of one good and one bad ref is still refused' );
like( $@, qr/LKT-404/, 'naming the bad one, not the good one' );
my $still_empty = ( grep { $_->{id} eq $task2->{id} } @{ $tira->tasklist_list( project => $root ) } )[0];
is_deeply( $still_empty->{refs}, [], 'the good ref was not partially applied either' );

# --- unlink is unaffected: removing a ref, bad or gone, is always safe -----

$tira->tasklist_task_ref_link( project => $root, id => $task2->{id}, refs => [ $card2->{ref} ] );
ok( eval {
    $tira->tasklist_task_ref_unlink( project => $root, id => $task2->{id}, refs => ['LKT-777'] );
    1;
}, 'unlinking a ref that was never valid does not refuse - there is nothing to protect against' );

# --- deliberately NOT extended to creation (tasklist_add/unshift/slice) ---
# Considered during review and rejected: a ref naming no card is an
# accepted, tested state at creation elsewhere on this board (see
# t/419-a-queue-that-disagrees-with-the-board.t's QTK-404 fixture, which
# exists specifically to prove a downstream policy stays silent about a
# card nobody can open). Linking is a considered claim; a fresh task
# naming a not-yet-real card is the ordinary case this ticket exists to
# let get linked LATER, once the card exists.

$ok = eval { $tira->tasklist_add( project => $root, text => 'Not yet real', refs => ['LKT-888'] ); 1 };
ok( $ok, 'tasklist_add still accepts a ref naming no card - creation is unvalidated on purpose' );

done_testing;

__END__

=head1 NAME

t/456-a-link-that-points-nowhere.t - tasklist_task_ref_link refuses a ref
to a card that does not exist

=head1 DESCRIPTION

TKT-682 (corrected scope, see the card's own comments/solution_needed):
tasklist.task.ref.link already existed before this card was filed, but
neither it nor tasklist.task.ref.unlink checked that a C<--ref> actually
named a record on the board. A typo'd or invented ref was stored exactly
like a real one, and C<task-unlinked> falls silent the moment any ref is
present - so a bad ref is a worse outcome than no ref at all: it looks
solved and is not.

Fixed by validating every ref through the same C<_record_data> lookup
C<link_add> already uses, refusing the whole call and naming the ref that
was not found if any one of them fails - nothing is partially applied.

A Codex review on this card raised the identical-looking gap at creation
time - C<tasklist_add>, C<tasklist_unshift>, and C<tasklist_slice> all
accept a C<--ref> and write it unchecked. Considered and deliberately
NOT extended there: a ref naming no card is an accepted, tested state at
creation elsewhere on this board -
t/419-a-queue-that-disagrees-with-the-board.t's own C<QTK-404> fixture
exists specifically to prove a downstream policy (C<task-card-mismatch>'s
duplicate walk) stays silent about a card nobody can open. Linking is a
considered claim an agent makes about existing work; a fresh,
still-unlinked task naming a not-yet-real card is the ordinary case this
whole ticket exists to let get linked LATER, once the card exists.
C<tasklist_task_ref_unlink> is likewise unchanged: removing a ref, valid
or not, can never manufacture a false link, so there is nothing here for
it to guard against.

C<task-unlinked>'s own message is also corrected: it told an agent to
"link it to one that already covers this work" without ever naming the
command that does that, which is exactly how the corrected-scope
investigation on this card missed that the command already existed. It
now names C<tira.tasklist.task.ref.link> directly.

=cut
