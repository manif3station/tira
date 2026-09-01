#!/usr/bin/env perl
# TKT-800. policy_review's declined array only ever held board-wide
# declines (data->{declined_policies}); per-card declines
# (data->{card_declines}, added by TKT-303's --ref scoping on
# policy_decline) were invisible to it. A board using per-card declines
# could not get a true "how many declines exist here" answer from the one
# command built for that question - measured on a real board: 2 board-wide
# + 2 per-card declines existed, and policy_review's declined[] held only
# the 2 board-wide ones, with the per-card ref appearing nowhere in its
# output.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-01T09:00:00+0100'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Reviewed', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'RVS', epic_prefix => 'RVE', ticket_prefix => 'RVT',
);

my $card = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'A card' );

$tira->policy_decline( project => $root, rule => 'card-unlinked', reason => 'board-wide, this project has no epics yet' );
$tira->policy_decline(
    project => $root, rule => 'priority-skipped', ref => $card->{ref},
    reason => 'owner claimed, handling himself', author => 'ada' );

my $review = $tira->policy_review( project => $root );

is( scalar @{ $review->{declined} }, 1, 'the board-wide decline is still reported where it always was' );

ok( exists $review->{declined_per_card}, 'a new key reports per-card declines - the whole set now has somewhere to live' );
is( scalar @{ $review->{declined_per_card} }, 1, 'the one per-card decline that exists is reported' );

my ($per_card) = @{ $review->{declined_per_card} };
is( $per_card->{ref}, $card->{ref}, 'tagged with the card it belongs to - the detail the old view had nowhere to put' );
is( $per_card->{rule}, 'priority-skipped', 'and the rule it answers' );
is( $per_card->{reason}, 'owner claimed, handling himself', 'and the reason given' );

# --- a board with no per-card declines gets an empty list, not a missing key -
{
    my $root2 = File::Spec->catdir( $tmp, 'clean' );
    $tira->project_new(
        name => 'Clean', dir => $root2, members => ['ada'],
        columns => ['backlog, doing, done'],
        sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
    );
    my $clean_review = $tira->policy_review( project => $root2 );
    ok( exists $clean_review->{declined_per_card}, 'the key exists even with nothing declined per-card' );
    is_deeply( $clean_review->{declined_per_card}, [], 'and is an empty list, not absent or undef' );
}

done_testing;

__END__

=head1 NAME

t/470-a-review-that-forgot-half-the-declines.t - policy_review reports
per-card declines alongside board-wide ones

=head1 DESCRIPTION

C<policy_review> is documented as printing "the whole set in one place" -
every rule declared, declined, or unanswered. Per-card declines
(C<policy_decline --ref CARD>, TKT-303) were a real fourth category the
review never read: they live in C<data-E<gt>{card_declines}>, a separate
store from the board-wide C<data-E<gt>{declined_policies}> that
C<policy_review>'s C<declined> array was built from.

Fixed by adding a new C<declined_per_card> key, read directly from
C<card_declines>, rather than changing the shape of the existing
C<declined> array - anything already parsing C<policy_review> as
board-wide-only keeps working. TKT-800.

=cut
