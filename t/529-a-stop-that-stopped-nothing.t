#!/usr/bin/env perl
# job.stop signalled one process in a pipeline of four.
#
# TKT-920, EPC-014. Found because JOB-006 was running under two pids at once
# while the board recorded a third that was dead. I filed that as a recording
# fault. It is not: the recorded pid is correct at every start.
#
# REPRODUCED in a tira:latest container, running the wrapper from
# lib/Tira/CLI/Job.pm through open3 exactly as job.start does, then sending TERM
# to the pid open3 returned exactly as job.stop does:
#
#   no loop:    recorded 10  ->  10 sh, 11 sleep, 12 feeder
#               after TERM 10:   11 sleep, 12 feeder   ppid 1, still running
#   with loop:  recorded 31  ->  31 sh, 32 sh(loop), 33 feeder, 34 sleep
#               after TERM 31:   32, 33, 34            ppid 1, still running
#
# BOTH SHAPES LEAK. The command, the feeder and - when restart_every is set -
# the loop subshell are separate processes; TERM to the top shell orphans them.
# The engine then clears the record, so the board forgets a monitor that is
# still going, and job.start's duplicate guard asks that emptied record and lets
# a second tree start. Stop, start, stop, start is the whole mechanism.
#
# TKT-893 MISSED IT rather than a change breaking it: the feeder pipeline
# shipped in 5.41 (TKT-851) and job.stop in 5.42 (TKT-893), so a monitor was
# already three processes on the day the single kill was written.
#
# THE FIX IS A PROCESS GROUP, not a descendant walk. The table this CLI gathers
# is `ps -eo pid=,lstart=,args=` - no ppid, and tasklist has no such column
# either - so walking parents would mean changing shared gathering code that
# every police rule reads.
#
# WHY THIS FILE CALLS THE REAL SUBS. A test that re-typed the wrapper and killed
# it would pass while the shipped one leaked. So the spawn and the signal are
# named - _spawn_monitor and _signal_monitor - and this asserts on those. That
# is the point of the refactor as much as the tidiness: the two halves have to
# agree about what the recorded pid is, and today they do not.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI::Job;

# Real processes are spawned here, which is unusual for this suite and is the
# only way to test the claim: the fault is not visible in any data structure.
# Windows has no ps to see them with and no process group to signal, which is
# the platform the fix explicitly does not serve - so it is skipped rather than
# asserted about.
plan skip_all => 'this test spawns processes and reads ps; not on Windows'
  if $^O eq 'MSWin32';

# --- the pair is named --------------------------------------------------------

ok( Tira::CLI::Job->can('_spawn_monitor'),
    'THE SPAWN IS A NAMED SUB. Today it is eighteen inline lines in job.start, '
      . 'so nothing but job.start can start a monitor and no test can spawn '
      . 'the real thing' );

ok( Tira::CLI::Job->can('_signal_monitor'),
    'AND SO IS THE SIGNAL. Today it is one line in the job.stop branch, forty '
      . 'lines and one sub away from the spawn it has to agree with - which is '
      . 'the shape of this bug' );

# A STAND-IN FOR THE FEEDER, and on TKT-927 it had to change shape with the
# thing it stands in for.
#
# It used to be a drain: `while (<STDIN>) {}`, because the monitor was a
# pipeline and the feeder was only its reader. Since 5.52 the feeder IS the
# monitor - it puts itself in a process group, runs the command as its own
# child and reads that child's pipe - so a stub that only drained STDIN would
# spawn nothing, lead no group, and make every assertion below fail while
# reporting the code as broken.
#
# So this stub does what the real feeder does and nothing else: setpgrp, then
# run the command it was handed. It is deliberately NOT the real verb - that
# would need a board, and this file is about _spawn_monitor and
# _signal_monitor rather than about the feeder's own behaviour, which t/538
# covers.
my $tmp = tempdir( CLEANUP => 1 );
my $feeder = File::Spec->catfile( $tmp, 'feeder' );
{
    open my $fh, '>', $feeder or die "$feeder: $!";
    print {$fh} <<'STUB';
eval { setpgrp 0, 0 };
my @command = ( 'sleep', '47' );
require IPC::Open3;
while (1) {
    my $pid = IPC::Open3::open3( my $in, my $out, undef, @command );
    close $in;
    while ( my $line = <$out> ) { }
    waitpid $pid, 0;
    last if !$ENV{STUB_EVERY};
    sleep $ENV{STUB_EVERY};
}
STUB
    close $fh;
}

# What is actually running, by pid. `ps` rather than kill 0, because a zombie
# answers kill 0 and is not running - and a stop that left zombies would pass a
# kill-0 assertion while the orphans in production were plainly alive.
sub alive {
    my (@pids) = @_;
    return () if !@pids;
    my $listing = `ps -o pid=,stat= -p @{[ join ',', @pids ]} 2>/dev/null` // '';
    my @up;
    for my $line ( split /\n/, $listing ) {
        next if $line !~ /\A\s*(\d+)\s+(\S+)/;
        next if $2 =~ /\AZ/;    # a zombie is not running
        push @up, $1;
    }
    return @up;
}

