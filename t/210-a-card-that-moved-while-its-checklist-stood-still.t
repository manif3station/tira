#!/usr/bin/env perl
# A card that moved while its checklist stood still.
#
# checklist-idle asks how long a checklist has not moved inside one column, so
# it catches a card standing still. This is the opposite case and the more
# misleading one: the card MOVES while the checklist is never ticked, so
# progress is claimed by dragging rather than by working, and the checklist
# meant to say what was done says nothing. Asked for by the owner.
#
# Measured against the real board before the rule was written. Reported without
# qualification - any move with nothing ticked since the previous one - it names
# 154 of 226 cards, and almost all are the last move into done, where the work
# finished earlier and there was nothing left to tick. A rule that fires on two
# thirds of a board is one somebody switches off. So two things narrow it, and
# both are asserted below: only a move INTO a working column, and only while the
# checklist still has something unfinished.
#
# The clock is controlled from the start, not for tidiness. Every write here
# lands in the same second on a real clock, and the rule compares a checklist
# entry's time against a move's time - so with the real clock the setup looks
# like work done after the move and the rule stays silent. That cost two false
# starts while building this, and it is the same artefact that t/86 and
# answer-ok-not-folded were bitten by.

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
    my @times = map { sprintf '2026-08-15T10:%02d:00Z', $_ } 0 .. 59;
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

# --- moved with nothing ticked --------------------------------------------
{
    my ( $tira, $root ) = board_at('dragged');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add(
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'todo' );

    # Two moves, because the window is since the PREVIOUS move. On the first
    # move the window reaches back to when the card was raised, and the
    # checklist was written inside it - which is movement, and rightly counts.
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'implement', author => 'claude' );

    is( reported( $tira, $root, 'dragged' ), 1,
        'a card moved on with nothing ticked since the last move is reported' );
}

# --- moved, having ticked something ---------------------------------------
{
    my ( $tira, $root ) = board_at('worked');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add(
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'todo' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->checklist_update(
        project => $root, ref => $card->{ref}, id => 'CHK-001', status => 'done' );
    $tira->checklist_add(
        project => $root, ref => $card->{ref}, item => 'more work', status => 'todo' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'implement', author => 'claude' );

    is( reported( $tira, $root, 'worked' ), 0,
        'while a card whose checklist moved in that window is left alone' );
}

# --- moved into a column where the work is over ----------------------------
{
    my ( $tira, $root ) = board_at('finished');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add(
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'todo' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'done', author => 'claude' );

    is( reported( $tira, $root, 'finished' ), 0,
        'and a card moved where the work is over is not chased for ticking nothing' );
}

# --- nothing left to tick --------------------------------------------------
{
    my ( $tira, $root ) = board_at('complete');
    my $card = $tira->create_record(
        project => $root, type => 'ticket', title => 'A card', reporter => 'claude' );
    $tira->checklist_add(
        project => $root, ref => $card->{ref}, item => 'do the work', status => 'done' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'tests-red', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref},
        column => 'implement', author => 'claude' );

    is( reported( $tira, $root, 'complete' ), 0,
        'nor a card whose checklist is finished, which has nothing left to tick' );
}

done_testing;

__END__

=head1 NAME

210-a-card-that-moved-while-its-checklist-stood-still.t - dragged, not worked

=head1 DESCRIPTION

C<checklist-idle> catches a card standing still. This catches the opposite: a
card that moves while its checklist is never ticked, so progress is claimed by
dragging rather than by working.

Two qualifications keep it usable, and both are asserted: only a move into a
working column, and only while the checklist still has something unfinished.
Without them the rule names two thirds of a real board, almost all of it the
last move into done.

The clock is controlled because every write here lands in the same second
otherwise, and the rule compares a checklist entry's time against a move's.

=cut
