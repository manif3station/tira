#!/usr/bin/env perl
# TKT-488, found immediately after shipping TKT-280 (checklist_update's
# identical bug): required_item_update refused an unknown id with only
# "Required item '<id>' not found" - no hint that ids are REQ-NNN rather
# than a position, the same shape TKT-280 fixed for checklist_update. Worth
# a real fix in its own right: required-action.update against REQ-NNN ids
# that shift as cards accumulate more required actions is one of the most
# common commands this project's own agent runs.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ordinal2', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RQS', epic_prefix => 'RQE', ticket_prefix => 'RQT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with real required items', priority => 3 );
$tira->required_item_add( author => 'claude', project => $root, type => 'ticket',
    ref => $card->{ref}, item => 'First requirement', status => 'pending' );
$tira->required_item_add( author => 'claude', project => $root, type => 'ticket',
    ref => $card->{ref}, item => 'Second requirement', status => 'pending' );

# --- an ordinal, the obvious wrong guess ------------------------------------

my $error = eval {
    $tira->required_item_update( author => 'claude', project => $root, type => 'ticket',
        ref => $card->{ref}, id => '1', status => 'in progress' );
    '';
} // $@;
like( $error, qr/Required item '1' not found/, 'still refuses the ordinal' );
like( $error, qr/addressed by id/, 'and now says entries are addressed by id, not position' );
like( $error, qr/REQ-001/, 'and lists the ids this card actually has' );
like( $error, qr/REQ-002/, 'both of them, not just the first' );

# --- a genuinely wrong id on a card with no required items yet -------------

my $empty = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with no required items yet', priority => 3 );
my $error_empty = eval {
    $tira->required_item_update( author => 'claude', project => $root, type => 'ticket',
        ref => $empty->{ref}, id => 'REQ-001', status => 'in progress' );
    '';
} // $@;
like( $error_empty, qr/Required item 'REQ-001' not found/, 'still refuses on a card with none yet' );
like( $error_empty, qr/REQ-001, \.\.\./, 'and names the shape the ids take, since there is nothing to list' );

done_testing;

__END__

=head1 NAME

367-a-required-item-that-looked-like-an-id-too.t - required_item_update names the id shape it wants

=head1 DESCRIPTION

Same bug as TKT-280, a different array: C<required_item_update> refused an
unknown checklist id with only "not found", naming neither the C<REQ-NNN>
shape nor the ids the card actually has. The refusal now lists the card's
real ids when it has any, or names the shape when it has none, matching
C<checklist_update>'s TKT-280 fix exactly.

=cut
