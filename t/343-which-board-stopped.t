#!/usr/bin/env perl
# agent-still's Telegram message names cards but never the board itself - on a
# machine running several projects with this skill installed, the owner
# receiving "Tira: the agent has stopped" cannot tell which project it is
# about without cross-referencing card prefixes by hand.
#
# Confirmed live by the owner: a Telegram alert naming EVT- prefixed cards,
# with no way to tell which of his several projects it was about. TKT-480.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-23T01:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Named', dir => $root, members => [ 'claude', 'michael' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NMS', epic_prefix => 'NME', ticket_prefix => 'NMT',
);
$tira->project_update( project => $root, agent => 'claude' );
$tira->policy_add( project => $root, rule => 'agent-still', age => '1s', action => 'bridge-reminder' );

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Stopped', priority => 5, assignee => 'claude' );
$tira->record_move(author => 'claude',  project => $root, ref => $card->{ref}, column => 'implement' );

$now = '2026-08-23T02:00:00Z';

my @sent;
{
    local *Tira::_send_notification = sub {
        my ( undef, %args ) = @_;
        push @sent, $args{text};
        return 1;
    };

    # --- an alias is set: the message names both it and the real path ------

    local $ENV{TIRA_HOME} = 'evt-project';
    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 1, 'the stall is reported' );
    like( $sent[0], qr/\Qevt-project\E/, 'naming the TIRA_HOME alias' );
    like( $sent[0], qr/\Q$root\E/,       'and the real project path' );
    like( $sent[0], qr/the agent has stopped/, 'without losing the existing message' );
    unlike( $sent[0], qr/^Tira: the agent has stopped/,
        'the identity comes before the existing sentence, not after it' );
}

# --- no alias set: the real path alone still identifies the board ----------

{
    local *Tira::_send_notification = sub {
        my ( undef, %args ) = @_;
        push @sent, $args{text};
        return 1;
    };

    delete local $ENV{TIRA_HOME};
    $now = '2026-08-23T02:16:00Z';    # past the throttle window, same ongoing stall
    $tira->police_pass( project => $root, store => $store, world => {} );
    is( scalar @sent, 2, 'a repeat reminder past the throttle window' );
    like( $sent[-1], qr/\Q$root\E/, 'still names the real project path with no alias set' );
}

done_testing;

__END__

=head1 NAME

343-which-board-stopped.t - agent-still names which project it is about

=head1 DESCRIPTION

agent-still speaks directly to Telegram, bypassing the bridge on purpose -
which also meant it never said which of several projects on the same machine
it was about. This proves the notification now names the TIRA_HOME alias
(when set) and the real project path, on both a fresh stall and a repeat
reminder, while leaving the message's own detail sentence untouched.

=cut
