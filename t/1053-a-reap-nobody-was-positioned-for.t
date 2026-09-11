#!/usr/bin/env perl
# TKT-1053. job.stop signals a monitor's whole process group (TKT-920/927),
# and the feeder now reaps its own child before exiting (TKT-1014) - but
# nothing ever reaped the FEEDER ITSELF once IT died. That was invisible in
# t/1014's own reproduction because that test is the feeder's real parent
# and its own comment says so: "unlike production, where job.start exits
# immediately after spawning and orphans the feeder to init within moments,
# well before it ever needs to be signalled" - true for a one-shot
# `d2 tira.job.start`, false for the dashboard's own Starman workers, which
# spawn a monitor from inside a request handler that keeps running to
# answer many more requests afterward. That worker IS the feeder's real
# parent, for as long as it lives - and nothing ever waited on it.
#
# Reproduced live in a developer-dashboard:latest container: a process that
# stays alive after spawning (playing the worker's part, not init's) shows
# the feeder as STAT=Z <defunct> after job.stop, indefinitely.
#
# THE FIX is a SIGCHLD handler installed once, at each Starman worker's own
# startup (dashboard.psgi), that reaps whichever pids
# Tira::CLI::Job::Monitor::_spawn_monitor itself recorded - NOT a blanket
# waitpid(-1, ...), which a first version of this fix used and Codex caught
# in review before it shipped: the same worker also runs command-mode jobs
# through Tira::CLI::Police::Jobs::run_due_job, which spawns its own child
# and reaps it with an explicit waitpid to read its real exit status. A
# handler that reaps ANY child can win that race and hand run_due_job
# ECHILD instead, which read back as every successful command reporting
# exit 255. _reap_known_monitors only ever waits on pids _spawn_monitor
# itself put in its own registry, so a caller with its own explicit
# waitpid is never raced.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use POSIX ();
use Test::More;

use lib 'lib', 't/lib';
use Tira;
use Tira::CLI::Job;
use Tira::CLI::Job::Monitor;
use Suite ();

# The fix itself, read from dashboard.psgi rather than duplicated - so a
# later edit to the real handler is what this test exercises, not a copy
# that could drift from it.
{
    local $/;
    open my $fh, '<', 'dashboard.psgi' or die "dashboard.psgi: $!";
    my $source = <$fh>;
    like( $source, qr/\$SIG\{CHLD\}\s*=/,
        'dashboard.psgi installs a SIGCHLD handler at worker startup' );
    like( $source, qr/_reap_known_monitors/,
        'and it reaps through the registry-scoped reaper, not a blanket '
          . 'waitpid(-1, ...) that would race every other caller\'s own '
          . 'explicit reap in the same worker' );
}

# THE REGISTRATION RACE, caught in review before this shipped: open3
# returning and $SPAWNED{$pid}=1 running are not the same instant, so a
# feeder that dies in that gap sends its SIGCHLD before the registry even
# knows its pid - the handler's own reap pass finds nothing, and no SECOND
# signal is coming to give it another chance once the pid IS added. The
# fix is _spawn_monitor calling _reap_known_monitors() itself, immediately
# after registering - a child already dead by then is still a zombie
# waiting to be collected, so this second call catches precisely what an
# earlier, unlucky SIGCHLD could not. Read from source rather than timed:
# the actual window is sub-instruction and not reliably reproducible by
# racing a real fork from outside.
{
    my $source = Suite::cli_source('Monitor.pm');
    my ($spawn_body) = $source =~ /sub _spawn_monitor \{(.*?)\n\}/s;
    ok( defined $spawn_body, 'sanity: _spawn_monitor was found, to read its own body' );
    like( $spawn_body // '', qr/\$SPAWNED\{\$pid\}\s*=\s*1.*_reap_known_monitors\(\)/s,
        '_spawn_monitor reaps immediately after registering, in that order - '
          . 'closing the window where a child that died before registration '
          . 'would otherwise wait for a signal nothing sends twice' );
}

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Reaped', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RQS', epic_prefix => 'RQE', ticket_prefix => 'RQT',
);
$tira->job_add( project => $root, author => 'claude', schedule => 'monitor', command => 'sleep 47' );
my ($job) = @{ $tira->job_list( project => $root ) };

my $feeder = File::Spec->rel2abs( File::Spec->catfile( 'skills', 'job', 'cli', 'feeder' ) );
ok( -f $feeder, 'the real feeder script exists at the path _spawn_monitor uses' );