# Every process in the monitor's tree, walked from the pid through ppid.
#
# NOT BY GROUP AND NOT BY COMMAND, and both alternatives were tried and were
# wrong. By group finds the whole tree only once the fix has put it in one, so
# before the fix "nothing survived" would be asked about a single process and
# the leak this file exists to catch would pass. By command - matching
# `tira-monitor` across the whole process table - swept in the monitors that
# t/493, t/502 and t/503 spawn, so this file passed alone and failed under
# `prove -j4`, which is a test reporting on its neighbours.
#
# CAPTURED BEFORE THE SIGNAL, which is what makes ppid usable at all. The
# survivors of a leaked stop are reparented to init and their link to the
# monitor is gone - that is the fault. While it is still running the tree is
# intact, so the pids are collected then and checked afterwards by number.
#
# The test may read ppid even though the shipped gathering cannot: the rule
# there is about Tira::Job never learning to reach a process table, not about
# what a test is allowed to look at.
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

sub reap {
    my (@pids) = @_;
    kill 'KILL', $_ for @pids;
    waitpid $_, 0 for @pids;
    return;
}

# --- a spawned monitor is stopped, in both shapes ------------------------------
#
# restart_every 0 and 5, because the loop adds a fourth process and I filed this
# card believing the loop was the cause. It is not - KD8 - and asserting both
# is what keeps a fix from being aimed at the loop alone.

for my $every ( 0, 5 ) {
    my $shape = $every ? "with restart_every $every" : 'with no restart_every';

    my $pid = eval {
        local $ENV{STUB_EVERY} = $every;
        Tira::CLI::Job::_spawn_monitor( $^X, $feeder, 'JOB-T', $every );
    };

    # non-zero is the whole claim: a spawn that returned nothing would make
    # every assertion below vacuously green, which is how a leak survives a
    # test written to catch it.
    ok( $pid && $pid =~ /\A[1-9][0-9]*\z/,
        "$shape: a monitor was spawned and its pid returned - the pid the "
          . 'board would record' )
      or next;

    sleep 1;
    my @tree = tree_of($pid);
    my @up   = alive(@tree);

    cmp_ok( scalar @up, '>=', 2,
        "$shape: the monitor is more than one process - the feeder and the "
          . 'command it runs. It was three, or four with a loop, until TKT-927 '
          . 'removed the shell and the shim; the number changed and the reason '
          . 'this test exists did not, because signalling the recorded pid '
          . 'alone still leaves the command running' );

    my $signalled = eval { Tira::CLI::Job::_signal_monitor($pid) };

    is( $signalled, 'group',
        "$shape: THE STOP SAYS THE WHOLE TREE WAS SIGNALLED. Today job.stop "
          . 'reports success whether it stopped a monitor or orphaned three '
          . 'quarters of one, so a leak reads exactly like a clean stop. Not a '
          . 'count: signalling a group returns the number of GROUPS reached, '
          . 'so how many processes were in it is not knowable here' );

    sleep 1;
    my @survivors = alive(@tree);

    is( scalar @survivors, 0,
        "$shape: NOTHING SURVIVED THE STOP. Today the top shell dies and the "
          . 'rest are orphaned to init and keep running, which is the pair of '
          . 'trees measured on the machine at 11:00' )
      or diag( "still running: @survivors" );

    reap(@tree);
}

# --- and the recorded pid leads the group -------------------------------------
#
# Criterion 1 in one assertion: "the pid the board records is the pid of the
# process it can stop". A group whose leader is some other pid would still be
# signallable, but not by the number the board holds - and the board holds only
# what open3 returned.

{
    my $pid = eval {
        Tira::CLI::Job::_spawn_monitor( $^X, $feeder, 'JOB-T', 0 );
    };

    SKIP: {
        skip 'no monitor was spawned', 2 if !$pid;
        sleep 1;

        my ($group) = `ps -o pgid= -p $pid 2>/dev/null` =~ /(\d+)/;

        is( $group, $pid,
            'THE RECORDED PID IS THE GROUP LEADER, which is what makes one '
              . 'signal reach the tree. Today the monitor inherits the group '
              . 'of whatever ran job.start, so there is no group to signal '
              . 'that would not also hit the caller' );

        my @tree = tree_of($pid);
        Tira::CLI::Job::_signal_monitor($pid);
        sleep 1;

        is( scalar alive(@tree), 0,
            'and signalling that one pid stops all of it' );

        reap(@tree);
    }
}

# --- a pid that is already gone ----------------------------------------------
#
# The case the orphans on the machine leave behind, and the one criterion 4's
# second half is for. It must not die, and it must not claim to have stopped
# something.

