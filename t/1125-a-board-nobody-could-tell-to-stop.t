#!/usr/bin/env perl
# TKT-1125, Michael's own live ask: "agent needs to have more control of the
# tira.dashboard... The agent is having hard time to restart it, if an
# agent want to stop it, there is not option for that and neither
# restart... and when tira.dashboard start and stop, there are also
# default --with-* options goes with... these have to be done with the
# command together."
#
# A served board writes a small state file (port, the command it was
# invoked as, and its own remembered argv - the same @Tira::CLI::RESTART_ARGV
# the version-upgrade self-restart already replays) to its police store the
# moment it starts serving, and clears it the moment it stops. --stop reads
# it, finds the master by port (Michael's own TKT-565 precedent: by port,
# not a pidfile), confirms it is genuinely a Starman, and sends it the same
# signal Ctrl-C already does (INT) - the ALREADY-SHIPPED "the pass dies with
# the board" cleanup in Tira::CLI::run then stops police/the policy bridge
# itself, in the original process, once serve() returns. --restart does the
# same stop, then execs into the remembered script and argv - the identical
# mechanism _restart_if_updated already uses for the version-upgrade case,
# just triggered on demand.
#
# Signals, the port lookup, and the exec are all injectable, so nothing
# here signals or execs a real process.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Serve;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'police' );

# --- the state file itself: written, read back, cleared ---------------------

ok( !Tira::CLI::Serve::_read_dashboard_state($store),
    'no state exists before anything has been written' );

Tira::CLI::Serve::_write_dashboard_state(
    store => $store, pid => 4242, port => 7800,
    command => 'dashboard.ticket', argv => [ '-o', 'browser', '--with-police' ],
    police_pid => 4243, policy_bridge_pid => 4244 );

my $state = Tira::CLI::Serve::_read_dashboard_state($store);
is( $state->{pid}, 4242, 'the written pid comes back' );
is( $state->{port}, 7800, 'the written port comes back' );
is( $state->{command}, 'dashboard.ticket', 'the written command comes back' );
is_deeply( $state->{argv}, [ '-o', 'browser', '--with-police' ],
    'the written argv comes back exactly, including --with-police' );
is( $state->{police_pid}, 4243, 'the written police companion pid comes back' );
is( $state->{policy_bridge_pid}, 4244, 'the written policy-bridge companion pid comes back' );

Tira::CLI::Serve::_clear_dashboard_state($store);
ok( !Tira::CLI::Serve::_read_dashboard_state($store), 'clearing removes it' );

# --- _stop_dashboard ---------------------------------------------------------

sub write_state {
    Tira::CLI::Serve::_write_dashboard_state(
        store => $store, pid => $$, port => 7800,
        command => 'dashboard', argv => [ '-o', 'browser', '--with-police', '--with-policy-bridge' ] );
}

{
    my $result = Tira::CLI::Serve::_stop_dashboard( store => $store );
    is( $result->{stopped}, 0, 'stopping with no board running at all is refused' );
    is( $result->{refused}, 'not-running', 'and says why' );
}

{
    write_state();
    my @signalled;
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store     => $store,
        listening => sub { undef },
        confirm   => sub { 1 },
        kill      => sub { push @signalled, $_[0]; 1 },
    );
    is( $result->{stopped}, 0, 'nothing listening on the remembered port is refused' );
    is( $result->{refused}, 'no-board', 'and says why' );
    is_deeply( \@signalled, [], 'and nothing was signalled' );
    ok( Tira::CLI::Serve::_read_dashboard_state($store),
        'the state survives a refusal - there was nothing to clear' );
}

{
    write_state();
    my @signalled;
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store     => $store,
        listening => sub { 4242 },
        confirm   => sub { 0 },    # a stranger holding the port, not a Starman
        kill      => sub { push @signalled, $_[0]; 1 },
    );
    is( $result->{stopped}, 0, 'a process on the port that is not a Starman is refused' );
    is( $result->{refused}, 'not-a-board', 'and says why' );
    is_deeply( \@signalled, [], 'and nothing was signalled - a stranger with no HUP/INT handler dies outright' );
}

{
    write_state();
    my @signalled;
    my @companions_killed;
    my $waited = 0;
    my $listening_calls = 0;
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store          => $store,
        listening      => sub { $listening_calls++; $listening_calls < 3 ? 4242 : undef },
        confirm        => sub { 1 },
        kill           => sub { push @signalled, $_[0]; 1 },
        kill_companion => sub { push @companions_killed, $_[0]; 1 },
        sleep          => sub { $waited++ },
        wait_seconds   => 5,
    );
    is( $result->{stopped}, 1, 'a genuine Starman on the remembered port is stopped' );
    is_deeply( \@signalled, [4242], 'signalled exactly once, the master pid, not the port' );
    ok( $waited > 0, 'it waited for the port to actually be released before calling it stopped' );
    ok( !Tira::CLI::Serve::_read_dashboard_state($store),
        'the state is cleared once the master is confirmed gone' );
    is_deeply( \@companions_killed, [],
        'no companion pid was killed - write_state recorded none, so there was nothing to kill' );
}

