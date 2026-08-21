#!/usr/bin/env perl
# Required items were never meant to share a card's checklist - they are a
# genuinely separate list, organized by the column each item came from, with
# their own add/list/update commands. Owner, TG voice 4236 (2026-08-20),
# restating and extending the original design (voice 4188, given before this
# session): opening a card should show, per column, which required items are
# done or not; an agent can remove a column's required item from one specific
# card (exemption, TKT-439) AND add a new required item to one specific card
# that ALSO gates that card's move-out - not just a plain, non-gating
# checklist.add. checklist stays purely manual from here on. TKT-445.

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
    name => 'Required', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'planning', 'doc', 'review' ],
    sow_prefix => 'RQS', epic_prefix => 'RQE', ticket_prefix => 'RQT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'backlog', required_action => ['said why'] );
$tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => [ 'left a note', 'reviewed by someone else' ] );

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

sub by_item {
    my ($ref) = @_;
    my $rec = $tira->record_show( project => $root, ref => $ref );
    return map { $_->{item} => $_ } @{ $rec->{required_items} };
}

# --- creation into a column with required_actions populates required_items,
#     NOT checklist ------------------------------------------------------
my ( $status, $out, $err ) = cli( 'record.create', '--title', 'Born in backlog' );
is( $status, 0, 'card created via the CLI path' ) or diag($err);
my ($card) = grep { $_->{title} eq 'Born in backlog' } @{ $tira->record_list( project => $root, type => 'ticket' ) };
my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
is_deeply( $shown->{checklist}, [], 'checklist starts empty - required items never land there' );
is( scalar @{ $shown->{required_items} }, 1, 'required_items carries the entry column template instead' );
is( $shown->{required_items}[0]{item}, 'said why', 'the item text' );
is( $shown->{required_items}[0]{column}, 'backlog', 'tagged with the column it came from' );
is( $shown->{required_items}[0]{status}, 'pending', 'starts pending' );

$tira->checklist_add( project => $root, ref => $card->{ref}, item => 'unrelated manual step', status => 'pending' );

# --- move-out refuses while the current column's required items are unmet -
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
isnt( $status, 0, 'refused - backlog\'s own item is still pending' );
like( $err, qr/said why/, 'naming it' );

my %by = by_item( $card->{ref} );
cli( 'required-action.update', '--ref', $card->{ref}, '--id', $by{'said why'}{id}, '--status', 'done',
    '--command', 'said it', '--proof', 'reason given' );

# --- move-in populates required_items, tagged with the destination column -
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
is( $status, 0, 'moves now that backlog\'s item is done' ) or diag($err);
$shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar @{ $shown->{required_items} }, 3, 'planning added its own two items alongside backlog\'s one' );
is_deeply( $shown->{checklist}, [ { %{ $shown->{checklist}[0] } } ], 'checklist still carries only the earlier manual item' );
%by = by_item( $card->{ref} );
is( $by{'left a note'}{column}, 'planning', 'new items tagged with planning' );
is( $by{'reviewed by someone else'}{column}, 'planning', 'both of planning\'s items' );

# --- move-out refuses while required_items are unmet, naming them ---------
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
isnt( $status, 0, 'refused while required items are pending' );
like( $err, qr/left a note/,                 'names one planning item' );
like( $err, qr/reviewed by someone else/,    'names the other' );
unlike( $err, qr/said why/,                  'not backlog\'s already-done item' );

