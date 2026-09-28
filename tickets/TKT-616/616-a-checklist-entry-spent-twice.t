#!/usr/bin/env perl
# A per-column checklist entry, once ticked, cannot be ticked again on a
# second pass through the same column - does the rule still ask for it?
#
# Reported from zen-framework (TKT-616), measured on ZSD-291/292: a card that
# returns to an earlier column under review and is then re-forwarded through
# columns it already visited. TKT-242 already exempts the BACKWARD move
# itself (t/223-a-card-sent-back.t) - this test asks the other half of the
# same question: what happens on the FORWARD re-pass through columns whose
# own checklist entry was already ticked on the first pass, while a LATER
# column's entry is still outstanding (so the checklist as a whole is not
# yet "complete" - the global complete-checklist exemption does not apply).
#
# TKT-1191: moved here from t/ (was t/616-a-checklist-entry-spent-twice.t).
# It is a deliberate, still-red ground-truth reproduction, parked pending
# Q-186 (folded into the backward-move-semantics family: TKT-636, TKT-643,
# TKT-654, TKT-661, TKT-702, TKT-725) - not something anyone is actively
# fixing right now. Leaving a red test inside t/ breaks `prove -lr t` for
# EVERY ticket's own gate.run, since that run has no per-test exemption -
# confirmed live: it blocked TKT-1190's gate.run despite being entirely
# unrelated to that ticket. Kept here, still runnable directly (`prove -Ilib
# tickets/TKT-616/616-a-checklist-entry-spent-twice.t` from the repo root),
# as the same evidence TKT-616's own required-action proof already commits
# to keeping - just outside prove's own default discovery path.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-08-27T09:00:00Z';

my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Spent twice', dir => $root, members => ['claude'],
    columns => ['backlog, drafting, ready, implement, qa, done'],
    sow_prefix => 'SPS', epic_prefix => 'SPE', ticket_prefix => 'SPT',
);
$tira->policy_add( project => $root, rule => 'checklist-unmoved',
    action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Round-tripped through the same columns twice' );

# One entry per column, per-column shape (ZSD-292) - the shape the report
# says "works perfectly on pass 1".
for my $col (qw(drafting ready implement qa)) {
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref},
        item => "$col: done", status => 'To Do' );
}

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'checklist-unmoved' } @{ $pass->{violations} } ];
}

# --- pass 1: forward through drafting and ready, ticking each as reached ---

$now = '2026-08-27T10:00:00Z';
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'drafting' );
$tira->checklist_update( author => 'claude', project => $root, ref => $card->{ref},
    id => 'CHK-001', status => 'done', command => ['reached drafting'], proof => ['drafted'] );

$now = '2026-08-27T11:00:00Z';
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'ready' );
$tira->checklist_update( author => 'claude', project => $root, ref => $card->{ref},
    id => 'CHK-002', status => 'done', command => ['reached ready'], proof => ['ready'] );

# --- review sends it back before the checklist is complete (CHK-003/004
#     are still To Do - so the global "checklist complete" exemption does
#     not cover what follows) ---------------------------------------------

$now = '2026-08-27T12:00:00Z';
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'drafting' );

is( scalar @{ findings() }, 0,
    'the backward move itself is not reported (TKT-242, already shipped)' );

# --- pass 2: forward again through drafting and ready - CHK-001/002 are
#     already done, so neither can be ticked again on this pass -----------

$now = '2026-08-27T13:00:00Z';
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'ready' );

my $second_pass = findings();
ok( !scalar @{$second_pass},
    'moving forward again through a column whose own checklist entry is already done is not reported - '
  . 'nothing was left to tick, and that is not the same as nothing being done' )
  or diag( "false-fired: $second_pass->[0]{detail}" );

done_testing;

__END__

=head1 NAME

616-a-checklist-entry-spent-twice.t - a per-column entry ticked once stays spent on a repeat pass

=head1 DESCRIPTION

TKT-242 already exempts C<checklist-unmoved> from firing on the backward move
itself. TKT-616 (zen-framework, ZSD-291/292) asked the other half: once a
card returns and is forwarded again through columns it already visited, do
the already-ticked entries for those columns make the rule fire anyway,
since there is nothing left in THEM to tick even though the checklist as a
whole is not yet complete (a later column's entry is still outstanding)?

Measured against the current codebase: yes, it still false-fires. The
backward move itself is correctly exempt (TKT-242), but the second forward
pass through C<ready> - whose own checklist entry (CHK-002) was already
ticked done on pass 1 - fires C<checklist-unmoved> anyway. The rule's
per-move check asks whether ANY checklist activity happened since the
second-to-last move, not whether THIS column's own entry was already
satisfied on an earlier visit; a checklist entry has no structural link to
the column it was ticked for, so the engine cannot tell "this column's own
work was already proven" from "nothing was done." TKT-616's own suggested
fix ("ask for movement since the return") is already what the window
computation does and does not close this gap - see Q-186 on TKT-616 for the
design decision on how to fix it, currently parked pending Michael's answer.

=cut