# TKT-1125 round 2, found live in a developer-dashboard:latest container:
# Starman's own INT handling exits before Tira::CLI::run's post-return "pass
# dies with the board" cleanup ever runs, so a --with-police/
# --with-policy-bridge companion was left running with the board fully gone
# and --stop still reporting success. Killing the master alone, or signalling
# its process group (-pid), both failed live - the master is not reliably its
# own process group leader. The state file must remember each companion's own
# pid, and _stop_dashboard must kill them itself.
{
    Tira::CLI::Serve::_write_dashboard_state(
        store => $store, pid => $$, port => 7800, command => 'dashboard',
        argv => [ '-o', 'browser', '--with-police', '--with-policy-bridge' ],
        police_pid => 5001, policy_bridge_pid => 5002 );
    my @companions_killed;
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store          => $store,
        listening      => sub { undef },
        confirm        => sub { 1 },
        kill           => sub { 1 },
        kill_companion => sub { push @companions_killed, $_[0]; 1 },
    );
    # "no-board" (nothing on the port any more) does not skip companion
    # cleanup - a board that already died some other way can still have
    # left its companions running, and those still need killing.
    is( $result->{stopped}, 1, 'stopped, with both companion pids on record' );
    is_deeply( [ sort { $a <=> $b } @companions_killed ], [ 5001, 5002 ],
        'both the police and the policy-bridge companion pids were killed directly, not left to the master to clean up' );
}

# --- the real, non-injected defaults - every closure above is a test double,
# so none of it proves the default _listening_pid/_confirm_starman/kill('INT')/
# kill('TERM') paths actually work. Exercised here for real: a genuinely free
# port, the test's own pid (definitely not a Starman), and two forked children
# that only die if truly signalled.

sub spawn_sleeper {
    my $pid = fork();
    die "Cannot fork: $!\n" if !defined $pid;
    if ( $pid == 0 ) {
        # A plain sleeping child with no signal handler of its own - the
        # default disposition for INT/TERM is termination, same as any real
        # police/policy-bridge companion with nothing trapping the signal.
        select( undef, undef, undef, 30 );
        exit 0;
    }
    return $pid;
}

{
    write_state();    # a port nothing in this container is listening on
    my $result = Tira::CLI::Serve::_stop_dashboard( store => $store );
    is( $result->{stopped}, 0, 'the real _listening_pid finds nothing on a genuinely free port' );
    is( $result->{refused}, 'no-board', 'and refuses the same way the injected-listening tests already proved' );
}

{
    write_state();
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store     => $store,
        listening => sub {$$},    # this test process's own pid - real, harmless to identify
    );
    is( $result->{stopped}, 0, 'the real _confirm_starman refuses a pid that genuinely is not a Starman' );
    is( $result->{refused}, 'not-a-board', 'this process is "perl ... .t", not starman, and _command_of_pid says so for real' );
}

{
    write_state();
    my $master     = spawn_sleeper();
    my $police     = spawn_sleeper();
    my $bridge     = spawn_sleeper();
    Tira::CLI::Serve::_write_dashboard_state(
        store => $store, pid => $$, port => 7800, command => 'dashboard', argv => [ '-o', 'browser' ],
        police_pid => $police, policy_bridge_pid => $bridge );
    my $checked = 0;
    my $result  = Tira::CLI::Serve::_stop_dashboard(
        store        => $store,
        listening    => sub { $checked++; $checked < 2 ? $master : undef },
        confirm      => sub {1},
        wait_seconds => 1,
    );
    is( $result->{stopped}, 1, 'stopped with the real kill(INT) and kill(TERM) - no kill/kill_companion override' );
    waitpid( $_, 0 ) for $master, $police, $bridge;
    ok( !kill( 0, $master ), 'the real INT actually reached and ended the master' );
    ok( !kill( 0, $police ), 'the real TERM actually reached and ended the police companion' );
    ok( !kill( 0, $bridge ), 'the real TERM actually reached and ended the policy-bridge companion' );
}

# --- _restart_dashboard -------------------------------------------------------

{
    my $result = Tira::CLI::Serve::_restart_dashboard( store => $store );
    is( $result->{restarted}, 0, 'restarting with nothing running is refused' );
    is( $result->{refused}, 'not-running', 'and says why' );
}

