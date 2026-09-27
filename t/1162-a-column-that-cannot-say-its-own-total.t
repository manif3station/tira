#!/usr/bin/env perl
# TKT-730: a budgeting board built on Tira has no way to ask a column for its
# own total - the balance a card's column holds is the sum of that column's
# cards, and today that sum can only be computed by fetching every card and
# folding it in the caller.
#
# Michael's answer to Q-191 chose the smallest shape that closes this: a
# single numeric field, declared once per board, plus a --sum FIELD flag on
# tira.<type>.list that composes with --column and --where exactly the way
# --count already does.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-09-27T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Budget', dir => $root, members => ['claude'],
    columns => ['backlog, pod-a, pod-b, done'],
    sow_prefix => 'BGS', epic_prefix => 'BGE', ticket_prefix => 'BGT',
);

# --- a board with no declared numeric field yet refuses --sum outright -----

my $too_soon = eval {
    $tira->record_list( project => $root, type => 'ticket', sum => 'amount' );
    1;
};
ok( !$too_soon, 'sum on a board with no declared numeric field dies rather than silently summing nothing' );
like( $@, qr/No numeric field is declared/, 'the refusal names the missing declaration' );

# --- declaring the field is a one-time, per-board setting -------------------

$tira->project_update( project => $root, numeric_field => 'amount' );

# --- and it validates the argument to --sum against the declared name ------

my $wrong_field = eval {
    $tira->record_list( project => $root, type => 'ticket', sum => 'points' );
    1;
};
ok( !$wrong_field, 'summing a field other than the one declared for this board dies' );
like( $@, qr/Unknown numeric field 'points'/, 'the refusal names the field it was actually given' );

# --- cards set the field like any other card field --------------------------

my $card_a1 = $tira->create_record( project => $root, type => 'ticket',
    title => 'Opening balance A', column => 'pod-a', numeric_value => '100.50' );
my $card_a2 = $tira->create_record( project => $root, type => 'ticket',
    title => 'A withdrawal', column => 'pod-a', numeric_value => '-22.75' );
my $card_b1 = $tira->create_record( project => $root, type => 'ticket',
    title => 'Opening balance B', column => 'pod-b', numeric_value => '40' );

# A card that never sets the field at all - the case this ticket's own
# acceptance criteria singles out: excluded from the sum, not zero.
my $card_unset = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card nobody has priced yet', column => 'pod-a' );

is( $tira->record_show( project => $root, ref => $card_a1->{ref} )->{numeric_value}, 100.5,
    'the value round-trips through create_record like any other card field' );

# --- the plain sum, across the whole board -----------------------------------

my $whole_board = $tira->record_list( project => $root, type => 'ticket', sum => 'amount' );
is( $whole_board->{sum}, 100.50 + ( -22.75 ) + 40, 'sum totals every card that set the field, across the whole board' );
is( scalar @{ $whole_board->{records} }, 4,
    'the normal record output rides alongside the total, not replaced by it - all four cards are still there' );
ok( !( grep { $_->{ref} eq $card_unset->{ref} && defined $_->{numeric_value} } @{ $whole_board->{records} } ),
    'the unpriced card is present in the record list but carries no numeric_value' );

# --- composing with --column, the same way --count already does ------------

my $pod_a_only = $tira->record_list( project => $root, type => 'ticket', column => 'pod-a', sum => 'amount' );
is( $pod_a_only->{sum}, 100.50 + ( -22.75 ), 'sum composes with column - only that column\'s cards are totalled' );

my $pod_b_only = $tira->record_list( project => $root, type => 'ticket', column => 'pod-b', sum => 'amount' );
is( $pod_b_only->{sum}, 40, 'a different column totals only its own cards' );

# --- composing with --where, the same way --count already does ------------

my $only_a2 = $tira->record_list(
    project => $root, type => 'ticket',
    where => ["title=A withdrawal"], sum => 'amount',
);
is( $only_a2->{sum}, -22.75, 'sum composes with where - only matching records are totalled' );

# --- a card the field was never set on is excluded, not treated as zero ----

my $set_only = grep { defined $_->{numeric_value} } @{ $whole_board->{records} };
is( $set_only, 3, 'exactly the three priced cards carry a numeric_value - the unpriced one is not a hidden zero' );

done_testing;

__END__

=head1 NAME

1162-a-column-that-cannot-say-its-own-total.t - a board's numeric field, declared once, summed via --sum

=head1 DESCRIPTION

TKT-730 (filed from a budgeting use of Tira): a column's balance is the sum of
its cards' amounts, and Tira had no numeric card field and no aggregation
across cards to compute it - every "sum" in the tool before this ticket
counted entries (C<--count>), never totalled a value anyone set.

Michael's answer to Q-191 chose the smallest fix: a single numeric field,
declared once per board via C<tira.project.update --numeric-field NAME>, set
on any card via the same C<numeric_value> slot C<create_record>/
C<record_update> already validate other typed fields through (mirroring
C<priority>'s own C<_valid_priority>), and read back with C<--sum FIELD> on
C<tira.<type>.list>, composing with C<--column> and C<--where> exactly the
way C<--count> already does. A card that never set the field is excluded from
the total, not folded in as a silent zero - the field is a fact a card has or
does not have, not a default.

=cut
