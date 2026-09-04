#!/usr/bin/env perl
# A relation needs two records.
#
# TKT-762, EPC-007. link_add accepts --from and --to naming the same card, and
# the board stores it without complaint. Measured in a container:
#
#   link_add LT-001 relates-to LT-001  ->  ACCEPTED
#   links on LT-001: relates-to->LT-001
#
# THE SECOND HALF IS SHARPER AND IS WHY THIS IS NOT COSMETIC. A link writes two
# entries - the forward type on `from`, the reciprocal on `to`. When both ends
# are the same card, both writes land on it and only one survives:
#
#   link_add LT-003 blocks LT-003      ->  ACCEPTED
#   links on LT-003: is-blocked-by->LT-003
#
# The caller asked for "this blocks that" and the record says "this is blocked by
# that", about one card, silently. Three cards on this board tonight were about a
# command answering a question nobody asked; this one answers with the mirror
# image of the question.
#
# WHY THE SECOND HALF NEEDS NO SEPARATE FIX. The overwrite happens only because
# both writes land on one card. Refusing the self-link removes the only path to
# it, so there is no reachable state left to correct - writing code for it would
# be guarding a case that can no longer be created.
#
# WHERE THE REFUSAL GOES, and it is criterion 2 rather than my preference: in
# link_add, not the dispatch layer. Three callers reach it - the CLI verb, the
# browser dashboard's /link/add route, and a direct engine call. A check in the
# CLI would leave the browser writing what the CLI refuses, which is how the
# engine and the browser came to disagree about attachment content types on
# TKT-713.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Link', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'LKS', epic_prefix => 'LKE', ticket_prefix => 'LKT',
    );
    return ( $tira, $root );
}

sub card {
    my ( $tira, $root, $title ) = @_;
    return $tira->create_record( project => $root, type => 'ticket',
        title => $title, description => 'x', author => 'claude' )->{ref};
}

sub links_on {
    my ( $tira, $root, $ref ) = @_;
    my $record = $tira->record_show( project => $root, type => 'ticket', ref => $ref );
    return join ', ',
      map { "$_->{type}->$_->{ref}" } @{ $record->{linkage}{links} || [] };
}

# --- linking two different cards still works, both ways ----------------------
#
# The control, first, because a refusal that caught real links would be a far
# worse defect than the one it fixes - linkage is how this board records that one
# card blocks another, and every epic on it depends on the hierarchy beside it.

{
    my ( $tira, $root ) = board();
    my $one = card( $tira, $root, 'One' );
    my $two = card( $tira, $root, 'Two' );

    $tira->link_add( project => $root, from => $one, type => 'blocks',
        to => $two, author => 'claude' );

    is( links_on( $tira, $root, $one ), "blocks->$two",
        'a normal link writes the forward type on the card it came from' );

    is( links_on( $tira, $root, $two ), "is-blocked-by->$one",
        'and the reciprocal on the other one - which is the mechanism the '
          . 'self-link case breaks, so it has to be shown working first' );
}

{
    my ( $tira, $root ) = board();
    my $one = card( $tira, $root, 'One' );
    my $two = card( $tira, $root, 'Two' );

    $tira->link_add( project => $root, from => $one, type => 'relates-to',
        to => $two, author => 'claude' );

    is( links_on( $tira, $root, $one ), "relates-to->$two",
        'a non-directional type is unaffected too - the refusal must key on the '
          . 'two refs being equal, not on the type' );
}

# --- and a card cannot be linked to itself -----------------------------------

{
    my ( $tira, $root ) = board();
    my $solo = card( $tira, $root, 'Solo' );

    # any failure is what this means: the only intended way out is the refusal,
    # and a failure for another reason is equally a link that was not stored.
    my $ok = eval {
        $tira->link_add( project => $root, from => $solo, type => 'relates-to',
            to => $solo, author => 'claude' );
        1;
    };
    my $why = $@ // '';

    ok( !$ok, 'A CARD CANNOT BE LINKED TO ITSELF. Today it can: the board stores '
          . 'relates-to pointing at the card it is written on, and says nothing' );

    like( $why, qr/\Q$solo\E/,
        'and the refusal NAMES the record, because a caller who got here pasted '
          . 'the same ref twice and needs to see which one' );

    is( links_on( $tira, $root, $solo ), '',
        'and nothing was written - a refusal that stored the link anyway would '
          . 'be the worst of both' );
}

{
    my ( $tira, $root ) = board();
    my $solo = card( $tira, $root, 'Blocks itself' );

    my $ok = eval {
        $tira->link_add( project => $root, from => $solo, type => 'blocks',
            to => $solo, author => 'claude' );
        1;
    };

    ok( !$ok, 'a DIRECTIONAL self-link is refused too, and it is the one that '
          . 'costs most: today "blocks" is stored as "is-blocked-by", because '
          . 'both writes land on one card and only the reciprocal survives - so '
          . 'the record holds the mirror image of what was asked for' );

    is( links_on( $tira, $root, $solo ), '',
        'with nothing stored, which is what removes the overwrite rather than '
          . 'correcting it: the state can no longer be created' );
}

# --- the refusal is the ENGINE's ---------------------------------------------
#
# Criterion 2, and the reason it is one line rather than three. The browser
# dashboard reaches link_add through its own route; a check in the CLI would let
# it write what the CLI refuses.

{
    my ( $tira, $root ) = board();
    my $solo = card( $tira, $root, 'Engine' );

    my $ok = eval {
        $tira->link_add( project => $root, from => $solo, type => 'duplicates',
            to => $solo, author => 'claude' );
        1;
    };

    ok( !$ok,
        'the engine itself refuses, called directly with no CLI in the way - so '
          . 'the browser route is guarded by the same rule rather than by a '
          . 'second copy of it' );
}

done_testing();

__END__

=head1 NAME

527-a-card-related-to-itself.t - a relation needs two records

=head1 WHY

TKT-762. C<link_add> accepts C<--from> and C<--to> naming the same card. With a
directional type it is worse: both writes land on one card and only the
reciprocal survives, so C<A blocks A> is stored as C<A is blocked by A> - the
mirror image of what was asked for, recorded silently.

=head1 WHAT IS ASSERTED

That linking two different cards is unchanged, in both directions and for a
non-directional type - the control, and the mechanism the self-link case breaks.
That a self-link is refused, naming the record, with nothing written. That the
directional case is refused too. And that the refusal comes from the engine, so
the browser's C</link/add> route is guarded by the same rule.

=head1 WHAT IS NOT ASSERTED

Anything about links already stored. TKT-762's solution leaves them alone - the
refusal is at the point of writing only - and they remain removable, though only
by the type they were B<added> with. That last is a separate defect found while
answering this card's own criterion 4, and it is TKT-910 rather than this file:
C<link_remove> reports success and removes nothing when asked for the type the
card visibly holds.

=cut
