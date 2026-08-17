#!/usr/bin/env perl
# Two cards of equal urgency are taken oldest first, and the board says so.
#
# The ordering this board enforces is priority first, then the card that has
# waited longest. work_order has sorted by both since it was written.
# priority-skipped enforced one of them: its comparison is strictly greater
# priority, so two cards at the same priority were never compared and the older
# one could be passed over indefinitely without a word.
#
# Measured on this board, which is how it was found rather than reasoned:
# TKT-281 was created 2026-08-17T01:59:54 and worked before TKT-274, created
# 2026-08-16T23:23:45, both at priority 3, and nothing was reported. It came out
# of disproving TKT-294 - whose larger claim was false, the board having been
# worked correctly for the whole 7h49m that prompted it - and this tie is the
# one thing in that window that was not.
#
# It is also the shape TKT-274 exists to prevent, surviving in the half nobody
# looked at: the command and the rule agreed about which cards are waiting and
# disagreed about which of two equals should have been taken.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-17T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Tied', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'TDS', epic_prefix => 'TDE', ticket_prefix => 'TDT',
);
$tira->policy_add( project => $root, rule => 'priority-skipped',
    action => 'bridge-reminder' );

my $older = $tira->create_record( project => $root, type => 'ticket',
    title => 'Raised first, at priority 3', priority => 3 );
$now = '2026-08-17T11:00:00Z';
my $newer = $tira->create_record( project => $root, type => 'ticket',
    title => 'Raised later, at the same priority', priority => 3 );

sub skipped {
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    return [ grep { ( $_->{rule} // '' ) eq 'priority-skipped' }
          @{ $pass->{violations} } ];
}

# --- the board offers the older of two equals ------------------------------------
#
# Asserted first, so what follows is the rule failing to enforce an order the
# command already states, rather than two components disagreeing about it.

is( $tira->work_order( project => $root )->[0]{ref}, $older->{ref},
    'the board offers the older of two cards at the same priority' );

# --- and working the newer one is reported ---------------------------------------

{
    $now = '2026-08-17T12:00:00Z';
    $tira->record_move( project => $root, ref => $newer->{ref}, column => 'implement' );

    my $found = skipped();
    ok( scalar @{$found}, 'taking the newer of two equals is reported' );
    like( $found->[0]{detail} // '', qr/\Q$older->{ref}\E/,
        'naming the card that has waited longer' );
    is( $found->[0]{ref}, $newer->{ref}, 'against the card being worked' );
}

# --- while working the older one is not ------------------------------------------
#
# The half that keeps this a rule rather than a complaint about every tie.

{
    $tira->record_move( project => $root, ref => $newer->{ref}, column => 'backlog' );
    $now = '2026-08-17T13:00:00Z';
    $tira->record_move( project => $root, ref => $older->{ref}, column => 'implement' );

    is_deeply( [ map { $_->{detail} } @{ skipped() } ], [],
        'taking the older of two equals is not reported, because it is the right one' );
}

# --- and a higher card being worked is still not reported --------------------------
#
# Nothing about the priority comparison changes. A card worked ahead of lower
# ones is the ordinary case and was never a violation.

{
    $tira->record_move( project => $root, ref => $older->{ref}, column => 'backlog' );
    $now = '2026-08-17T14:00:00Z';
    my $urgent = $tira->create_record( project => $root, type => 'ticket',
        title => 'More urgent than either', priority => 5 );
    $tira->record_move( project => $root, ref => $urgent->{ref}, column => 'implement' );

    is_deeply( [ map { $_->{detail} } @{ skipped() } ], [],
        'working the most urgent card is not reported, whatever its age' );
}

# --- proved by comparing on priority alone again ------------------------------------
#
# The strictly-greater comparison the rule shipped with: the tie goes unreported,
# which is what let TKT-281 be worked ahead of TKT-274 in silence.

{
    $tira->record_move( project => $root, ref => $older->{ref}, column => 'backlog' );
    $now = '2026-08-17T15:00:00Z';
    $tira->record_move( project => $root, ref => $newer->{ref}, column => 'implement' );
    ok( scalar @{ skipped() }, 'the tie is reported' );

    no warnings 'redefine';
    local *Tira::_outranks_for_work = sub {
        my ( $self, $above, $record ) = @_;
        return ( $above->{priority} // 0 ) > ( $record->{priority} // 0 );
    };

    is_deeply( [ map { $_->{detail} } @{ skipped() } ], [],
        'comparing on priority alone lets it pass in silence, which is what shipped' );
}

done_testing;

__END__

=head1 NAME

263-the-half-of-the-ordering-nobody-enforced.t - equal priority, oldest first

=head1 DESCRIPTION

The board orders work by priority and then by age, and C<priority-skipped>
compared only priority - so two cards at the same priority were never compared
and the older could be passed over indefinitely without a word.

Measured on this board: TKT-281, created at 01:59, was worked before TKT-274,
created at 23:23 the night before, both at priority 3, and nothing was said.

=cut
