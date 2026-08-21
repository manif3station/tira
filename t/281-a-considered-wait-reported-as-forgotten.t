#!/usr/bin/env perl
# A column-scoped card-duration policy is a considered decision about exactly
# that column, and card-still's own board-wide age used to outrank it anyway.
#
# Measured on a real board, the night it happened. A resting column - Release
# Held - was added for work that is finished and final-checked, waiting for a
# release the owner holds until a whole part is done. The wait there is
# legitimate and can be long, so a watchdog was declared on purpose:
#
#   card-duration  --column release-held  --age 24h
#     "the wait is legitimate, but a whole day means the release has been
#      FORGOTTEN rather than held"
#
#   card-still  --age 4h  (board-wide, declared the day before)
#
# card-still won, because 4h comes first - five correctly-parked cards
# reported CRITICAL for doing exactly what the column exists for, and the
# declared 24h decision was quietly never in force. Not the shape 2.54 fixed:
# that was two policies for the SAME rule and scope, refused outright since.
# This is two DIFFERENT rules whose coverage happens to overlap on one
# column - card-still board-wide, card-duration column-scoped - so nothing
# refuses it, nothing reports it, and policy.list shows both looking
# perfectly healthy.
#
# card-still already has one precedent for exactly this shape: a column's own
# --notify-after outranks the policy's own declared age (TKT-278), because
# "some columns want no watching at all" and the column knows its own case
# better than a board-wide number does. A card-duration policy is that same
# case made explicit and considered, with a written reason attached - the
# reporter's own words apply, "the precedence order your own docs already
# state for card over column over board over project, one step further out."
# card-still now stands down for a column a card-duration policy already
# watches, rather than firing at its own, less-considered age underneath it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-18T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Held', dir => $root, members => ['claude'],
    columns => ['backlog, implement, release-held, elsewhere, done'],
    sow_prefix => 'HLS', epic_prefix => 'HLE', ticket_prefix => 'HLT',
);

$tira->policy_add( project => $root, rule => 'card-still', action => 'bridge-reminder', age => '4h' );
$tira->policy_add( project => $root, rule => 'card-duration', action => 'bridge-reminder',
    column => 'release-held', age => '24h',
    message => 'the wait is legitimate, but a whole day means the release has been FORGOTTEN rather than held' );

my $held = $tira->create_record( project => $root, type => 'ticket', title => 'Parked on purpose' );
$tira->record_move(author => 'claude',  project => $root, ref => $held->{ref}, column => 'release-held' );

my $unrelated = $tira->create_record( project => $root, type => 'ticket', title => 'A different column' );
$tira->record_move(author => 'claude',  project => $root, ref => $unrelated->{ref}, column => 'elsewhere' );

sub findings_for {
    my ($rule) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return { map { $_->{ref} => $_ }
          grep { ( $_->{rule} // '' ) eq $rule } @{ $pass->{violations} } };
}

# --- five hours later: past card-still's 4h, well under card-duration's 24h ----

$now = '2026-08-18T14:00:00Z';

{
    my $still = findings_for('card-still');
    ok( !$still->{ $held->{ref} },
        'a card in the column a card-duration policy watches is not reported by card-still at its own age' );

    my $duration = findings_for('card-duration');
    ok( !$duration->{ $held->{ref} },
        'and card-duration itself has not fired yet either - five hours is still inside the 24h it was given' );
}

# --- while an unrelated column, with no card-duration policy of its own, is unchanged ---

{
    my $still = findings_for('card-still');
    ok( $still->{ $unrelated->{ref} },
        'a column nothing else watches still reports at card-still\'s own age, exactly as before' );
}

# --- past 24h: card-duration fires, on its own considered age ------------------

$now = '2026-08-19T10:00:00Z';    # 25 hours after the card was moved into release-held

{
    my $duration = findings_for('card-duration');
    ok( $duration->{ $held->{ref} },
        'past the 24h it was actually given, card-duration reports it - the watchdog is real, not disabled' );
    like( $duration->{ $held->{ref} }{message} // '', qr/FORGOTTEN/,
        'carrying the reason that was written down for it' );

    my $still = findings_for('card-still');
    ok( !$still->{ $held->{ref} },
        'and card-still still stands down for that column - one report of a true thing, not two' );
}

# --- proved by removing the stand-down: the old defect comes back --------------

{
    no warnings 'redefine';
    local *Tira::_card_duration_governs = sub { return 0 };

    $now = '2026-08-18T14:00:00Z';
    my $still = findings_for('card-still');
    ok( $still->{ $held->{ref} },
        'without the stand-down, the same five-hour-old card is reported CRITICAL again - the exact defect reported' );
}

done_testing;

__END__

=head1 NAME

281-a-considered-wait-reported-as-forgotten.t - TKT-355

=head1 DESCRIPTION

C<card-still> is board-wide and C<card-duration> is column-scoped, so nothing
in 2.54's duplicate refusal (TKT-339, same rule and scope) could see the two
overlapping on one column - a five-hour-old card in a column deliberately
given 24 hours was reported CRITICAL by card-still's own 4-hour age, and the
considered decision was quietly never in force. C<card-still> now stands down
for a column a card-duration policy already watches, following the same
precedent that already lets a column's own C<--notify-after> outrank the
policy's declared age.

=cut