{
    write_state();
    my @execced;
    my $result = Tira::CLI::Serve::_restart_dashboard(
        store      => $store,
        listening  => sub { undef },    # already stopped somehow
        confirm    => sub { 1 },
        kill       => sub { 1 },
        entrypoint => '/opt/tira/cli/dashboard',
        restarter  => sub { push @execced, [@_]; return 0 },    # exec "failed"
    );
    is( scalar @execced, 1, 'restart execs exactly once, after the stop step' );
    is_deeply(
        $execced[0],
        [ '/opt/tira/cli/dashboard', '-o', 'browser', '--with-police', '--with-policy-bridge' ],
        'with the remembered script and the exact remembered argv - including both --with- flags'
    );
    is( $result->{restarted}, 0, 'a fake exec that returns is reported as a failed restart, not a silent success' );
}

{
    my @stopped_first;
    write_state();
    my $result = Tira::CLI::Serve::_restart_dashboard(
        store      => $store,
        listening  => sub { 4242 },
        confirm    => sub { 1 },
        kill       => sub { push @stopped_first, $_[0]; 1 },
        entrypoint => '/opt/tira/cli/dashboard',
        restarter  => sub { 1 },    # never actually execs in this test
    );
    is_deeply( \@stopped_first, [4242], 'the OLD master is stopped before the new one is ever execced into' );
}

# --- CODEX REVIEW, round 2: three real gaps found in a fresh adversarial
# pass over the shipped code, none reachable by anything above.

{
    # A corrupted/hand-edited state file with police_pid=0 or a negative
    # value must never be signalled - kill(2) reads 0/negative as "this
    # process's own group", not "nothing to kill".
    Tira::CLI::Serve::_write_dashboard_state(
        store => $store, pid => $$, port => 7800, command => 'dashboard', argv => ['-o'],
        police_pid => 0, policy_bridge_pid => -5001 );
    my @companions_killed;
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store => $store, listening => sub {undef}, kill_companion => sub { push @companions_killed, $_[0]; 1 } );
    is( $result->{stopped}, 0, 'a state file with only 0/negative companion pids has nothing safe to act on' );
    is( $result->{refused}, 'no-board', 'and refuses rather than signalling pid 0 or a process group' );
    is_deeply( \@companions_killed, [], 'neither the zero nor the negative pid was ever passed to kill' );
}

{
    # The poll loop exhausting its budget is not proof the master died -
    # claiming "stopped" and clearing the restart record for a board still
    # answering on its port would be worse than refusing.
    write_state();
    my $result = Tira::CLI::Serve::_stop_dashboard(
        store => $store, listening => sub {4242}, confirm => sub {1}, kill => sub {1},
        sleep => sub { }, wait_seconds => 1 );
    is( $result->{stopped}, 0, 'a master still answering after the whole poll budget is not claimed stopped' );
    is( $result->{refused}, 'still-running', 'and says why' );
    ok( Tira::CLI::Serve::_read_dashboard_state($store),
        'the state survives - there is still a board it describes' );
}

{
    # _restart_dashboard clears the state as part of a successful stop -
    # if the exec after that never actually replaces this process, the
    # remembered command/argv must not be lost for a later retry. But the
    # companions that same stop just killed must NOT come back with it -
    # CODEX REVIEW: restoring their old pids would let a later --stop
    # signal an already-dead, possibly since-reused pid.
    Tira::CLI::Serve::_write_dashboard_state(
        store => $store, pid => $$, port => 7800, command => 'dashboard',
        argv => [ '-o', 'browser', '--with-police', '--with-policy-bridge' ],
        police_pid => 6001, policy_bridge_pid => 6002 );
    my $result = Tira::CLI::Serve::_restart_dashboard(
        store => $store, listening => sub {undef}, confirm => sub {1}, kill => sub {1}, kill_companion => sub {1},
        entrypoint => '/opt/tira/cli/dashboard', restarter => sub {0} );    # exec "failed"
    is( $result->{restarted}, 0, 'the failed exec is still reported as a failed restart' );
    my $state = Tira::CLI::Serve::_read_dashboard_state($store);
    ok( $state, 'the state was NOT left cleared by the failed restart' );
    is_deeply( $state->{argv}, [ '-o', 'browser', '--with-police', '--with-policy-bridge' ],
        'a later retry would still find the exact argv this attempt could not exec into' );
    ok( !$state->{police_pid} && !$state->{policy_bridge_pid},
        'but not the companion pids the preceding stop already killed - those do not come back' );
}

