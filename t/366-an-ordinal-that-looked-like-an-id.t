#!/usr/bin/env perl
# TKT-280. Probed live: 'tira.checklist.update --ref REF --id 1 --status done'
# against a card whose checklist entries are CHK-001..CHK-NNN answered
# "Checklist entry '1' not found" - true, and it named neither the shape the
# ids take nor how to discover it. An ordinal is the obvious thing to try,
# because entries print as a numbered list. The reporter looped '--id' 1..N
# believing it took the position, sent the loop's output to /dev/null, and
# reported three cards' checklists as ticked when every call had silently
# failed - the same shape TKT-268 fixed for a missing option: a refusal that
# says what is wrong should say what to type instead.

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
    name => 'Ordinal', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ODS', epic_prefix => 'ODE', ticket_prefix => 'ODT',
);

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with a real checklist', priority => 3 );
$tira->checklist_add( author => 'claude', project => $root, type => 'ticket',
    ref => $card->{ref}, item => 'First step', status => 'Open' );
$tira->checklist_add( author => 'claude', project => $root, type => 'ticket',
    ref => $card->{ref}, item => 'Second step', status => 'Open' );

# --- an ordinal, the obvious wrong guess ------------------------------------

my $error = eval {
    $tira->checklist_update( author => 'claude', project => $root, type => 'ticket',
        ref => $card->{ref}, id => '1', status => 'In Progress' );
    '';
} // $@;
like( $error, qr/Checklist entry '1' not found/, 'still refuses the ordinal' );
like( $error, qr/addressed by id/, 'and now says entries are addressed by id, not position' );
like( $error, qr/CHK-001/, 'and lists the ids this card actually has' );
like( $error, qr/CHK-002/, 'both of them, not just the first' );

# --- a genuinely wrong id on a card with no checklist yet -------------------

my $empty = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card with no checklist yet', priority => 3 );
my $error_empty = eval {
    $tira->checklist_update( author => 'claude', project => $root, type => 'ticket',
        ref => $empty->{ref}, id => 'CHK-001', status => 'In Progress' );
    '';
} // $@;
like( $error_empty, qr/Checklist entry 'CHK-001' not found/, 'still refuses on an empty checklist' );
like( $error_empty, qr/CHK-001, \.\.\./, 'and names the shape the ids take, since there is nothing to list' );
unlike( $error_empty, qr/entries are addressed by id, not position: \s*$/,
    'and does not print an empty, misleading id list' );

done_testing;

__END__

=head1 NAME

366-an-ordinal-that-looked-like-an-id.t - checklist.update names the id shape it wants

=head1 DESCRIPTION

C<checklist_update> refused an unknown checklist id with only "Checklist
entry '<id>' not found" - true, and silent about the fact that ids are
C<CHK-NNN> rather than a position, which is what a numbered display makes
someone reach for first. Reported live: a loop over ordinals 1..N failed on
every call, silently, and three cards' checklists were reported ticked when
none of them were.

The refusal now lists the card's real ids when it has any, or names the
C<CHK-NNN> shape when it has none - either way, the reader is told what to
type without a second command.

=cut
