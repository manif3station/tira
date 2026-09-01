#!/usr/bin/env perl
# TKT-701. column_remove moved every card in the removed column by a
# filesystem rename straight into discard - not through record_move - so
# there was no journal entry, no author, and no reason. discard-unexplained
# then fired on every one of them for ever, unable to tell "displaced by an
# admin change" from "somebody gave up on this".
#
# Scope corrected on the card before implementing: required_items on OTHER
# cards naming the removed column are deliberately left untouched, per the
# existing TKT-613/t/445 decision that such a tag is inert history (the
# departure gate matches by a card's CURRENT column, which a removed
# column's name can never become again) rather than a live gap.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T18:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Removable', dir => $root, members => ['ada'],
    columns => [ 'backlog', 'staging', 'done' ],
    sow_prefix => 'RVS', epic_prefix => 'RVE', ticket_prefix => 'RVT',
);
$tira->policy_add( project => $root, rule => 'discard-unexplained', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Resting in staging' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'staging', author => 'ada' );

# --- refused without a reason -----------------------------------------------

ok( !eval { $tira->column_remove( project => $root, type => 'ticket', name => 'staging', author => 'ada' ); 1 },
    'column.remove is refused without a reason' );
like( $@, qr/reason/i, 'and the refusal names what is missing' );

# --- the discard carries the reason and is journalled -----------------------

my $result = $tira->column_remove(
    project => $root, type => 'ticket', name => 'staging', author => 'ada',
    reason => 'consolidating staging into backlog',
);
is_deeply( $result->{discarded}, [ $card->{ref} ], 'the removal reports which cards it discarded' );

my $after = $tira->record_show( project => $root, ref => $card->{ref} );
is( $after->{column}, 'discard', 'the card is discarded' );

my ($explained) = grep { $_->{body} =~ /consolidating staging into backlog/ } @{ $after->{comments} };
ok( $explained, 'the discard reason is written onto the card as a comment' );
is( $explained->{author}, 'ada', 'attributed to whoever removed the column' );

my @moved = grep { ( $_->{after} // '' ) eq 'discard' } @{
    $tira->history_list( project => $root, ref => $card->{ref}, type => 'ticket', field => 'column' )
};
ok( @moved, 'the discard is journalled like any other move, not done by a silent rename' );

# --- discard-unexplained does not fire ---------------------------------------

my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'police' ), world => {} );
ok( !( grep { $_->{rule} eq 'discard-unexplained' && $_->{ref} eq $card->{ref} } @{ $pass->{violations} } ),
    'discard-unexplained does not fire for a card discarded with a real reason' );

# --- required items on OTHER cards naming the removed column are untouched --

$tira->column_add( project => $root, type => 'ticket', name => 'staging', label => 'Staging' );
my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Already moved on' );
$tira->record_move( project => $root, ref => $other->{ref}, column => 'staging', author => 'ada' );
$tira->required_item_add(
    project => $root, ref => $other->{ref}, column => 'staging',
    item => 'Verify the thing', status => 'pending', author => 'ada',
);
$tira->record_move( project => $root, ref => $other->{ref}, column => 'done', author => 'ada' );
$tira->column_remove(
    project => $root, type => 'ticket', name => 'staging', author => 'ada',
    reason => 'removing again for this test',
);
my $other_after = $tira->record_show( project => $root, ref => $other->{ref} );
my ($item) = grep { $_->{item} eq 'Verify the thing' } @{ $other_after->{required_items} // [] };
ok( $item, 'the required item on the OTHER card is still there, untouched, per the existing TKT-613/t/445 decision' );
is( $item->{column}, 'staging', 'and still names the removed column - not scrubbed' );

# --- an empty column is unchanged apart from needing a reason ---------------

$tira->column_add( project => $root, type => 'ticket', name => 'idle', label => 'Idle' );
ok( !eval { $tira->column_remove( project => $root, type => 'ticket', name => 'idle', author => 'ada' ); 1 },
    'an empty column still refuses without a reason' );
my $empty_result = $tira->column_remove(
    project => $root, type => 'ticket', name => 'idle', author => 'ada', reason => 'never used',
);
is_deeply( $empty_result->{discarded}, [], 'removing an empty column discards nothing, as before' );

done_testing;

__END__

=head1 NAME

t/481-a-removal-that-explains-itself.t - column.remove journals and
explains every card it discards

=head1 DESCRIPTION

C<column_remove> moved cards in the removed column by a filesystem
C<rename> straight into C<discard>, bypassing C<record_move> entirely - so
there was no journal entry, no author, and nothing had ever asked for a
reason. C<discard-unexplained> then fired on every one of them forever,
unable to tell an administrative removal from abandoned work.

C<column_remove> now refuses without C<--reason>, mirroring
C<column_roles_remove>'s existing precedent, and moves each card through
C<record_move> (journalled, attributed) followed by a C<comment_add>
carrying the reason, so C<discard-unexplained> is answered by the act that
caused it. Required items on cards that had already left the removed
column are deliberately left untouched - TKT-613/t/445 already decided
this is inert history rather than a live gap, and that decision stands.
TKT-701.

=cut
