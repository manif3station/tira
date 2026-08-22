#!/usr/bin/env perl
# The column's required-action template is a baseline, not an absolute -
# some cards genuinely do not need every item a column normally requires.
# Owner, TG voice msg 4188: "有些card可能不需要全部required...那些agent是有權刪減或者
# 增加required item,specifically for那張card,但baseline根據policyset在column那裏"
# (some cards may not need everything required - the agent has the right to
# add or remove required items specifically for that card, but the baseline
# follows the policy set on the column). Settled design (Q-054): a per-card
# exemption list, tira.<type>.update --exempt-required TEXT, repeatable.
# Extra required items already work today - just checklist.add a new one, no
# new mechanism needed for that half. TKT-439.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Exempt', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc' ],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => [ 'left a note', 'said why' ] );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = "claude";
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Exempt from one' );
cli( 'record.move', '--ref', $card->{ref}, '--column', 'planning' );

# --- without an exemption, both items are demanded, exactly as before -----
my ( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
isnt( $status, 0, 'without an exemption, both required items are still demanded' );
like( $err, qr/left a note/, 'naming the first' );
like( $err, qr/said why/,    'and the second' );

# --- exempting one item lets the move succeed with only the other done -----
cli( 'record.update', '--ref', $card->{ref}, '--exempt-required', 'said why' );
my ($note) = grep { $_->{item} eq 'left a note' } @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
$tira->required_item_update( author => 'claude', project => $root, ref => $card->{ref}, id => $note->{id}, status => 'done',
    command => ['left it'], proof => ['note left'] );
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
is( $status, 0, 'with the second item exempted, the first done is enough' ) or diag($err);

# --- a sibling card with no exemption still needs both, unaffected --------
my $sibling = $tira->create_record( project => $root, type => 'ticket', title => 'No exemption' );
cli( 'record.move', '--ref', $sibling->{ref}, '--column', 'planning' );
my ($sibling_note) = grep { $_->{item} eq 'left a note' } @{ $tira->required_item_list( project => $root, ref => $sibling->{ref} ) };
$tira->required_item_update( author => 'claude', project => $root, ref => $sibling->{ref}, id => $sibling_note->{id}, status => 'done',
    command => ['left it'], proof => ['note left'] );
( $status, $out, $err ) = cli( 'record.move', '--ref', $sibling->{ref}, '--column', 'doc' );
isnt( $status, 0, "a sibling card's own exemption does not leak onto another card" );
like( $err, qr/said why/, 'still demanding the item this card was never exempted from' );

# --- an extra required item, beyond the column template, already works ----
my $extra = $tira->create_record( project => $root, type => 'ticket', title => 'Extra item' );
cli( 'record.move', '--ref', $extra->{ref}, '--column', 'planning' );
$tira->checklist_add( author => 'claude', project => $root, ref => $extra->{ref}, item => 'a card-specific extra step', status => 'pending' );
my ($n1) = grep { $_->{item} eq 'left a note' } @{ $tira->required_item_list( project => $root, ref => $extra->{ref} ) };
my ($n2) = grep { $_->{item} eq 'said why' } @{ $tira->required_item_list( project => $root, ref => $extra->{ref} ) };
$tira->required_item_update( author => 'claude', project => $root, ref => $extra->{ref}, id => $n1->{id}, status => 'done',
    command => ['left it'], proof => ['note left'] );
$tira->required_item_update( author => 'claude', project => $root, ref => $extra->{ref}, id => $n2->{id}, status => 'done',
    command => ['said why'], proof => ['reason given'] );
( $status, $out, $err ) = cli( 'record.move', '--ref', $extra->{ref}, '--column', 'doc' );
is( $status, 0, "an extra card-specific item, added with plain checklist.add, does not block the move - it was never part of the column's own template" )
  or diag($err);

done_testing;

__END__

=head1 NAME

307-a-card-that-said-no-to-one.t - a card can exempt itself from one of a column's required items

=head1 DESCRIPTION

Covers TKT-439's second half: tira.<type>.update --exempt-required TEXT
(repeatable, accumulating) lets a specific card diverge from a column's
required-action baseline. The move-out check skips anything on a card's
own exemption list. The exemption is per card - a sibling card's own
required items are unaffected. Extra, card-specific required items already
work via plain checklist.add, confirmed unaffected by this change.

=cut
