#!/usr/bin/env perl
# TKT-613. column_rename renames the column's directory and its config
# entry, but never rewalks any record's required_items array to update the
# column tag stored on each entry. The push/departure gate greps items
# whose column equals the card's CURRENT column, so after a rename every
# item still tagged with the OLD name becomes invisible to that gate -
# a card can leave with required actions silently unmet.
#
# Reproduced against the pre-fix source (lib/Tira.pm, sub column_rename):
# the rename block touches $old_directory/$new_directory and the column
# config entry only - nothing in it ever reads or writes required_items.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-08-30T04:00:00Z'} );

$tira->project_new(
    name => 'Renamed', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'review', 'done' ],
    sow_prefix => 'RNS', epic_prefix => 'RNE', ticket_prefix => 'RNT',
);

my $record = $tira->create_record( project => $root, type => 'ticket', title => 'Card in review' );
$tira->record_move( project => $root, ref => $record->{ref}, type => 'ticket', column => 'review', author => 'claude' );
$tira->required_item_add(
    project => $root, ref => $record->{ref}, type => 'ticket', column => 'review',
    item => 'Verify the fix works', status => 'pending', author => 'claude',
);
$tira->required_item_add(
    project => $root, ref => $record->{ref}, type => 'ticket', column => 'review',
    item => 'Already verified', status => 'done', author => 'claude',
);
$tira->required_item_update(
    project => $root, ref => $record->{ref}, type => 'ticket', id => 'REQ-002',
    status => 'done', command => ['the real command'], proof => ['the real proof'], author => 'claude',
);

$tira->column_rename( project => $root, type => 'ticket', name => 'review', new_name => 'verify' );

my $after = $tira->record_show( project => $root, ref => $record->{ref}, type => 'ticket' );
my ($tagged) = grep { $_->{item} eq 'Verify the fix works' } @{ $after->{required_items} // [] };

ok( $tagged, 'the required item is still on the card after the column rename' );
is( $tagged->{column}, 'verify',
    'the required item column tag follows the rename to the column\'s new name '
      . '- if this is still "review", the departure gate that greps items by the '
      . "card's CURRENT column can no longer see this pending item at all" );

# CHK-004: a done item's own status and proof must survive the same retag
# untouched - the fix only rewrites the column field, nothing else on the
# entry.
my ($done_item) = grep { $_->{item} eq 'Already verified' } @{ $after->{required_items} // [] };
is( $done_item->{column}, 'verify', 'a done item is retagged to the new column name too' );
is( $done_item->{status}, 'done', 'and keeps its own done status through the rename' );
is( $done_item->{proof}[-1]{command}, 'the real command', 'and its recorded command survives the rename' );
is( $done_item->{proof}[-1]{proof}, 'the real proof', 'and its recorded proof survives the rename' );

done_testing();

__END__

=head1 NAME

t/444-a-rename-that-leaves-old-tags-behind.t - a column rename must update
every required item still tagged with the old column name

=head1 DESCRIPTION

C<column_rename> renamed the column's directory and its entry in the board
config, but never rewalked C<required_items> on the records that reference
that column, so a pending item created while the column was named
C<review> stayed tagged C<review> forever, even after the column itself
became C<verify>. The push/departure gate matches items by the card's
current column, so the rename silently blinded that gate to the item.

=cut
