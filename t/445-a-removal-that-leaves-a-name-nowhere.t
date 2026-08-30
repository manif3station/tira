#!/usr/bin/env perl
# TKT-613 (CHK-002/005). column_rename retags required_items entries that
# still name the OLD column, because that old name keeps meaning something
# else after the rename - a live column the departure gate still checks
# against. column_remove is different: once a column is removed, its name
# does not go on to mean anything at all, so no card's CURRENT column can
# ever equal it again.
#
# This is a decision, recorded here as a test rather than left implicit:
# column_remove is NOT changed to retag or scrub required_items entries
# that still name the removed column. A card physically living in the
# removed column is discarded wholesale by column_remove already, taking
# its own required_items with it. The only residual case - a card that
# already moved on before the column was removed, still carrying an item
# tagged with the column it left behind - is inert: the departure gate
# matches items by the card's CURRENT column, and "a column that no
# longer exists" can never be a card's current column. The stale tag
# becomes harmless history, not a live gap the way a rename's stale tag
# is (a renamed column IS still a live column, just under a new name -
# that's what makes TKT-613's fix necessary there and unnecessary here).

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-08-30T04:30:00Z'} );

$tira->project_new(
    name => 'Removed', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'review', 'done' ],
    sow_prefix => 'RMS', epic_prefix => 'RME', ticket_prefix => 'RMT',
);

my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Card that moved on' );
$tira->record_move( project => $root, ref => $record->{ref}, type => 'ticket', column => 'review', author => 'claude' );
$tira->required_item_add(
    project => $root, ref => $record->{ref}, type => 'ticket', column => 'review',
    item => 'Verify the fix works', status => 'pending', author => 'claude',
);
$tira->record_move( project => $root, ref => $record->{ref}, type => 'ticket', column => 'done', author => 'claude' );

$tira->column_remove( project => $root, type => 'ticket', name => 'review' );

my $after = $tira->record_show( project => $root, ref => $record->{ref}, type => 'ticket' );
is( $after->{column}, 'done', 'the card itself is untouched by removing a column it already left' );

my ($item) = grep { $_->{item} eq 'Verify the fix works' } @{ $after->{required_items} // [] };
ok( $item, 'the required item added while the card was in "review" is still there' );
is( $item->{column}, 'review',
    'and still names the removed column - column_remove does not retag or scrub it, by design: '
      . 'that name can never match a live current column again, so it is harmless history, unlike '
      . "a rename's stale tag, which still names a column that continues to exist" );

done_testing();

__END__

=head1 NAME

t/445-a-removal-that-leaves-a-name-nowhere.t - column_remove deliberately
does not retag required_items entries naming the removed column

=head1 DESCRIPTION

Recorded as a decision, not left implicit: unlike C<column_rename>
(TKT-613), C<column_remove> does not walk the board rewriting
C<required_items> entries that still name the removed column. A card
physically in the removed column is discarded wholesale, taking its own
required items with it; a card that already moved elsewhere before the
removal can keep a required item tagged with the column it left behind,
but that tag is inert - a removed column's name can never again equal a
card's current column, so the push/departure gate can never be fooled by
it the way a rename's stale tag could.

=cut