sub stat_of {
    my ($pid) = @_;
    my $listing = `ps -o stat= -p $pid 2>/dev/null` // '';
    $listing =~ s/\s+\z//;
    return $listing;
}

# THE HANDLER ITSELF, installed here exactly as dashboard.psgi installs it -
# a worker's own startup, once, before it ever spawns anything. This test
# process now plays the worker's part for the rest of the file: it spawns,
# it signals, and unlike t/1014 it never calls waitpid itself - the handler
# is the only thing standing between the child that is about to die and a
# zombie nothing else is positioned to reap.
$SIG{CHLD} = sub {
    local ( $!, $? );
    Tira::CLI::Job::Monitor::_reap_known_monitors();
};

my $pid = eval {
    local $ENV{TIRA_HOME}   = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    Tira::CLI::Job::_spawn_monitor( $^X, $feeder, $job->{id}, 0 );
};
ok( $pid && $pid =~ /\A[1-9][0-9]*\z/, 'the real feeder was spawned and its pid returned' )
  or done_testing, exit;

sleep 1;
ok( stat_of($pid) !~ /\AZ/, 'freshly spawned, the feeder is not a zombie' );

my $signalled = eval { Tira::CLI::Job::_signal_monitor($pid) };
is( $signalled, 'group', 'the whole group was signalled, exactly as job.stop does it' );

# GIVEN TIME TO DIE AND FOR THE HANDLER TO FIRE - no waitpid of our own here,
# which is the one thing this test must not do: that would be playing init's
# part again, the exact assumption that let this ship unnoticed.
for ( 1 .. 20 ) {
    last if stat_of($pid) eq '';
    sleep 0.1;
}

is( stat_of($pid), '',
    'and the feeder is gone from the process table entirely - reaped by the '
      . 'SIGCHLD handler, not left as a zombie nothing was positioned to '
      . 'reap, and not left for this test to clean up after itself' );

# --- AND A CALLER'S OWN EXPLICIT REAP IS NEVER RACED ------------------------
#
# The exact regression Codex caught: with the SIGCHLD handler installed
# (still armed from above), a command spawned and reaped OUTSIDE the
# monitor registry - exactly what run_due_job does - must still get its
# real exit status, not ECHILD from a handler that already stole the reap.
{
    require IPC::Open3;
    require Symbol;
    my ( $in, $out, $err ) = ( undef, Symbol::gensym(), Symbol::gensym() );
    my $unrelated_pid = IPC::Open3::open3( $in, $out, $err, 'true' );
    close $in if $in;
    waitpid $unrelated_pid, 0;
    is( $? >> 8, 0,
        'a child NOT in the monitor registry is untouched by the SIGCHLD '
          . 'handler - its own explicit waitpid still reads a real exit '
          . 'status, not ECHILD from a reaper that got there first' );
}

done_testing();

__END__

=head1 NAME

t/1053-a-reap-nobody-was-positioned-for.t - a stopped monitor's own process
is reaped, not left defunct

=head1 DESCRIPTION

TKT-920/927 made C<job.stop> signal a monitor's whole process group at once,
and TKT-1014 made the feeder reap its own child before exiting on that
signal. Both fixed what dies; neither addressed what reaps the FEEDER
ITSELF once it dies - because C<job.start> is not always the one-shot CLI
invocation that exits within moments and lets C<init> adopt whatever it
spawned. The dashboard's own Starman workers spawn a monitor from inside a
request handler that keeps running, so that worker is the monitor's real
parent for as long as it lives, and nothing had ever waited on it.

Reproduced live in a developer-dashboard:latest container: a process that
stays alive after spawning shows the feeder as C<STAT=Z> C<E<lt>defunctE<gt>>
after C<job.stop>, indefinitely.

The fix is a C<SIGCHLD> handler installed once, at each worker's own
startup (F<dashboard.psgi>), that reaps only the pids
C<Tira::CLI::Job::Monitor::_spawn_monitor> itself recorded in its own
registry - never a blanket C<waitpid(-1, ...)>, which would also reap a
command-mode job's own child mid-flight and hand
C<Tira::CLI::Police::Jobs::run_due_job>'s own explicit C<waitpid> C<ECHILD>
instead of the real exit status it is waiting for.

=head1 SEE ALSO

L<t/1014-a-signal-that-outran-the-reap.t>

=cut
