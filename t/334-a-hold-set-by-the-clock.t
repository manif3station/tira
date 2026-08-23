#!/usr/bin/env perl
# A card held on an unanswered question is not offered by work_order (TKT-296).
# A card held on a future start_date was - the other machine-readable hold this
# board already validates, and after 2.45 work_order read one and not the other.
#
# Reported against a card that measures a live trading window: it cannot run
# until the window closes at a known time, competing for a shared broker
# terminal with two live bots. That hold is not a decision waiting on the
# owner - a question would be a fabricated one - it is a time, and start_date
# is where a time belongs. TKT-309.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Windowed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WNS', epic_prefix => 'WNE', ticket_prefix => 'WNT',
);

my $held = $tira->create_record( project => $root, type => 'ticket',
    title => 'Cannot run until the trading window closes', priority => 5,
    start_date => '2026-08-23T17:00:00Z' );
my $free = $tira->create_record( project => $root, type => 'ticket',
    title => 'Nothing is holding this one', priority => 4 );

# --- a future start_date holds the card, the same way an unanswered question does --

{
    my $order = $tira->work_order( project => $root );
    is( $order->[0]{ref}, $free->{ref},
        'the answer is the highest card that is not held by a future start_date' );

    my %offered = map { $_->{ref} => 1 } @{$order};
    ok( !$offered{ $held->{ref} },
        'and the held card is not offered anywhere, rather than offered further down' );
}

# --- a card with no start_date at all is unaffected -----------------------------

is( scalar @{ $tira->work_order( project => $root ) }, 1,
    'a card with no start_date is unaffected - only the one with a future date is held' );

# --- a PAST start_date does not hold the card ------------------------------------

my $already_open = $tira->create_record( project => $root, type => 'ticket',
    title => 'Its window already opened', priority => 3,
    start_date => '2026-08-23T08:00:00Z' );

{
    my %offered = map { $_->{ref} => 1 } @{ $tira->work_order( project => $root ) };
    ok( $offered{ $already_open->{ref} },
        'a start_date already in the past does not hold the card' );
}

# --- and once the clock passes the date, the hold releases -----------------------

$now = '2026-08-23T17:00:01Z';

{
    my %offered = map { $_->{ref} => 1 } @{ $tira->work_order( project => $root ) };
    ok( $offered{ $held->{ref} },
        'once start_date has passed, the card is offered again' );
    is( $tira->work_order( project => $root )->[0]{ref}, $held->{ref},
        'and it is the answer, since it is the highest priority now that nothing holds it' );
}

done_testing;

__END__

=head1 NAME

334-a-hold-set-by-the-clock.t - a future start_date holds a card in work_order

=head1 DESCRIPTION

C<work_order> read an unanswered question as a hold (TKT-296) but not a
future C<start_date> - the other machine-readable, already-validated hold
this board carries. A card whose window has not opened yet (a maintenance
window, an embargo, a market close) is now parked the same way an
unanswered question parks one; a past or absent C<start_date> is unchanged.
TKT-309.

=cut
