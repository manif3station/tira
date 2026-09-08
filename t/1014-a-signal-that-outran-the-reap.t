#!/usr/bin/env perl
# TKT-1014. job.stop signals a monitor's whole process group at once - the
# feeder and its command together, not the command first and the feeder
# second. The feeder installed no SIGTERM handler, so the group signal's
# default disposition killed it outright, mid-read, before it ever reached
# its own "waitpid" - so its child died as an unreaped sibling rather than
# a child its parent collected, and became a zombie nothing else was
# positioned to reap. Reproduced live in a container: both the feeder and
# its child showed <defunct> immediately after a stop.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI::Job;
use Tira::CLI::Job::Monitor;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Reaped', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RPS', epic_prefix => 'RPE', ticket_prefix => 'RPT',
);
$tira->job_add( project => $root, author => 'claude', schedule => 'monitor', command => 'sleep 47' );
my ($job) = @{ $tira->job_list( project => $root ) };

# The real feeder script, not a stand-in - the fix lives inside run_feeder
# itself, and a stub that skips the SIGTERM handling under test would make
# every assertion below vacuously green.
my $feeder = File::Spec->rel2abs( File::Spec->catfile( 'skills', 'job', 'cli', 'feeder' ) );
ok( -f $feeder, 'the real feeder script exists at the path _spawn_monitor uses' );

sub alive {
    my (@pids) = @_;
    return () if !@pids;
    my $listing = `ps -o pid=,stat= -p @{[ join ',', @pids ]} 2>/dev/null` // '';
    my @up;
    for my $line ( split /\n/, $listing ) {
        next if $line !~ /\A\s*(\d+)\s+(\S+)/;
        next if $2 =~ /\AZ/;
        push @up, $1;
    }
    return @up;
}

sub zombies {
    my (@pids) = @_;
    return () if !@pids;
    my $listing = `ps -o pid=,stat= -p @{[ join ',', @pids ]} 2>/dev/null` // '';
    my @dead;
    for my $line ( split /\n/, $listing ) {
        push @dead, $1 if $line =~ /\A\s*(\d+)\s+Z/;
    }
    return @dead;
}

sub tree_of {
    my ($pid) = @_;
    my $listing = `ps -eo pid=,ppid= 2>/dev/null` // '';
    my %children;
    for my $line ( split /\n/, $listing ) {
        next if $line !~ /\A\s*(\d+)\s+(\d+)/;
        push @{ $children{$2} }, $1;
    }
    my @tree  = ($pid);
    my @queue = ($pid);
    my %seen  = ( $pid => 1 );
    while ( my $next = shift @queue ) {
        for my $child ( @{ $children{$next} || [] } ) {
            next if $seen{$child}++;
            push @tree,  $child;
            push @queue, $child;
        }
    }
    return @tree;
}

my $pid = eval {
    local $ENV{TIRA_HOME}   = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    Tira::CLI::Job::_spawn_monitor( $^X, $feeder, $job->{id}, 0 );
};
ok( $pid && $pid =~ /\A[1-9][0-9]*\z/, 'the real feeder was spawned and its pid returned' )
  or done_testing, exit;

sleep 1;
my @tree = tree_of($pid);
cmp_ok( scalar @tree, '>=', 2, 'the monitor is more than one process - the feeder and sleep 47' );

my $signalled = eval { Tira::CLI::Job::_signal_monitor($pid) };
is( $signalled, 'group', 'the whole group was signalled' );

sleep 1;

# This test process is the feeder's own real parent (it called open3
# directly, via _spawn_monitor) - unlike production, where job.start exits
# immediately after spawning and orphans the feeder to init within
# moments, well before it ever needs to be signalled. Reaping the
# top-level pid here plays init's part, so what is being asserted next is
# specifically about the CHILD the feeder itself owns, which is what
# TKT-1014 is about - a real init reaps the feeder's own exit promptly;
# whether the feeder reaped ITS OWN child before that is what was broken.
waitpid $pid, 0;

is( scalar( alive(@tree) ), 0, 'nothing in the tree is still running' );
is_deeply( [ zombies(@tree) ], [],
    'and nothing in the tree was left as an unreaped zombie - the feeder caught TERM and reaped its own child before exiting' )
  or diag( 'zombies: ' . join( ', ', zombies(@tree) ) );

# Best-effort cleanup if the assertion above failed and something is still around.
kill 'KILL', $_ for alive(@tree);
waitpid $_, 0 for @tree;

# --- THE HANDLER ITSELF, WHERE COVERAGE CAN SEE IT -----------------------------
#
# The reproduction above execs the real feeder script through open3, which is
# right for proving the fix behaviourally - it is what job.start actually
# does - but invisible to Devel::Cover: code reached only past an exec runs in
# a process the harness never instrumented, so the SIGTERM handler counted as
# uncovered even though every assertion above depends on it having run.
#
# fork() does not exec. The child is the same compiled, already-instrumented
# Perl this file is running as, so calling run_feeder directly in a forked
# child exercises the handler somewhere coverage is counting.

SKIP: {
    skip 'fork() unavailable', 3 if $^O eq 'MSWin32';

    require Tira::CLI::Job::Feeder;

    my $child = fork();
    die "fork: $!" if !defined $child;

    if ( $child == 0 ) {
        # CHILD: the real verb, in-process - no exec of anything but the
        # command itself (a plain `sleep`, which owns no Perl for coverage to
        # miss).
        close STDOUT;
        close STDERR;
        eval {
            Tira::CLI::Job::Feeder::run_feeder(
                $tira,
                { id => $job->{id}, project => $root, command => 'sleep 30' },
                1, 50,
            );
        };
        exit 0;
    }

    # PARENT: give the child time to reach open3 and start blocking inside
    # feed_from_handle before signalling it - too early and TERM would arrive
    # before $current_pid is set, which the handler's own `if defined` guards
    # but is not the path this test means to exercise.
    sleep 1;

    my ($grandchild) = grep { $_ != $child } tree_of($child);
    ok( $grandchild, 'the forked feeder has already started its own child - the command it is running' )
      or diag("tree of $child: @{[ tree_of($child) ]}");

    kill 'TERM', $child;
    waitpid $child, 0;

    is( $?, 0,
        'the forked feeder exited cleanly from its own TERM handler, run in this '
          . 'process rather than an exec\'d one - not killed by the default '
          . 'disposition mid-read' );

    sleep 1;
    is( scalar zombies($grandchild), 0,
        'and the command it owned left no zombie behind - the handler reaped it '
          . 'before exiting' )
      if $grandchild;

    kill 'KILL', $grandchild if $grandchild && alive($grandchild);
    waitpid $grandchild, 0   if $grandchild;
}

done_testing();

__END__

=head1 NAME

1014-a-signal-that-outran-the-reap.t - a stopped monitor leaves no zombie

=head1 DESCRIPTION

TKT-1014. C<job.stop> signals a monitor's whole process group at once, so
the feeder and its command receive C<TERM> together rather than
child-then-parent. Without a handler, the feeder's own default C<TERM>
disposition killed it before it reached its own C<waitpid>, so its child
died unreaped. The feeder now traps C<TERM>, reaps whichever child it is
currently running, and exits - reproduced and fixed after confirming the
zombie live in a container.

=cut
