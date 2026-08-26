#!/usr/bin/env perl
# TKT-565. A live dashboard does not pick up a new Tira on its own: the
# shipped board runs under Starman with a worker pool, and the in-process
# self-restart is gated on being the process that bound the port, which is
# never true in a worker. So the board shows a banner and waits for a human.
#
# Police can fix it, because it is not a worker and owns no socket. What it
# sends is HUP, not a kill: Tira deliberately serves a .psgi FILE PATH
# rather than an in-memory coderef, so Starman's HUP re-forks workers that
# read the modules from disk again and come up on the installed version.
# Proved before building on it - a two-worker Starman on a .psgi reading a
# version from a file served "one", the file changed, the master got HUP,
# and it served "two" from fresh worker pids. Starman's own docs agree.
#
# Michael, CMT-001 on this card, is why this is HUP and not kill: "After
# master process killed. The children still survived. Have you think of
# this side effect too?" - and why the master is found by port rather than
# by a pidfile: "Could that be more reliable to find the pid on demand by
# checking which is the master process by the port number?"
#
# Signals and the port lookup are injectable, so nothing here signals a
# real process.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'police' );

sub attempt {
    my (%args) = @_;
    my @hupped;
    my $result = Tira::CLI::_dashboard_hup_if_stale(
        $store,
        port      => exists $args{port} ? $args{port} : 7800,
        on_disk   => exists $args{on_disk} ? $args{on_disk} : '4.35',
        listening => $args{listening} // sub { 999 },

        # A board-looking command line by default, so these cases exercise
        # the version logic rather than TKT-566's identity check, which has
        # its own cases below.
        identify => $args{identify} // sub { 'starman master' },
        hup      => $args{hup} // sub { push @hupped, $_[0]; 1 },
    );
    return ( $result, \@hupped );
}

# --- a board on old code is HUPed, once ------------------------------------

{
    my ( $stale, $hupped ) = attempt();
    ok( $stale->{hupped}, 'a board serving older code than is installed is HUPed' );
    is_deeply( $hupped, [999], 'the process holding the board port is the one signalled' );
}

{
    # The same version again must not signal again: a restart on a timer is
    # the exact loop this whole mechanism exists to avoid.
    my ( $again, $hupped ) = attempt();
    ok( !$again->{hupped}, 'the same installed version does not signal a second time' );
    is( $again->{refused}, 'already-current', 'saying it has already been done' );
    is_deeply( $hupped, [], 'and nothing is signalled' );
}

{
    my ( $moved, $hupped ) = attempt( on_disk => '4.36' );
    ok( $moved->{hupped}, 'but a further release does signal again' );
    is_deeply( $hupped, [999], 'on the board holding the port' );
}

# --- every uncertainty refuses, and names itself ---------------------------

{
    my ( $none, $hupped ) = attempt( on_disk => '4.37', listening => sub { undef } );
    ok( !$none->{hupped}, 'no board holding the port means nothing to signal' );
    is( $none->{refused}, 'no-board', 'saying so rather than guessing at a pid' );
    is_deeply( $hupped, [], 'and nothing is signalled' );
}

{
    my ( $unknown, $hupped ) = attempt( on_disk => undef );
    ok( !$unknown->{hupped}, 'an unreadable installed version is not acted on' );
    is( $unknown->{refused}, 'unknown-version', 'since acting on unknown is how a loop starts' );
    is_deeply( $hupped, [], 'and nothing is signalled' );
}

{
    my ( $portless, $hupped ) = attempt( on_disk => '4.38', port => undef );
    ok( !$portless->{hupped}, 'a board with no known port is not looked for' );
    is( $portless->{refused}, 'no-port', 'saying so' );
    is_deeply( $hupped, [], 'and nothing is signalled' );
}

# --- TKT-566: the process on the port must be proved to be the board -------
#
# Whoever holds the port is not necessarily the board. SIGHUP's default
# disposition is Term, so signalling a stranger that installs no handler
# kills it - proved with a plain `perl -e 'sleep 300'`, which died on HUP.
# The board port is a stable configured number, so any time the board is
# down and something else takes it, this is a real program being killed.

{
    my @hupped;
    my $stranger = Tira::CLI::_dashboard_hup_if_stale(
        $store, port => 7801, on_disk => '4.40',
        listening => sub { 4242 },
        identify  => sub { 'nginx: worker process' },
        hup       => sub { push @hupped, $_[0]; 1 },
    );
    ok( !$stranger->{hupped}, 'a process on the port that is not the board is not signalled' );
    is( $stranger->{refused}, 'not-a-board', 'saying it could not be confirmed as the board' );
    is_deeply( \@hupped, [], 'and nothing is signalled, so the stranger lives' );
}

{
    my @hupped;
    my $unreadable = Tira::CLI::_dashboard_hup_if_stale(
        $store, port => 7802, on_disk => '4.41',
        listening => sub { 4243 },
        identify  => sub { undef },
        hup       => sub { push @hupped, $_[0]; 1 },
    );
    ok( !$unreadable->{hupped}, 'a process whose command line cannot be read is not signalled either' );
    is( $unreadable->{refused}, 'not-a-board', 'because unconfirmed is not the same as confirmed' );
    is_deeply( \@hupped, [], 'and nothing is signalled' );
}

