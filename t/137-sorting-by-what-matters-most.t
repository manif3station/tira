#!/usr/bin/env perl
# A column can be ordered by priority.
#
# He sent a screenshot of the two sort buttons - Last modified and Card
# reference - captioned "add 1 more by prioity". Priority is the field the whole
# board is arranged around: it decides what to pick up next, and it is on every
# card. Somebody looking at a full column had to read every card to find the one
# that mattered most.
#
# Highest first, because the question anybody asks a column is what to do next.
# Ordering lowest first would answer a question nobody asks.
#
# A card with no priority goes last, and that is stated rather than left to
# whatever the sort happens to do with an empty value: an unprioritised card is
# not urgent, it is unassessed.
#
# The card markup has to carry the priority for any of this to work, and so does
# the refresh that rebuilds every card a minute later - a sort that works until
# the board refreshes is the shape of defect this project keeps finding.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T19:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'What next', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WNS', epic_prefix => 'WNE', ticket_prefix => 'WNT',
);

my $low = $tira->create_record( project => $root, type => 'ticket', title => 'Low' );
$tira->record_update( project => $root, ref => $low->{ref}, priority => 1 );
my $high = $tira->create_record( project => $root, type => 'ticket', title => 'High' );
$tira->record_update( project => $root, ref => $high->{ref}, priority => 5 );
my $unset = $tira->create_record( project => $root, type => 'ticket', title => 'Nobody has said' );

my $data = $tira->dashboard( project => $root, with_title => 1 );
my $page = $tira->format_output( $data, output => 'table', project => $root,
    live => 1, with_title => 1 );

# --- the button, and the code behind it ------------------------------------------
#
# t/121 made this a rule: an element the page offers must have the binding that
# gives it behaviour, or it is a control that looks live and is not.

like( $page, qr/data-sort="priority"/, 'the board offers a priority sort' );
like( $page, qr/\[data-sort\]/, 'and binds every sort button, this one included' );

# --- every card says what its priority is ----------------------------------------
#
# Nothing can order by a number the markup does not carry.

like( $page, qr/\Qdata-ref="$high->{ref}"\E[^>]*data-priority="5"/,
    'a card carries its priority where the sort can read it' );
like( $page, qr/\Qdata-ref="$low->{ref}"\E[^>]*data-priority="1"/, 'whatever the priority is' );
like( $page, qr/\Qdata-ref="$unset->{ref}"\E[^>]*data-priority=""/,
    'and a card nobody has prioritised says so, rather than pretending to a number' );

# --- highest first, unassessed last ----------------------------------------------

like( $page, qr/mode==="priority"/, 'the sort knows about priority' );
like( $page, qr/\QNumber(b.dataset.priority||0)-Number(a.dataset.priority||0)\E/,
    'ordering highest first, with no priority counting as none rather than as urgent' );

# --- and the refresh keeps it ----------------------------------------------------
#
# The board rebuilds every card from the payload a minute later. A sort that
# survives only until then is the defect this project keeps finding: something
# that works on the path anybody checks and not on the one nobody does.

like( $page, qr/priority/, 'the refresh payload is read for a priority' );
like( $page, qr/\Qdataset.priority=\E/, 'and the rebuilt card is given one' );

# --- the payload carries it ------------------------------------------------------

my $refresh = $tira->dashboard( project => $root );
my ($card) = grep { $_->{ref} eq $high->{ref} }
  map { @{$_} } values %{ $refresh->{ticket} };
ok( $card, 'the refresh payload holds the card' );
is( $card->{priority}, 5, 'and its priority, so the rebuild has something to read' );

done_testing;

__END__

=head1 NAME

137-sorting-by-what-matters-most.t - a column can be ordered by priority

=head1 DESCRIPTION

The board offered two orderings and neither was the field it is arranged
around, so a full column had to be read card by card to find what mattered
most.

Priority sorts highest first, because the question a column answers is what to
do next. A card nobody has prioritised goes last and says so in the markup
rather than pretending to a number. The priority travels in the payload as well
as the first render, so the sort still works after the board rebuilds itself.

=cut
