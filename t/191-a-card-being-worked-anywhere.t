#!/usr/bin/env perl
# A card being worked anywhere counts as a card being worked.
#
# Measured on this project's own board at 08:11 on 2026-08-15. work-without-card
# raised VIO-0013, escalated it to URGENT and repeated it four times, while
# TKT-195 sat in verify - assigned, with its suite running - and the tree changed
# under it because that is what working on a card looks like.
#
# The rule was not wrong about the tree. It was wrong about the board, and it was
# told so by a role: _card_in_progress counts a card as being worked only if it
# sits in the single column named by the in-progress role, when one is declared.
# This board declares in-progress=implement and has five columns work happens in,
# so tests-red, verify, document and push - four of the five - read as nobody
# working at all.
#
# That is the fault column-unwatched shipped for policies, arriving through a
# different door. A setting that names one column stops covering the board the
# moment work happens in another, and nobody has to do anything wrong for it: the
# role was accurate when it was set.
#
# The documentation half is the part that makes it hard to spot. docs/commands.md
# says of roles, "The vocabulary is the project's own; Tira matches a role
# without needing to understand it." Two names are understood and hard-coded -
# in-progress here, and done in parent-ahead-of-children - and they behave
# differently. done says out loud when it cannot find its role. in-progress says
# nothing, so a board using its own word for it falls through to the wide reading
# and is watched correctly by accident, while a board using Tira's word is
# watched in one column out of five. Following the documentation gives the right
# behaviour; using Tira's own vocabulary gives the bug.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Working', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, verify, done'],
    sow_prefix => 'WKS', epic_prefix => 'WKE', ticket_prefix => 'WKT',
);
$tira->column_roles_set( project => $root, type => 'ticket',
    roles => { 'in-progress' => 'implement', done => 'done' } );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Being worked in verify' )->{ref};

# --- the board this is about ------------------------------------------------------------
#
# A card in verify, which is a column work happens in and is not the one the
# role names. This is TKT-195's exact position when the rule accused it.

$tira->record_move( project => $root, ref => $card, column => 'verify' );

is( Tira::CLI::_card_in_progress( $tira, $root ), 1,
    'a card in verify is a card being worked, though the role names implement' );

# --- the column the role does name is unchanged --------------------------------------------

{
    $tira->record_move( project => $root, ref => $card, column => 'implement' );
    is( Tira::CLI::_card_in_progress( $tira, $root ), 1,
        'and so is a card in the column the role names' );
}

# --- while a board with nothing being worked still says so ------------------------------------
#
# The half that matters more than the fix: if everything counted, the rule would
# never fire and a tree changing with no card behind it would go unseen, which is
# what work-without-card exists for.

{
    $tira->record_move( project => $root, ref => $card, column => 'backlog' );
    is( Tira::CLI::_card_in_progress( $tira, $root ), 0,
        'a card waiting in the backlog is not work in progress' );

    $tira->record_move( project => $root, ref => $card, column => 'done' );
    is( Tira::CLI::_card_in_progress( $tira, $root ), 0,
        'and neither is one that is finished' );

    $tira->record_move( project => $root, ref => $card, column => 'discard' );
    is( Tira::CLI::_card_in_progress( $tira, $root ), 0,
        'nor one that was set aside' );
}

# --- a board that declares no roles is untouched ------------------------------------------------
#
# It already had the wide reading and must keep it: this changes what a declared
# role does, not what an undeclared board does.

{
    my $plain = File::Spec->catdir( $tmp, 'plain' );
    my $other = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    $other->project_new(
        name => 'Plain', dir => $plain, members => ['claude'],
        columns => ['backlog, implement, verify, done'],
        sow_prefix => 'PNS', epic_prefix => 'PNE', ticket_prefix => 'PNT',
    );
    my $ref = $other->create_record( project => $plain, type => 'ticket',
        title => 'Somewhere in the middle' )->{ref};
    $other->record_move( project => $plain, ref => $ref, column => 'verify' );
    is( Tira::CLI::_card_in_progress( $other, $plain ), 1,
        'a board that has declared no roles behaves exactly as before' );
}

# --- and a board that marked its own ending is asked, not guessed at -------------------------------
#
# `done` is the fallback for a board that has said nothing, not the answer.

{
    my $named = File::Spec->catdir( $tmp, 'named' );
    my $board = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    $board->project_new(
        name => 'Named', dir => $named, members => ['claude'],
        columns => ['backlog, implement, shipped'],
        sow_prefix => 'NMS', epic_prefix => 'NME', ticket_prefix => 'NMT',
    );
    $board->column_update( project => $named, type => $_, name => 'shipped', terminal => 1 )
      for qw(sow epic ticket);
    my $ref = $board->create_record( project => $named, type => 'ticket',
        title => 'Shipped' )->{ref};
    $board->record_move( project => $named, ref => $ref, column => 'shipped' );
    is( Tira::CLI::_card_in_progress( $board, $named ), 0,
        'a card in a column the board marked as its ending is not work in progress' );
}

# --- and the documentation stops claiming Tira understands no role names -----------------------

{
    open my $fh, '<:raw', 'docs/commands.md' or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr/in-progress/,
        'the reference names the roles Tira itself reads, rather than saying it reads none' );
}

done_testing;

__END__

=head1 NAME

191-a-card-being-worked-anywhere.t - work in progress is not one column

=head1 DESCRIPTION

C<_card_in_progress> counted a card as being worked only if it sat in the single
column named by the C<in-progress> role. On a board with five working columns
that left four of them reading as nobody working, and C<work-without-card>
accused the agent of exactly what it was in the middle of doing properly -
measured on this project's own board, URGENT, four times, while the card in
C<verify> had its suite running.

It now asks the board where work happens, the same question C<card-unassigned>
and C<priority-skipped> ask: not protected, and not marked C<--terminal>. A board
that has declared no roles is unchanged, and a board that marked its own ending
has that ending respected rather than C<done> assumed.

=cut