{
    my $signalled = eval { Tira::CLI::Job::_signal_monitor(999_999_999) };
    my $why = $@ // '';

    is( $why, '',
        'signalling a pid that is not there does not raise - a stop whose '
          . 'process has already gone is the commonest reason to stop '
          . 'something, and refusing it would leave the record wrong for ever' );

    is( $signalled, 'gone',
        'AND IT SAYS SO. "gone" is what makes a stop that stopped nothing '
          . 'different from one that worked, instead of the board saying the '
          . 'same thing either way' );

    # A monitor that was never started has no pid at all, and job_stop hands
    # back whatever it cleared - undef included. Signalling that must answer
    # rather than warn, and "gone" is the true answer.
    is( Tira::CLI::Job::_signal_monitor(undef), 'gone',
        'and no pid at all is "gone" too - a monitor that was never started '
          . 'is exactly the case job_stop exists to clear' );

    is( Tira::CLI::Job::_signal_monitor('not-a-pid'), 'gone',
        'as is anything that is not a pid, which must not reach kill - a '
          . 'negative or zero argument there signals a whole process group, '
          . 'and 0 would be this very process' );
}

# --- and a monitor that leads no group ---------------------------------------
#
# Every monitor running on this machine right now, since none was started by the
# shim. The fallback signals the recorded process only, and the whole value of
# the word it returns is that it does NOT say "group" - the rest of that
# monitor is still running and somebody has to be told.
#
# Injected rather than spawned: making a real process that leads no group means
# inheriting this test's own group, and signalling THAT would kill the test.
# Which is also precisely why the fallback is the narrow one.

{
    my @asked;
    my $signalled = Tira::CLI::Job::_signal_monitor(
        4242,
        killer  => sub { push @asked, $_[0]; return 1 },
        grouper => sub { return 900 },    # led by somebody else
    );

    is( $signalled, 'process',
        'a monitor that leads no group reports "process", not "group" - it was '
          . 'started before this shipped, so whatever else it forked is still '
          . 'running and the word is what says so' );

    is_deeply( \@asked, [4242],
        'AND THE GROUP WAS NEVER SIGNALLED. This is the assertion that matters '
          . 'most in the file. The first version of _signal_monitor tried the '
          . 'group first and fell back, which sounds equivalent and is not: '
          . 'kill TERM -PID signals THE GROUP WHOSE ID IS PID, whoever created '
          . 'it. Running the suite that way took out prove\'s own workers and '
          . 'left an orphaned test file going for ten minutes. A stop verb that '
          . 'can kill its caller\'s siblings is worse than the leak it fixes' );
}

# --- and it asks before it signals -------------------------------------------
#
# The same claim from the other side: when the pid DOES lead its own group, the
# group is signalled and the bare pid is not, so a stopped monitor is not
# signalled twice.

{
    my @asked;
    my $signalled = Tira::CLI::Job::_signal_monitor(
        4242,
        killer  => sub { push @asked, $_[0]; return 1 },
        grouper => sub { return $_[0] },    # leads its own group
    );

    is( $signalled, 'group', 'a pid that leads its own group is stopped as a group' );

    is_deeply( \@asked, [-4242],
        'and only the group is signalled - the negative pid, once. A monitor '
          . 'signalled again by pid afterwards would be a second TERM to a '
          . 'process that already had one' );
}

# A pid nothing knows about: getpgrp answers -1 with errno set rather than
# dying, and the guard must read that as "leads no group" instead of comparing
# it to the pid and hoping.

{
    my @asked;
    my $signalled = Tira::CLI::Job::_signal_monitor(
        4242,
        killer  => sub { push @asked, $_[0]; return 0 },
        grouper => sub { return -1 },
    );

    is( $signalled, 'gone',
        'a pid whose group cannot be read and which nothing can signal is '
          . '"gone" - not a group, and not a claim that something was stopped' );

    is_deeply( \@asked, [4242],
        'and it was not signalled as a group on the way to finding that out' );
}

done_testing();

__END__

=head1 NAME

529-a-stop-that-stopped-nothing.t - stopping a monitor stops all of it

=head1 WHY

TKT-920. C<job.stop> sends C<TERM> to the pid C<open3> returned, which is the
shell that owns the pipe. The command, the feeder and - when C<restart_every> is
set - the loop subshell are separate processes and survive, orphaned to init.
The engine then clears the record, so the board forgets a monitor that is still
running; C<job.start>'s duplicate guard asks that emptied record and starts a
second tree.

Measured on this machine at 11:00 on 2026-09-04: C<JOB-006> running under two
pids, the board holding a third that was dead.

=head1 WHAT IS ASSERTED

That the spawn and the signal are named subs, so a test can call the real pair
rather than a re-typed copy - the two halves have to agree about what the
recorded pid is, and the bug is that they do not.

Then, with real processes: that a spawned monitor is more than one process, that
stopping it leaves nothing running, in both the looping and non-looping shapes,
that the recorded pid leads the group, and that the stop reports how many
processes it signalled.

Finally that signalling a pid that has already gone does not raise and reports
zero, which is what makes a stop that stopped nothing distinguishable from one
that worked.

=head1 WHAT IS NOT ASSERTED, AND WHY

Anything on Windows, where the file skips. There is no C<ps> to see the tree
with and no process group to signal; C<setpgrp> is unimplemented and the shim
execs anyway, so behaviour there is exactly what it is today. The reported count
is what says so, and that is deliberate rather than overlooked - criterion 4
allows a stop that says plainly it cannot stop everything.

Anything about the two orphan trees already running. No fix reaches processes
started before it.

=cut