# --- Tira::CLI->run's own --stop/--restart dispatch - the unit tests above
# exercise Serve.pm directly, none of them through the CLI layer that parses
# --stop/--restart, refuses combining them, resolves the project, and prints
# the result. Covered here with a real project and real state files, the
# same pattern t/1028 already uses for dashboard-level CLI tests.

my $cli_tmp  = tempdir( CLEANUP => 1 );
my $cli_root = File::Spec->catdir( $cli_tmp, 'stopcli' );
my $cli_tira = Tira->new;
$cli_tira->project_new(
    name => 'StopCLI', dir => $cli_root, members => ['claude'],
    columns => ['backlog, done'],
);
my $cli_store = File::Spec->catdir( $cli_tmp, 'store' );

sub run_captured {
    my (%args) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = $cli_root;
    Tira::CLI->run( tira => $cli_tira, %args );
    return ( $out, $err );
}

{
    my ( $out, $err ) = run_captured(
        command => 'dashboard', argv => [ '--stop', '--restart' ] );
    like( $err, qr/Use only one of --stop or --restart/, 'the CLI refuses --stop and --restart together' );
}

{
    my ( $so_out, $so_err ) = ( '', '' );
    open my $so, '>', \$so_out or die $!;
    open my $se, '>', \$so_err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = File::Spec->catdir( $cli_tmp, 'nowhere-near-a-project' );
    Tira::CLI->run( tira => $cli_tira, command => 'dashboard', argv => ['--stop'] );
    like( $so_err, qr/No Tira project found|Cannot resolve/,
        'the CLI reports the real discover_project failure when --stop cannot resolve a board at all' );
}

{
    my ( $out, $err ) = run_captured( command => 'dashboard', argv => ['--restart'] );
    like( $err, qr/Could not restart: not-running/,
        'the CLI reports --restart refused when there is no remembered state, through the real _restart_dashboard' );
}

{
    my ( $out, $err ) = run_captured(
        command => 'dashboard', argv => [ '--store', $cli_store, '--stop' ] );
    like( $err, qr/Nothing to stop.*not-running/,
        'and the same for --stop, through the real _stop_dashboard' );
}

{
    my $police = spawn_sleeper();
    Tira::CLI::Serve::_write_dashboard_state(
        store => $cli_store, pid => $$, port => 7801, command => 'dashboard',
        argv => [ '-o', 'browser', '--with-police' ], police_pid => $police );
    my ( $out, $err ) = run_captured(
        command => 'dashboard', argv => [ '--store', $cli_store, '--stop' ] );
    like( $out, qr/Stopped the board and its police\/policy-bridge companions\./,
        'a real --stop through the CLI layer stops a genuinely recorded companion and says so' );
    waitpid( $police, 0 );
    ok( !kill( 0, $police ), 'the companion the CLI --stop reported stopping is actually gone' );
}

# CODEX REVIEW, round 5: a state-file write that fails (an unwritable
# store, say) was silently ignored, so the board still served but --stop/
# --restart could never find it again - the same "still worth serving,
# said rather than swallowed" shape a failed police/policy-bridge spawn
# already gets, missing here.
{
    my $unwritable_store = File::Spec->catfile( $cli_tmp, 'a-plain-file-not-a-directory' );
    open my $fh, '>', $unwritable_store or die $!;
    close $fh;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    local $ENV{TIRA_HOME} = $cli_root;
    my @served;
    Tira::CLI->run(
        tira => $cli_tira, command => 'dashboard',
        argv => [ '-o', 'browser', '--store', $unwritable_store ],
        browser_server => sub { push @served, {@_}; return 1 },
    );
    is( scalar @served, 1, 'the board still serves despite the state write failing' );
    like( $err, qr/could not record dashboard state/,
        'and says so, rather than leaving --stop/--restart silently unable to find it later' );
}

done_testing();

__END__

=head1 NAME

1125-a-board-nobody-could-tell-to-stop.t - tira.dashboard --stop/--restart

=head1 DESCRIPTION

Before TKT-1125, C<tira.dashboard> had no C<--stop> or C<--restart>: the
only documented way to stop a served board was Ctrl-C on its own
foreground terminal, and there was no way at all to restart it with the
C<--with-police>/C<--with-policy-bridge> (and every other) flag it was
originally started with. A served board now writes its own port, command,
and remembered argv to a small state file in its police store; C<--stop>
finds the master by port (never a pidfile - Michael's own TKT-565
precedent), confirms it is genuinely a Starman, and signals it the same
way Ctrl-C already does; C<--restart> does the same stop, then execs into
the exact script and argv the board was originally started with, the
identical mechanism the version-upgrade self-restart already uses.

=cut
