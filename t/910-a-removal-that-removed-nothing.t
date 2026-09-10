#!/usr/bin/env perl
# A link is stored as two entries - the forward type on one card and its
# reciprocal on the other - and link_remove takes a from, a type and a to and
# removes the pair. Ask it for the type that does not belong to that from/to
# ORDER and it exits successfully having removed nothing.
#
# TKT-910, EPC-007. Measured in a container, two different cards A and B:
#
#   link_add --from A --to B --type blocks
#     A holds: blocks->B
#     B holds: is-blocked-by->A
#
#   link_remove --from A --to B --type is-blocked-by   -> removed=1 (LIE)
#     A holds: blocks->B          <-- UNCHANGED
#     B holds: is-blocked-by->A   <-- UNCHANGED
#
# 'is-blocked-by' is never a type A can hold towards B - A only ever stores
# the forward type it was added with. Neither the from-side filter nor the
# to-side filter (which checks the RECIPROCAL of what was asked, on the other
# record) can match anything, and the sub returns { removed => true }
# unconditionally regardless of whether either grep actually removed a line.
#
# THE SELF-LINK CASE (TKT-762's own remaining question, criterion 4 - whether
# link.remove can remove a self-link already on the board) has a second,
# sharper fault: from_path and to_path are the SAME file, so the two
# JSON writes in one transaction land on one path, and the SECOND write wins
# outright, discarding whichever of the two filters ran first. A self-link
# can only ever ask for ONE of its two type spellings to actually survive to
# disk, and which one survives depends on write order, not on which type the
# caller asked to remove.
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
    return $tira->create_record( project => $root, type => 'ticket', title => $title );
}

sub links_of {
    my ( $tira, $root, $ref ) = @_;
    my $list = $tira->link_list( project => $root, ref => $ref );
    return join ';', map {"$_->{type}->$_->{ref}"} sort { $a->{type} cmp $b->{type} } @{$list};
}

# --- two DIFFERENT cards: the wrong-direction type is a no-op today ---------

{
    my ( $tira, $root ) = board();
    my $a = card( $tira, $root, 'A' );
    my $b = card( $tira, $root, 'B' );
    $tira->link_add( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'blocks' );

    is( links_of( $tira, $root, $a->{ref} ), "blocks->$b->{ref}", 'A holds the forward type' );
    is( links_of( $tira, $root, $b->{ref} ), "is-blocked-by->$a->{ref}", 'B holds the reciprocal' );

    # 'is-blocked-by' is not a type A can ever hold towards B - it belongs to
    # B's own end of this same link, not A's.
    my $ok = eval {
        $tira->link_remove( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'is-blocked-by' );
        1;
    };
    my $why = $@ // '';
    ok( !$ok, "removing 'is-blocked-by' from A towards B is refused - that type "
          . 'never belonged to A in this direction, and removing it silently would '
          . 'report success for a change that never happened' );
    like( $why, qr/\bblocks\b/,
        "and the refusal names 'blocks' - the type that IS actually there - "
          . 'so the caller can retype the call rather than guess' );

    is( links_of( $tira, $root, $a->{ref} ), "blocks->$b->{ref}",
        'and the link survives the refused attempt - nothing was removed' );
    is( links_of( $tira, $root, $b->{ref} ), "is-blocked-by->$a->{ref}",
        'on both ends' );

    # The type that DOES belong to A in this direction still works, unchanged.
    my $removed = $tira->link_remove( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'blocks' );
    ok( $removed->{removed}, 'removing the real forward type succeeds' );
    is( links_of( $tira, $root, $a->{ref} ), '', 'and it is actually gone from A' );
    is( links_of( $tira, $root, $b->{ref} ), '', 'and from B' );
}

# --- and from the OTHER card, the type IT holds still works -----------------
#
# The fix is about the type not matching the from/to order given, not about
# which end of the link the caller happens to name first - removing by B's own
# visible type, with B named as --from, is exactly the shape that already
# worked and must keep working.

{
    my ( $tira, $root ) = board();
    my $a = card( $tira, $root, 'A' );
    my $b = card( $tira, $root, 'B' );
    $tira->link_add( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'blocks' );

    my $removed = $tira->link_remove( project => $root, from => $b->{ref}, to => $a->{ref}, type => 'is-blocked-by' );
    ok( $removed->{removed}, "removing B's own visible reciprocal type, with B as --from, still works" );
    is( links_of( $tira, $root, $a->{ref} ), '', 'gone from A' );
    is( links_of( $tira, $root, $b->{ref} ), '', 'gone from B' );
}