# --- required-exempt works against required_items -------------------------
cli( 'record.update', '--ref', $card->{ref}, '--exempt-required', 'left a note' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
isnt( $status, 0, 'still refused - the other planning item is still pending' );
like( $err, qr/reviewed by someone else/, 'names only the still-unmet item' );
unlike( $err, qr/left a note/,            'the exempted item is not demanded' );

cli( 'required-action.update', '--ref', $card->{ref}, '--id', $by{'reviewed by someone else'}{id}, '--status', 'done',
    '--command', 'reviewed it', '--proof', 'review complete' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
is( $status, 0, 'moves into doc now that the one unexempted item is done' ) or diag($err);

# --- required-action.add lets an agent add a genuinely gating item to just
#     this one card - distinct from a plain, non-gating checklist.add ------
( $status, $out, $err ) = cli( 'required-action.add', '--ref', $card->{ref}, '--item', 'card-specific extra check', '--status', 'pending' );
is( $status, 0, 'required-action.add succeeds' ) or diag($err);
%by = by_item( $card->{ref} );
is( $by{'card-specific extra check'}{column}, 'doc', 'tagged with doc - wherever the card sits when it is added' );

( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'review' );
isnt( $status, 0, 'refused - the card-specific item was never marked done, and it DOES gate' );
like( $err, qr/card-specific extra check/, 'naming the card-specific item' );

$shown = $tira->record_show( project => $root, ref => $card->{ref} );
is( scalar( grep { $_->{item} eq 'unrelated manual step' } @{ $shown->{checklist} } ), 1,
    'the earlier plain checklist.add is still on checklist, untouched and non-gating, unaffected by any of this' );
is( scalar( grep { $_->{item} eq 'card-specific extra check' } @{ $shown->{checklist} } ), 0,
    'and required-action.add never wrote into checklist either' );

# --- required-action.list reads them back ----------------------------------
my ( $lstatus, $lout, $lerr ) = cli( 'required-action.list', '--ref', $card->{ref}, '-o', 'json' );
is( $lstatus, 0, 'required-action.list succeeds' ) or diag($lerr);
require Cpanel::JSON::XS;
my $listed = Cpanel::JSON::XS::decode_json($lout);
is( scalar @{$listed}, 4, 'required-action.list returns every item - backlog, both planning, and the card-specific one' )
  or diag( explain $listed );

cli( 'required-action.update', '--ref', $card->{ref}, '--id', $by{'card-specific extra check'}{id}, '--status', 'done',
    '--command', 'checked it', '--proof', 'check passed' );
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'review' );
is( $status, 0, 'moves cleanly once the card-specific item is done too' ) or diag($err);

# --- backward move resets required_items (not checklist) for columns
#     from the destination through the origin, inclusive on both ends,
#     scoped by the column each item was tagged with -----------------------
( $status, $out, $err ) = cli( 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
is( $status, 0, 'moves backward unconditionally' ) or diag($err);
$shown = $tira->record_show( project => $root, ref => $card->{ref} );
%by = by_item( $card->{ref} );
is( $by{'card-specific extra check'}{status}, 'pending',
    'the doc-tagged card-specific item resets - doc is strictly between planning (destination) and review (origin)' );
is( $by{'reviewed by someone else'}{status}, 'pending',
    'and planning\'s own item, the destination itself, resets too - landing on it means its own check applies again' );
is( $by{'said why'}{status}, 'done',
    'and backlog\'s item, strictly before the range, is untouched too' );
is( scalar( grep { $_->{item} eq 'unrelated manual step' } @{ $shown->{checklist} } ), 1,
    'checklist is completely unaffected by the backward reset' );

# --- a sibling card's required items are entirely independent -------------
cli( 'record.create', '--title', 'Sibling' );
my ($sibling) = grep { $_->{title} eq 'Sibling' } @{ $tira->record_list( project => $root, type => 'ticket' ) };
$shown = $tira->record_show( project => $root, ref => $sibling->{ref} );
is( $shown->{required_items}[0]{status}, 'pending', "a sibling card's own copy starts fresh, unaffected by the first card's history" );

done_testing;

__END__

=head1 NAME

309-a-list-that-was-never-its-own.t - required items live on their own list, organized by column, separate from checklist

=head1 DESCRIPTION

Covers TKT-445: required-action items (from a column's template, or added
specifically to one card) are stored in a new required_items field, never in
checklist. Each entry is tagged with the column it applies to. Move-in and
creation-time population, the move-out gate, the per-card exemption list
(TKT-439), and the backward-move reset all read/write required_items.
required-action.add/list/update are new commands for the new list;
required-action.add lets an agent add a genuinely gating item to one specific
card, distinct from a plain checklist.add's non-gating extra, tagged with
whichever column the card is in at the time it is added. checklist is
confirmed unaffected throughout - purely manual, as it always was before
TKT-427 first touched it.

=cut
