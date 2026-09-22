#!/usr/bin/env perl
# TKT-1084. required-action-stranded (and the departure gate _unmet_in_column
# it shares this logic with) exempts a required item by matching an
# exemption's value against the item's 'item' TEXT field only - never its
# 'id' field. Live incident: --exempt-required REQ-082 (naming the required
# item by the board-visible id every police finding and required-action.list
# already names it by) was run for all 12 stranded items, required_exempt
# confirmed populated, and required-action-stranded STILL reported them -
# the exemption's value never matched the item's descriptive text.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-22T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Exempt', dir => $root, members => ['claude'],
    columns => ['backlog, tests-red, implement, done'],
);
$tira->policy_add(
    project => $root, rule => 'required-action-stranded', action => 'bridge-reminder',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Exempted by its own id' );
my $item = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref},
    column => 'backlog', item => 'Fill in the fields', status => 'pending' );

# Exempt it by the REQ id - the natural, board-visible identifier, and what
# the live incident actually used.
$tira->record_update(
    project => $root, ref => $card->{ref}, type => 'ticket', author => 'claude',
    required_exempt => [ $item->{id} ], exempt_reason => ['covered elsewhere'],
);

# The browser move: ungated, past both backlog and tests-red.
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

my $pass = $tira->police_pass(
    project => $root, store => File::Spec->catdir( $tmp, 'store' ), world => {},
);
my $violations = $pass->{violations} // [];

is( scalar @{$violations}, 0,
    'an item exempted by its own REQ id is not reported as stranded' )
  or diag( 'reported: ' . join( '; ', map { $_->{detail} } @{$violations} ) );

# --- exempting by the item's own TEXT still works - no regression ----------

{
    my $card2 = $tira->create_record( project => $root, type => 'ticket', title => 'Exempted by its own text' );
    my $item2 = $tira->required_item_add( author => 'claude', project => $root, ref => $card2->{ref},
        column => 'backlog', item => 'Fill in the fields', status => 'pending' );

    $tira->record_update(
        project => $root, ref => $card2->{ref}, type => 'ticket', author => 'claude',
        required_exempt => [ $item2->{item} ], exempt_reason => ['still works by text too'],
    );
    $tira->record_move( project => $root, ref => $card2->{ref}, column => 'implement', author => 'claude' );

    my $pass2 = $tira->police_pass(
        project => $root, store => File::Spec->catdir( $tmp, 'store2' ), world => {},
    );
    is( scalar @{ $pass2->{violations} // [] }, 0,
        'and exempting by the item\'s exact text - the pre-existing, documented shape - still works' );
}

# --- the ENTRY gate (a different call site, same fix) also honours an id ---

{
    $tira->column_update( project => $root, type => 'ticket', name => 'implement',
        entry_required_action => ['Confirm scope'] );
    my $card3 = $tira->create_record( project => $root, type => 'ticket', title => 'Entry gate by id' );
    my $entry_item = $tira->required_item_add( author => 'claude', project => $root, ref => $card3->{ref},
        column => 'implement', item => 'Confirm scope', status => 'pending', entry => 1 );

    $tira->record_update(
        project => $root, ref => $card3->{ref}, type => 'ticket', author => 'claude',
        required_exempt => [ $entry_item->{id} ], exempt_reason => ['exempted by id at the entry gate too'],
    );
    my $moved = eval { $tira->record_move( project => $root, ref => $card3->{ref}, column => 'implement', author => 'claude' ); 1 };
    ok( $moved, 'the entry gate (_column_required_action_violation) also honours an exemption by REQ id' )
      or diag("move refused: $@");
}

# --- a text exemption that happens to equal ANOTHER item's id does not -----
# --- also exempt that other item (Codex review) -----------------------------
#
# REQ-001's own item TEXT is literally "REQ-002" (a contrived but possible
# card), and REQ-002 is a real, separate required item. An id-or-text OR
# without disambiguation would let an exemption for the text "REQ-002"
# accidentally also exempt REQ-002 by id.

{
    my $card4 = $tira->create_record( project => $root, type => 'ticket', title => 'Ambiguous text/id collision' );
    $tira->required_item_add( author => 'claude', project => $root, ref => $card4->{ref},
        column => 'backlog', item => 'REQ-002', status => 'pending' );    # REQ-001, text is "REQ-002"
    my $real_002 = $tira->required_item_add( author => 'claude', project => $root, ref => $card4->{ref},
        column => 'backlog', item => 'Submit evidence', status => 'pending' );    # REQ-002, a real item

    $tira->record_update(
        project => $root, ref => $card4->{ref}, type => 'ticket', author => 'claude',
        required_exempt => ['REQ-002'], exempt_reason => ['exempting the item whose TEXT is REQ-002'],
    );
    $tira->record_move( project => $root, ref => $card4->{ref}, column => 'implement', author => 'claude' );

    my $pass4 = $tira->police_pass(
        project => $root, store => File::Spec->catdir( $tmp, 'store4' ), world => {},
    );
    my @stranded4 = @{ $pass4->{violations} // [] };
    is( scalar @stranded4, 1, 'REQ-002 (the real item, unexempted) is still reported - the text exemption did not leak onto it' )
      or diag( 'reported: ' . join( '; ', map { $_->{detail} } @stranded4 ) );
    like( $stranded4[0]{detail}, qr/\Q$real_002->{id}\E/, 'and it names the real REQ-002 as the stranded one' )
      if @stranded4;
}

done_testing;

__END__

=head1 NAME

1151-an-exemption-that-named-the-wrong-half.t - --exempt-required by REQ id
actually exempts a required item

=head1 DESCRIPTION

TKT-1084. Both C<_unmet_in_column> (the departure gate, lib/Tira/CLI/Move.pm)
and C<required-action-stranded>'s own exempt check (lib/Tira.pm) built their
exempt set keyed only on a required item's C<item> text field, never its
C<id> - so an exemption naming the item by its REQ id (the identifier every
other part of this board already uses to refer to a required item) silently
had no effect.

=cut