# --- the self-link: both spellings must actually remove it ------------------
#
# TKT-762 refuses NEW self-links but explicitly leaves an already-stored one
# alone - this is that remaining question, answered. A self-link's two writes
# land on the SAME file; whichever of the two is written second used to win
# outright, so only one of the two type spellings could ever actually take
# the link off disk, and which one depended on write order, not on which type
# the caller named.

{
    my ( $tira, $root ) = board();
    my $x = card( $tira, $root, 'X' );

    # Built directly rather than through link_add, which now refuses to
    # create a NEW self-link (TKT-762) - this reproduces a self-link already
    # on the board from before that refusal shipped.
    my ( $path, $rec ) = $tira->_record_data( project => $root, ref => $x->{ref} );
    push @{ $rec->{linkage}{links} }, { type => 'is-blocked-by', ref => $x->{ref} };
    $tira->_write_json_transaction( [ [ $path, $rec ] ] );

    is( links_of( $tira, $root, $x->{ref} ), "is-blocked-by->$x->{ref}",
        'the pre-existing self-link is on disk, one entry, as TKT-762 measured it' );

    my $removed = $tira->link_remove( project => $root, from => $x->{ref}, to => $x->{ref}, type => 'is-blocked-by' );
    ok( $removed->{removed}, 'removing a self-link by the type it visibly shows actually removes it' );
    is( links_of( $tira, $root, $x->{ref} ), '', 'and it is gone, not merely reported gone' );
}

{
    my ( $tira, $root ) = board();
    my $x = card( $tira, $root, 'X' );
    my ( $path, $rec ) = $tira->_record_data( project => $root, ref => $x->{ref} );
    push @{ $rec->{linkage}{links} }, { type => 'is-blocked-by', ref => $x->{ref} };
    $tira->_write_json_transaction( [ [ $path, $rec ] ] );

    # The OTHER spelling of the same self-link ('blocks', its reciprocal) was
    # the one TKT-762's own measurement found actually worked, by accident of
    # write order rather than by design - it must keep working too.
    my $removed = $tira->link_remove( project => $root, from => $x->{ref}, to => $x->{ref}, type => 'blocks' );
    ok( $removed->{removed}, "removing the self-link by its reciprocal spelling ('blocks') still works" );
    is( links_of( $tira, $root, $x->{ref} ), '', 'and it is gone' );
}

# --- an ordinary link in either direction is unaffected ---------------------

{
    my ( $tira, $root ) = board();
    my $a = card( $tira, $root, 'A' );
    my $b = card( $tira, $root, 'B' );
    $tira->link_add( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'relates-to' );
    is( links_of( $tira, $root, $a->{ref} ), "relates-to->$b->{ref}", 'a symmetric type adds cleanly' );
    my $removed = $tira->link_remove( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'relates-to' );
    ok( $removed->{removed}, 'and removes cleanly' );
    is( links_of( $tira, $root, $a->{ref} ), '', 'gone from both ends' );
    is( links_of( $tira, $root, $b->{ref} ), '', 'gone from both ends' );
}

# --- and a pair linked by MORE than one type names all of them -------------
#
# The refusal above reads one real link off the from card and names it - two
# records can be linked by more than one type at once, and naming only the
# first found while a second one also exists would be its own small version
# of the same lie: a caller retyping the call from a partial answer.

{
    my ( $tira, $root ) = board();
    my $a = card( $tira, $root, 'A' );
    my $b = card( $tira, $root, 'B' );
    $tira->link_add( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'blocks' );
    $tira->link_add( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'relates-to' );

    my $ok = eval {
        $tira->link_remove( project => $root, from => $a->{ref}, to => $b->{ref}, type => 'is-blocked-by' );
        1;
    };
    my $why = $@ // '';
    ok( !$ok, 'a wrong-direction removal on a doubly-linked pair is still refused' );
    like( $why, qr/\bblocks\b/, 'and both real types are named' );
    like( $why, qr/relates-to/, 'both real types are named' );
}

done_testing;

__END__

=head1 NAME

910-a-removal-that-removed-nothing.t - link_remove refuses rather than lies

=head1 WHY

TKT-910: link_remove unconditionally returned C<{ removed => true }> whether
or not either of its two filter operations actually matched anything, so a
type that did not belong to the from/to order given was a silent no-op
reported as a success. A self-link's two writes also landed on one file, so
whichever write happened second discarded the other - only one of a
self-link's two type spellings could ever actually reach disk.

=head1 WHAT IS ASSERTED

Removing by a type that does not belong to the from/to order given is
refused, naming nothing removed rather than lying about it; removing by the
type that DOES belong (from either end) still works; a pre-existing
self-link is removable by either of its two spellings, not only the one
write order happened to favour; an ordinary link in either direction is
unaffected.

=cut
