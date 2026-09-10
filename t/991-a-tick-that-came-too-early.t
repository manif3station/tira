#!/usr/bin/env perl
# checklist-unmoved's single-move window defaults to -1, so a stale
# pre-move tick silences the rule.
#
# TKT-991. Found during the 2026-09-07 hourly bug hunt. The rule bounds
# "has the checklist moved since the card did" by journal position: for a
# card with more than one recorded move, the window is the SECOND-to-last
# move's own index, so only checklist activity strictly after the last
# move counts. For a card with exactly ONE recorded move, the code instead
# used -1 - meant to read as "since the beginning of the journal" - but
# every journal index is greater than -1, so a checklist tick made BEFORE
# the card's only move (when it was still sitting untouched in the entry
# column) is misread as having happened "since" that move, silencing a
# card that is genuinely stale.
#
# The fix: for a single move, the window is the move's OWN index, not -1 -
# only checklist entries strictly after the move itself should count,
# exactly as the multi-move case already bounds by the PRIOR move's index.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );

sub board_at {
    my ($name) = @_;
    my $step = 0;
    my @times = map { sprintf '2026-09-07T10:%02d:00Z', $_ } 0 .. 59;
    my $tira = Tira->new( clock => sub { $times[ $step++ ] // $times[-1] } );
    my $root = File::Spec->catdir( $tmp, $name );
    $tira->project_new(
        name => $name, dir => $root, members => ['claude'],
        columns => ['backlog, tests-red, implement, done'],
    );
    $tira->policy_add(
        project => $root, rule => 'checklist-unmoved', action => 'bridge-reminder',
    );
    return ( $tira, $root );
}

sub reported {
    my ( $tira, $root, $name ) = @_;
    my $pass = $tira->police_pass(
        project => $root,
        store   => File::Spec->catdir( $tmp, "store-$name" ),
        world   => {},
    );
    return scalar @{ $pass->{violations} // [] };
}

# --- the bug: one move, checklist ticked BEFORE it, nothing after ----------
{
    my ( $tira, $root ) = board_at('pre-move-tick');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'To Do' );

    # Ticked while still sitting in the entry column, BEFORE the only move
    # this card will ever have - the same shape as a card filed with its
    # checklist pre-populated and then walked forward without further work.
    $tira->checklist_update( author => 'claude',
        project => $root, ref => $card->{ref}, id => 'CHK-001', status => 'done',
        command => ['did the work'], proof => ['it is done'] );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'more work', status => 'To Do' );

    # The one and only move - nothing ticked after this.
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );

    is( reported( $tira, $root, 'pre-move-tick' ), 1,
        'a single-move card whose only checklist activity was BEFORE that move is reported' )
      or diag('not reported - the -1 window bug: a pre-move tick silenced the rule');
}

# --- the control: one move, checklist genuinely ticked after it ------------
{
    my ( $tira, $root ) = board_at('post-move-tick');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'To Do' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->checklist_update( author => 'claude',
        project => $root, ref => $card->{ref}, id => 'CHK-001', status => 'done',
        command => ['did the work'], proof => ['it is done'] );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'more work', status => 'To Do' );

    is( reported( $tira, $root, 'post-move-tick' ), 0,
        'and a single-move card genuinely ticked after that move is left alone - no regression' );
}

# --- multi-move cases are unchanged -----------------------------------------
{
    my ( $tira, $root ) = board_at('multi-move-dragged');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'To Do' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'implement', author => 'claude' );

    is( reported( $tira, $root, 'multi-move-dragged' ), 1,
        'multi-move: still reported when nothing ticked since the second-to-last move' );
}

{
    my ( $tira, $root ) = board_at('multi-move-worked');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'To Do' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->checklist_update( author => 'claude',
        project => $root, ref => $card->{ref}, id => 'CHK-001', status => 'done',
        command => ['did the work'], proof => ['it is done'] );
    $tira->checklist_add( author => 'claude',
        project => $root, ref => $card->{ref}, item => 'more work', status => 'To Do' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'implement', author => 'claude' );

    is( reported( $tira, $root, 'multi-move-worked' ), 0,
        'multi-move: still left alone when the checklist moved since the second-to-last move' );
}

done_testing();

__END__

=head1 NAME

991-a-tick-that-came-too-early.t - checklist-unmoved's single-move window bug

=head1 WHY

TKT-991. For a card with exactly one recorded move, checklist-unmoved's
window defaulted to -1, which every journal index is greater than - so a
checklist tick made BEFORE the card's only move was misread as having
happened since it, silencing a genuinely stale card.

=head1 WHAT IS ASSERTED

That a single-move card ticked only before its move is now reported; that
one ticked genuinely after its move is still left alone; and that both
multi-move shapes (dragged, worked) are unaffected.

=cut