{
    my @hupped;
    my $board = Tira::CLI::_dashboard_hup_if_stale(
        $store, port => 7803, on_disk => '4.42',
        listening => sub { 4244 },
        identify  => sub { 'starman master' },
        hup       => sub { push @hupped, $_[0]; 1 },
    );
    ok( $board->{hupped}, 'a genuine dashboard master is still signalled' );
    # A live master's command line really does read just "starman master":
    # Starman rewrites $0, so it names neither dashboard.psgi nor the command
    # that started it. An earlier version of this check looked for
    # dashboard.psgi and would have refused every real board while looking
    # perfectly safe.
    is_deeply( \@hupped, [4244], 'on its own pid' );
}

# --- the port lookup itself, against a socket this test really holds -------

{
    require IO::Socket::INET;
    my $held = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' );
 SKIP: {
        skip 'could not bind a probe port', 2 if !$held;
        skip 'the port lookup reads /proc, which this platform does not have', 2 if !-d '/proc';
        my $port = $held->sockport;
        is( Tira::CLI::_listening_pid($port), $$,
            'the port lookup finds the process genuinely holding a port' );
        $held->close;
        is( Tira::CLI::_listening_pid($port), undef,
            'and finds nothing once it has been let go of' );
    }
}

# --- the real defaults, exercised without signalling anything --------------
#
# Everything above injects the lookup, the identity check and the signal, so
# none of the code that actually runs in production had ever been executed.
# These two cases run the genuine defaults end to end and still signal
# nothing, because both stop at a refusal: the first finds no board on a
# port nothing holds, and the second finds this very test process on a port
# it really is holding - and a perl test is not a Starman.

{
    my $free = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' );
 SKIP: {
        skip 'could not bind a probe port', 2 if !$free;
        skip 'the defaults read /proc, which this platform does not have', 2 if !-d '/proc';
        my $port = $free->sockport;
        $free->close;
        my $nobody = Tira::CLI::_dashboard_hup_if_stale(
            File::Spec->catdir( $tmp, 'defaults' ), port => $port, on_disk => '9.99' );
        ok( !$nobody->{hupped}, 'the real lookup on a port nothing holds signals nothing' );
        is( $nobody->{refused}, 'no-board', 'refusing through the genuine default' );
    }
}

{
    my $mine = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' );
 SKIP: {
        skip 'could not bind a probe port', 2 if !$mine;
        skip 'the defaults read /proc, which this platform does not have', 2 if !-d '/proc';
        my $port = $mine->sockport;
        my $self = Tira::CLI::_dashboard_hup_if_stale(
            File::Spec->catdir( $tmp, 'defaults' ), port => $port, on_disk => '9.98' );
        ok( !$self->{hupped}, 'the real identity check refuses this test process' );
        is( $self->{refused}, 'not-a-board',
            'so a genuine non-Starman on the port is never signalled - which is the whole point' );
        $mine->close;
    }
}

# And the command-line read those defaults rely on, against a process whose
# answer is known: this one.
SKIP: {
    skip 'reading a command line needs /proc', 3 if !-d '/proc';
    my $me = Tira::CLI::_command_of_pid($$);
    ok( defined $me && length $me, 'a running process has a command line to read' );
    like( $me, qr/perl|\.t\b/i,
        'and it is this process\'s real command line, not any old text' );
    is( Tira::CLI::_command_of_pid('not-a-pid'), undef, 'and something that is not a pid reads as undef' );
}

# The real signalling closure, which every case above injects around. Run
# here against this process, with HUP ignored for the duration - so the
# genuine `kill 'HUP', $pid` executes and lands somewhere harmless.
SKIP: {
    skip 'signalling needs /proc for the lookup', 2 if !-d '/proc';
    my $mine = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp' );
    skip 'could not bind a probe port', 2 if !$mine;
    local $SIG{HUP} = 'IGNORE';
    my $sent = Tira::CLI::_dashboard_hup_if_stale(
        File::Spec->catdir( $tmp, 'real-signal' ),
        port      => $mine->sockport,
        on_disk   => '9.97',
        identify  => sub { 'starman master' },
    );
    ok( $sent->{hupped}, 'the real signalling path runs end to end' );
    is( $sent->{pid}, $$, 'and signals the process the lookup actually found' );
    $mine->close;
}

done_testing;

__END__

=head1 NAME

403-a-board-nobody-restarted.t - police HUPs a dashboard left on old code

=head1 DESCRIPTION

TKT-565: police finds the process holding the board's port and sends it
HUP when the installed version has moved, so a live dashboard comes up on
the new code without anyone restarting it and without dropping a request.
It signals once per version, because signalling every pass is the loop
this mechanism exists to avoid, and every uncertainty - no board on the
port, an unreadable installed version, no known port - refuses and names
itself instead. The signal and the lookup are injectable, so the suite
never signals a real process.

=cut
