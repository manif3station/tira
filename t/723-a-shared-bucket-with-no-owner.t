#!/usr/bin/env perl
# TKT-723. tasklist_prune resolves an absent --session/TIRA_AGENT_SESSION the
# same way it resolves an explicit empty one - both become the same '' bucket
# the filter compares against. On a board worked by more than one agent
# session, everyone who never sets a session lands in that same bucket, so a
# routine, unscoped prune (a required entry action on done-not-released)
# silently deletes every OTHER unscoped session's done items too, not just
# the caller's own. Observed as real data loss: ten completed items from one
# session were deleted by another session's own routine prune.
#
# WRITTEN RED: tasklist_prune has no refusal at all - it resolves an absent
# session straight to the shared '' bucket and prunes it unconditionally.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-24T20:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A shared bucket with no owner', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SBW', epic_prefix => 'SBE', ticket_prefix => 'SBT',
);

local $ENV{TIRA_AGENT_SESSION};
delete $ENV{TIRA_AGENT_SESSION};

# --- two sessions, both unscoped at add time (today's documented default) --

$tira->tasklist_add( project => $root, text => 'session A done item', session => 'session-a' );
my $a_done = $tira->tasklist_add( project => $root, text => 'session A item to finish', session => 'session-a' );
$tira->tasklist_update( project => $root, id => $a_done->{id}, session => 'session-a', status => 'done' );

$tira->tasklist_add( project => $root, text => 'session B done item', session => 'session-b' );
my $b_done = $tira->tasklist_add( project => $root, text => 'session B item to finish', session => 'session-b' );
$tira->tasklist_update( project => $root, id => $b_done->{id}, session => 'session-b', status => 'done' );

# Genuinely unscoped items - neither --session nor TIRA_AGENT_SESSION - the
# documented single-agent default, and the shape that actually caused the
# reported data loss.
my $unscoped_done = $tira->tasklist_add( project => $root, text => 'unscoped done item, session claimed later' );
$tira->tasklist_update( project => $root, id => $unscoped_done->{id}, status => 'done' );

# --- THE BUG: a prune with no session context refuses, not silently deletes -

my $error = do {
    local $@;
    eval { $tira->tasklist_prune( project => $root ) };
    $@;
};
ok( $error, 'a prune with neither --session nor TIRA_AGENT_SESSION set refuses' )
  or diag('tasklist_prune did not die - it silently pruned the shared bucket');
like( $error, qr/session/i, 'the refusal names the missing scope (session)' );

my $after_refusal = $tira->tasklist_list( project => $root, all_sessions => 1 );
is( scalar( grep { $_->{status} == 2 } @{$after_refusal} ), 3,
    'nothing was deleted by the refused prune - all 3 done items (A, B, unscoped) survive' );

# --- a prune scoped to a real session only touches that session's items ----

my $pruned_a = $tira->tasklist_prune( project => $root, session => 'session-a' );
is( scalar(@$pruned_a), 1, 'session-a prune removes exactly session-a\'s own 1 done item' );

my $after_a = $tira->tasklist_list( project => $root, all_sessions => 1 );
is( scalar( grep { $_->{status} == 2 } @{$after_a} ), 2, 'session B and the unscoped done item both survive session A\'s own prune' );
ok( ( grep { $_->{session} eq 'session-b' && $_->{status} == 2 } @{$after_a} ), 'session B\'s done item specifically survives' );

# --- TIRA_AGENT_SESSION env var path behaves identically to --session ------

local $ENV{TIRA_AGENT_SESSION} = 'session-b';
my $pruned_b = $tira->tasklist_prune( project => $root );
is( scalar(@$pruned_b), 1, 'TIRA_AGENT_SESSION=session-b prunes exactly session-b\'s own 1 done item, same as --session session-b would' );
delete $ENV{TIRA_AGENT_SESSION};

# --- --all-sessions is the deliberate, explicit opt-in that IGNORES session
# --- scoping entirely - it prunes every session's done items, not just the
# --- unscoped bucket. A fresh done item is added under a properly-scoped
# --- session (session-a again) here specifically to prove that: if
# --- --all-sessions only touched the unscoped bucket, this item would
# --- survive; it must not.

my $a_done_again = $tira->tasklist_add( project => $root, text => 'session A second done item', session => 'session-a' );
$tira->tasklist_update( project => $root, id => $a_done_again->{id}, session => 'session-a', status => 'done' );

my $pruned_all = $tira->tasklist_prune( project => $root, all_sessions => 1 );
is( scalar(@$pruned_all), 2,
    '--all-sessions prunes BOTH the remaining unscoped done item AND session-a\'s freshly-added done item - every session, not only the unscoped bucket' );

my $final = $tira->tasklist_list( project => $root, all_sessions => 1 );
is( scalar( grep { $_->{status} == 2 } @{$final} ), 0, 'no done items remain in any session after the explicit --all-sessions prune' );

done_testing();

__END__

=head1 NAME

723-a-shared-bucket-with-no-owner.t - tasklist.prune refuses rather than
silently deleting everyone's done items when no session can be determined

=head1 DESCRIPTION

TKT-723. C<_tasklist_session> resolves an absent C<--session>/
C<TIRA_AGENT_SESSION> to the same empty string an explicit empty session
would resolve to, so C<tasklist_prune>'s own filter cannot tell "my
unsessioned items" from "everyone's unsessioned items" apart - a caller who
never sets a session prunes the SAME shared bucket every other unscoped
caller's done items land in. On a board worked by more than one agent
session (the documented single-agent default is exactly this: no
C<--session> at all), a routine prune - required as an entry action on the
C<done-not-released> column - silently deleted ten completed items belonging
to a different session, with no warning and no per-session breakdown.

C<tasklist_prune> now refuses with a clear error naming the missing scope
when neither C<--session> nor C<TIRA_AGENT_SESSION> is set, rather than
treating that absence as an implicit shared-bucket prune. A caller who
genuinely wants to prune the shared bucket opts in explicitly with
C<--all-sessions>, the same deliberate opt-in C<tasklist.list> already uses
for "see every session's items" (TKT-539). A prune with C<--session> or
C<TIRA_AGENT_SESSION> set continues to work exactly as before, scoped only
to that session's own done items.

=cut
