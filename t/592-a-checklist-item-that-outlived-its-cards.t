#!/usr/bin/env perl
# TKT-867. An epic checklist item names its child cards in its own text - there
# is no structured refs field the way a tasklist item has. When every named
# card reaches a terminal column, nothing marks the item, so checklist-idle
# goes on claiming the epic's work is outstanding.
#
# MEASURED on this board, 2026-09-02 21:45: EPC-014 had 8 checklist items, ALL
# open, while 7 of its 8 named cards had already reached done.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'store' );
my $now   = '2026-09-07T09:00:00Z';

my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Outlived', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'OLS', epic_prefix => 'OLE', ticket_prefix => 'OLT',
);
$tira->policy_add( project => $root, rule => 'checklist-item-terminal',
    action => 'bridge-reminder' );

sub findings {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'checklist-item-terminal' } @{ $pass->{violations} } ];
}

# Routed through the real dashboard move path (TKT-1144/TKT-1145: record_move
# itself now enforces the column chain for every other caller) - these skip
# straight to 'done', not what this file is testing.
sub browser_moved {
    my ( $ref, $column ) = @_;
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    return $providers{move}->( { ref => $ref, column => $column, type => 'ticket', _signed_in => 'claude' } );
}

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Outlived epic' );
my $one  = $tira->create_record( project => $root, type => 'ticket', title => 'Card one' );
my $two  = $tira->create_record( project => $root, type => 'ticket', title => 'Card two' );

$tira->checklist_add( author => 'claude', project => $root, ref => $epic->{ref},
    item => "$one->{ref} done", status => 'To Do' );
$tira->checklist_add( author => 'claude', project => $root, ref => $epic->{ref},
    item => "$one->{ref}, $two->{ref} both done", status => 'To Do' );
$tira->checklist_add( author => 'claude', project => $root, ref => $epic->{ref},
    item => 'No card named here', status => 'To Do' );

# --- neither card finished yet - nothing reported ---------------------------

is( scalar @{ findings() }, 0, 'nothing reported while the named card is still open' );

# --- one card reaches done, its own item fires -------------------------------

browser_moved( $one->{ref}, 'done' );

my $after_one = findings();
is( scalar @{$after_one}, 1, 'the item naming only the finished card is reported' );
like( $after_one->[0]{detail}, qr/CHK-001/, 'it names the checklist item id' );
like( $after_one->[0]{detail}, qr/\Q$one->{ref}\E/, 'and the card ref' );
like( $after_one->[0]{detail}, qr/done/, "and the card's column" );

# --- the two-card item stays quiet until BOTH finish -------------------------

my @two_card = grep { $_->{detail} =~ /CHK-002/ } @{$after_one};
is( scalar @two_card, 0, 'the item naming two cards is not reported while one is still open' );

browser_moved( $two->{ref}, 'done' );
my $after_two = findings();
my @two_card_now = grep { $_->{detail} =~ /CHK-002/ } @{$after_two};
is( scalar @two_card_now, 1, 'and is reported once both are terminal' );

# --- the item naming no card is never reported --------------------------------

my @no_card = grep { $_->{detail} =~ /CHK-003/ } @{$after_two};
is( scalar @no_card, 0, 'an item naming no card is never reported' );

# --- the rule marks nothing itself --------------------------------------------

my $epic_now = $tira->record_show( project => $root, ref => $epic->{ref} );
ok( ( grep { lc( $_->{status} ) ne 'done' } @{ $epic_now->{checklist} } ),
    'the rule reports only - the items it named are still open after the pass' );

# --- the rule declares no age, and refuses one rather than storing it --------
# TKT-1000: this refusal existed since TKT-867 but nothing exercised it.

my $refused = eval {
    $tira->policy_add( project => $root, rule => 'checklist-item-terminal',
        age => '1h', action => 'bridge-reminder' );
    1;
};
ok( !$refused, 'checklist-item-terminal refuses an --age rather than silently storing it' );
like( $@, qr/takes no --age/, 'and says so' );

done_testing;

__END__

=head1 NAME

592-a-checklist-item-that-outlived-its-cards.t - checklist-item-terminal

=head1 DESCRIPTION

TKT-867. An epic or sow checklist item that names its child cards in free
text - the only shape a checklist item has, unlike a tasklist item's
structured C<refs> - stays open forever once every named card finishes,
because nothing marks it. C<checklist-idle> then goes on reporting the epic
as though its work were outstanding, on an epic whose children are all done.

C<checklist-item-terminal> reports an item once every card it names has
reached a terminal column, naming the item id, each card's ref and column,
and marks nothing itself - the same reporting-only discipline every other
police rule keeps.

=cut
