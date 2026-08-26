#!/usr/bin/env perl
# agent-still sent an identical Telegram message on every poll that found the
# agent still stopped - roughly once a minute for as long as the stall
# lasted, because it deliberately goes around the bridge (the one channel
# with its own seen/settle throttling) and had nothing standing in for that
# on its own direct-to-Telegram path.
#
# Confirmed live by the owner: a screenshot of his phone showing the same
# message, "Tira: the agent has stopped ... which is 52m/53m/54m/55m...",
# roughly sixty seconds apart, only the elapsed-time figure changing. TKT-422.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-18T01:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Throttled', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'THS', epic_prefix => 'THE', ticket_prefix => 'THT',
);
$tira->project_update( project => $root, agent => 'claude' );
$tira->policy_add( project => $root, rule => 'agent-still', age => '1s', action => 'bridge-reminder', notify => 1 );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Stopped', priority => 5, assignee => 'claude' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

# Long past the 1s age threshold - the agent's last action stays at this
# board's creation time while $now moves on, which is what a real stall is.
$now = '2026-08-18T02:00:00Z';

my @sent;
{
    local *Tira::_send_notification = sub {
        my ( undef, %args ) = @_;
        push @sent, $args{text};
        return 1;
    };

    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 1, 'the first poll that finds the stall sends once' );

    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 1, 'a second poll, seconds later, does not send again' );

    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 1, 'nor a third - the same stall, still within the throttle window' );

    # Past the throttle window (900s), the same ongoing stall is reminded again.
    $now = '2026-08-18T02:16:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 2, 'past the throttle window, the same stall is reminded again' );
    like( $sent[-1], qr/the agent has stopped/, 'with the same message the rule always sends' );

    # A stall that ends and a new one that starts is not "the same stall" -
    # the owner should hear about a fresh stoppage without waiting out the
    # window from the last one.
    $now = '2026-08-18T02:17:00Z';
    $tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'done' );
    my $second_card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Stopped again', priority => 5, assignee => 'claude' );
    $tira->record_move(author => 'claude',  project => $root, ref => $second_card->{ref}, column => 'implement' );
    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 2, 'acting again is not itself a stall, so nothing new is sent yet' );

    $now = '2026-08-18T02:17:05Z';
    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 3, 'a new stall, seconds after the old one ended, is reported without waiting out the old window' );
}

done_testing;

__END__

=head1 NAME

294-the-same-warning-twice-a-minute.t - one reminder per stall, not per poll

=head1 DESCRIPTION

agent-still sends its Telegram message directly, bypassing the bridge's own
seen/settle throttling on purpose - the whole point of the rule is to reach
someone when the agent, who reads the bridge, is the one not listening. That
also meant nothing throttled the direct send itself: every ~30 second poll
that still found the agent stopped sent an identical message. This proves
one send per stall, a repeat reminder only after the throttle window if the
same stall continues, and an immediate reminder for a genuinely new stall
rather than a wait for the old window to expire.

=cut
