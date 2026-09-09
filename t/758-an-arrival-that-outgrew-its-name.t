#!/usr/bin/env perl
# TKT-606 put arrival and removal detection inside task-changed, a rule named
# for editing items it already knows. TKT-758 is the "later" half of Q-097's
# answer: split a task-created rule out, covering both the arrival and the
# removal (a rule named "created" reporting removals repeats the mistake
# this card exists to fix), while task-changed goes back to reporting only
# edits to items it already knows.
#
# THE TRANSITION IS THE DESIGN QUESTION. Michael answered live (Q-145/Q-146,
# folded into the card's own solution_needed): task-created is declared and
# task-changed keeps sending arrivals until a board declares the new rule,
# then stops for that board. No board goes quiet, and the handover is per
# board.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

sub new_board {
    my $tmp   = tempdir( CLEANUP => 1 );
    my $tira  = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
    my $root  = File::Spec->catdir( $tmp, 'proj' );
    my $store = File::Spec->catdir( $tmp, 'police-store' );
    $tira->project_new(
        name => 'Arrivals', dir => $root, members => ['claude'],
        columns    => ['backlog, implement, done'],
        sow_prefix => 'AS', epic_prefix => 'AE', ticket_prefix => 'AT',
    );
    return ( $tira, $root, $store );
}

sub findings {
    my ( $tira, $root, $store, $rule ) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq $rule } @{ $pass->{violations} } ];
}

# --- (a), the compatibility branch: task-changed alone still reports --------
# arrivals, unchanged from TKT-606, for a board that has not moved over yet.

{
    my ( $tira, $root, $store ) = new_board();
    $tira->policy_add( project => $root, rule => 'task-changed', action => 'bridge-reminder' );

    $tira->tasklist_add( project => $root, text => 'already here' );
    is( scalar @{ findings( $tira, $root, $store, 'task-changed' ) }, 0,
        'first pass on an existing tasklist stays quiet, as before' );

    my $arrived = $tira->tasklist_add( project => $root, text => 'a new one' );
    my @after = @{ findings( $tira, $root, $store, 'task-changed' ) };
    is( scalar @after, 1,
        'a board that has not declared task-created still gets arrivals from task-changed - no board goes quiet' );
    like( $after[0]{detail}, qr/\Q$arrived->{id}\E|new/i, 'and the finding names it' );

    $tira->tasklist_remove( project => $root, id => $arrived->{id} );
    my @gone = @{ findings( $tira, $root, $store, 'task-changed' ) };
    is( scalar @gone, 1, 'and a removal too, same as before task-created existed' );
}

# --- task-created alone: a lifecycle rule that covers BOTH halves -----------

{
    my ( $tira, $root, $store ) = new_board();
    $tira->policy_add( project => $root, rule => 'task-created', action => 'bridge-reminder' );

    $tira->tasklist_add( project => $root, text => 'already here' );
    is( scalar @{ findings( $tira, $root, $store, 'task-created' ) }, 0,
        'a first pass on task-created alone stays quiet too - the baseline mechanism is not rule-specific' );

    my $arrived = $tira->tasklist_add( project => $root, text => 'a fresh task' );
    my @after = @{ findings( $tira, $root, $store, 'task-created' ) };
    is( scalar @after, 1, 'task-created reports the arrival' );
    like( $after[0]{detail}, qr/\Q$arrived->{id}\E|new/i, 'and names it' );

    $tira->tasklist_remove( project => $root, id => $arrived->{id} );
    my @gone = @{ findings( $tira, $root, $store, 'task-created' ) };
    is( scalar @gone, 1,
        'task-created ALSO reports the removal - a rule named for creation must still cover a task disappearing' );
    like( $gone[0]{detail}, qr/\Q$arrived->{id}\E|remov|gone|disappear/i, 'and names which one' );
}

# --- both declared together: the handover, with no duplicate ----------------

{
    my ( $tira, $root, $store ) = new_board();
    $tira->policy_add( project => $root, rule => 'task-changed', action => 'bridge-reminder' );
    $tira->policy_add( project => $root, rule => 'task-created', action => 'bridge-reminder' );

    $tira->tasklist_add( project => $root, text => 'already here' );
    findings( $tira, $root, $store, 'task-created' );    # first pass, establish baseline

    my $arrived = $tira->tasklist_add( project => $root, text => 'a new one, once both are declared' );
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    my @created_hits = grep { ( $_->{rule} // '' ) eq 'task-created' } @{ $pass->{violations} };
    my @changed_hits = grep { ( $_->{rule} // '' ) eq 'task-changed' } @{ $pass->{violations} };

    is( scalar @created_hits, 1, 'once task-created is declared, it is the one reporting the arrival' );
    is( scalar @changed_hits, 0,
        'and task-changed no longer claims it as a change - the handover the acceptance criteria asked for' );

    # --- task-changed still does its own job: edits to known items ----------
    $tira->tasklist_update( project => $root, id => $arrived->{id}, text => 'edited wording' );
    my $pass2 = $tira->police_pass( project => $root, store => $store, world => {} );
    my @edited = grep { ( $_->{rule} // '' ) eq 'task-changed' } @{ $pass2->{violations} };
    is( scalar @edited, 1, 'task-changed keeps reporting edits to items it already knows' );
    like( $edited[0]{detail}, qr/text/i, 'and still says what changed' );
}

done_testing();

__END__

=head1 NAME

t/758-an-arrival-that-outgrew-its-name.t - a task-created rule, split out of
task-changed, with a per-board handover

=head1 DESCRIPTION

TKT-758, the "later" half of Q-097's answer (TKT-606 shipped the "now" half
in 4.79). C<task-changed> reported a tasklist item arriving or disappearing,
even though its own name and job description are about editing items it
already knows.

A new C<task-created> rule now covers both halves - arrival and removal,
since naming a rule for creation and having it silently drop removals
repeats exactly the mistake this card exists to fix - reusing the same
C<task_seen> baseline ledger TKT-606 built, so the "no baseline, adopt
silently" property is not re-derived per rule.

The transition is per board, per Michael's live answer: a board that has
not declared C<task-created> keeps getting arrivals from C<task-changed>
exactly as before (shape (a) of three offered - the only one that keeps
TKT-606's promise without duplicating). A board that has declared both gets
the arrival from C<task-created> only - no duplicate finding for one event.

=cut
