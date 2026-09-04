package Tira::CLI::Job::Monitor;

# Starting a monitor and stopping it - the two halves that have to agree about
# which pid the board records.
#
# LIFTED OUT OF Tira::CLI::Job BY HIS 500-LINE RULE (Telegram 6104, guarded by
# t/524), which TKT-920's work crossed: 496 lines became 583. The split is not
# arbitrary arithmetic though - it is the concern this card is about. Job.pm
# keeps the four verbs and their argument handling; this holds the process
# lifecycle, where the spawn and the signal now sit forty lines apart instead of
# in different subs in a 583-line file. That distance is what let them disagree
# for a release, and putting them side by side is half the fix.

use strict;
use warnings;

# Start a monitor, and record what it started as.
#
# WHY open3 AND NOT fork/setsid/exec. A hand-rolled detach puts the child's
# redirections and its exec in a branch that only ever runs in the child
# process, where Devel::Cover cannot follow it - so the mandatory 100%
# statement gate would be met by writing the fork out again in a shape nobody
# runs, or by lowering the gate. open3 is already this codebase's spawn (see
# run_due_job) and does the forking in code that is not ours to cover. The
# monitor is reparented when this process exits, which is what "keeps running"
# needs; it is not setsid'd, and a terminal hangup would still reach it. That
# is a real difference from a daemon and is written here rather than implied.
#
# OUTPUT GOES THROUGH A PIPELINE to the feeder, which is its reader. An UNREAD
# pipe fills at about 64KB and blocks the monitor forever - the deadlock TKT-841
# was reviewed for - and until TKT-851 this said the output went to a file for
# exactly that reason. The constraint is unchanged; what satisfies it is not.

# Is this word something the system can actually run? Answered the way a shell
# answers it: a word with a slash is a path and is asked directly, a bare word is
# looked for along PATH. A directory is not a program, which -x alone would say
# yes to.
sub _command_is_runnable {
    my ($word) = @_;
    return 0 if !defined $word || $word eq '';

    require File::Spec;
    return ( -x $word && !-d $word ) ? 1 : 0 if $word =~ m{/};

    for my $dir ( File::Spec->path ) {
        my $try = File::Spec->catfile( $dir, $word );
        return 1 if -x $try && !-d $try;
    }
    return 0;
}

sub _start_monitor {
    my ( $tira, $args, $job ) = @_;

    die "Job $job->{id} is a cron job - it runs when due, and is not started\n"
      if ( $job->{schedule_kind} // '' ) ne 'monitor';
    die "Job $job->{id} is disabled - enable it before starting it\n"
      if !$job->{enabled};

    my @command = Tira::Job::job_command_words( $job->{command} );
    die "Job $job->{id} has no command to run\n" if !@command;

    # ALREADY RUNNING IS A REFUSAL, not a second process. Without this, starting
    # a live monitor spawns a twin and overwrites the recorded pid, so the first
    # process keeps running with nothing on the board pointing at it - an orphan
    # monitor-dead cannot see, which is precisely the failure EPC-014 exists to
    # end. From a terminal that takes a deliberate mistake; with TKT-843's play
    # button it is one stray click, which is what made it worth fixing here.
    require Tira::Job;
    die "Job $job->{id} is already running as pid $job->{pid} - starting it "
      . "again would leave the first process with nothing on the board "
      . "pointing at it\n"
      if Tira::Job::job_monitor_alive( $job, _running_processes_for_jobs() );

    # A PIPELINE, NOT A REDIRECT. TKT-851, after his instruction that monitors
    # should not have separate logs and his answer to Q-112 choosing a feeder:
    # the monitor's output goes THROUGH a Tira command that records it against
    # this job, so the board hears from the monitor rather than reading its
    # leavings. That is what makes "when did this monitor last call in" a fact,
    # which is what TKT-873's silence rule needs.
    #
    # The shell owns the pipe, so the feeder lives and dies with the monitor
    # instead of being a second thing somebody has to start. And the feeder
    # drains continuously, which is the whole reason a pipe is safe here at all -
    # TKT-842 chose a file because a pipe with NO READER fills at about 64KB and
    # blocks the child forever. A pipe with a reader does not.
    #
    # THE FEEDER IS RESOLVED FROM THIS FILE, not from PATH. A monitor started by
    # a board that happens to have d2 on its PATH and one started by a board that
    # does not must behave the same, and the entrypoint sits at a known place
    # relative to this module - the same reasoning _view_dir uses for templates.
    my $feeder = _feeder_entrypoint();

    # THE BOARD TRAVELS IN THE ENVIRONMENT, not on the command line. The feeder
    # has to find the same project this monitor belongs to, and a --project
    # argument would put the board's location into the process table for anyone
    # running ps. An inherited variable does not.
    my $root = $tira->discover_project( %{$args} );

    # THE COMMAND IS CHECKED BEFORE THE SHELL IS ASKED TO RUN IT. open3 used to
    # give this refusal for free: exec'ing a program that is not there failed,
    # and job.start said so. A shell ALWAYS starts, then fails inside itself with
    # exit 127 that nobody is waiting on - so a monitor whose command is
    # misspelled would look started, and only monitor-dead would notice, minutes
    # later and as an alarm rather than an answer. The check has to move here or
    # the refusal is lost with the redirect.
    die "$command[0]: command not found\n"
      if !_command_is_runnable( $command[0] );

    require IPC::Open3;


    my $pid = eval {
        local $ENV{TIRA_HOME} = $root;
        _spawn_monitor( $^X, $feeder, $job->{id},
            ( $job->{restart_every} || 0 ), \@command );
    };
    if ( !$pid ) {
        my $why = $@ || 'could not be started';
        $why =~ s/\s+\z//;
        die "$command[0]: $why\n";
    }

    # SPAWNING AND RECORDING MUST NOT COME APART. The process exists the
    # instant open3 returns; the board only learns its pid on the next line.
    # If that write fails - a held lock, a full disk - the old code left a
    # RUNNING monitor that the board had no pid for, which monitor-dead then
    # reported dead on every pass while job.start, run again, started a second
    # copy. A live monitor reported dead is the noise that gets this rule
    # ignored, and a silent duplicate is worse.
    #
    # So the child is killed if it cannot be recorded, and the failure is
    # raised. Leaving nothing running is the state the caller can retry from.
    my $started = eval { $tira->job_started( %{$args}, id => $job->{id}, pid => $pid ) };
    if ( !$started ) {
        my $why = $@ || 'the start could not be recorded';
        $why =~ s/\s+\z//;
        kill 'TERM', $pid;
        waitpid $pid, 0;
        die "Started $job->{id} as pid $pid but could not record it, so it "
          . "was stopped again rather than left running unrecorded: $why\n";
    }
    return $started;
}

# The process table, asked for once and by the CLI layer, because the engine is
# forbidden every construct that could read it. Kept as its own sub so the
# start path can be tested without a real process table.
sub _running_processes_for_jobs {
    require Tira::CLI::Police;
    return Tira::CLI::Police::_running_processes();
}

# Run one job NOW, whatever its schedule says.
#
# His msg 6484: "each repeated job record has a play button. That the user can
# run them anytime bypass the schedule."
#
# ONE EXECUTOR. This is TKT-841's run_due_job with the due-check simply not
# asked - not a second implementation of running a command. That executor
# carries a deadlock fix (a pipe nobody drains blocks the child forever) and a
# signal-status fix (a killed job reported success) that only came out of
# review; a fresh executor written for a button would have carried neither.
#
# A MONITOR IS STARTED RATHER THAN FIRED, decided as TKT-843's CHK-001 before
# any of this was written. A monitor has no schedule to bypass - it is either up
# or it is not - so "run it now" on that row means start it, which is the action
# that answers the monitor-dead finding printed beside it.
# HOW A MONITOR IS STARTED, in one place, because the signal that stops it has
# to agree with it about which pid the board records - and for a day it did not.
# TKT-920: job.stop sent TERM to the pid open3 returns, which is the shell that
# owns the pipe, while the command and the feeder are separate processes and
# survived it. Naming the spawn beside _signal_monitor is what makes the two
# halves reviewable together; it is also the only way the suite can start a real
# monitor, since job.start is forty lines of record-keeping around this.
#
# THE FEEDER ARRIVES AS AN ARGUMENT rather than being resolved here. The caller
# resolves it relative to this file, where it lives after an install; the source
# tree has no skills/job/cli/feed at all, so a spawn that resolved it internally
# could not be exercised in a test.
# WHERE THE ENTRYPOINT IS, FOUND RATHER THAN COUNTED.
#
# This used to be dirname(__FILE__) plus three updirs plus skills/job/cli/...,
# which was correct while the code lived in lib/Tira/CLI/Job.pm. TKT-920 lifted
# it one level deeper into this file to stay under the 500-line rule, and the
# same three updirs then landed on lib/ - so the resolved path was
# <root>/lib/skills/job/cli/feed, exec failed, and the child was a zombie
# before it could say anything. open3 had already returned the pid the board
# recorded, so the board held a pid for a monitor that had never started.
#
# IT SHIPPED IN 5.45 and was found by reading ps in a container on TKT-927.
# Nothing caught it because every test passes the feeder path IN - t/529 says
# so in its own comment - so no test exercised the resolution.
#
# COUNTING LEVELS IS THE SAME FAULT AS NAMING A FILE, which TKT-921 spent an
# evening removing from the suite: both encode where something sits today, and
# both fail as "the code regressed" when it moves. So this WALKS UP looking for
# the skill root - the directory holding lib/Tira/CLI.pm, which is what every
# entrypoint script itself looks for - and the answer survives this module
# being lifted again.
sub _feeder_entrypoint {
    require File::Basename;
    require File::Spec;

    my $cursor = File::Basename::dirname( File::Spec->rel2abs(__FILE__) );
    while ( !-f File::Spec->catfile( $cursor, 'lib', 'Tira', 'CLI.pm' ) ) {
        my $parent = File::Basename::dirname($cursor);

        # The root of the filesystem is its own parent, which is where this
        # stops rather than looping. A caller that gets undef gets the same
        # refusal it would have got from a path that did not exist.
        last if $parent eq $cursor;
        $cursor = $parent;
    }

    return File::Spec->catfile( $cursor, 'skills', 'job', 'cli', 'feeder' );
}

sub _spawn_monitor {
    my ( $perl, $feeder, $id, $every, $command ) = @_;
    require IPC::Open3;

    # ONE PROCESS, since TKT-927. It was three - a perl shim that set a process
    # group and exec'd sh, an sh script that owned the pipe and looped, and the
    # command - with the feeder on the far end. His own JOB-006 in ps was that
    # whole script plus a resolved absolute path into the install, and it never
    # said which board the job was on. Job ids are per-board and this machine
    # runs the skill for several projects, so that omission is what let me
    # report another project's monitors as his.
    #
    # EVERYTHING THE SCRIPT DID IS NOW THE FEEDER'S, and none of it is text a
    # shell parses: it puts itself in a process group (TKT-920), runs the
    # command through open3 as a LIST (TKT-851 - a semicolon stays an
    # argument), reads that pipe itself (TKT-842 - the reader cannot be
    # forgotten because it is the same process), and starts the command again
    # after it ends when the job asked for that (TKT-891).
    #
    # THE RECORDED PID IS STILL THE SUPERVISOR'S, which is what keeps a restart
    # invisible to monitor-dead: the feeder outlives each run of the command.
    #
    # NOTHING OF THE JOB'S IS ON THE COMMAND LINE except its id. The command
    # comes from the record and the board travels in TIRA_HOME, so ps shows what
    # the feeder chooses to show rather than the board's location.
    return IPC::Open3::open3( my $in, my $out, my $err,
        $perl, $feeder, '--id', $id,
        ( $every ? ( '--interval', $every ) : () ) );
}

# STOPPING THE WHOLE MONITOR, and reporting how much of it there was.
#
# The group first, because that is the one signal that reaches a pipeline the
# shim put in a group of its own. The single pid second, because a monitor
# started before TKT-920 shipped is in whatever group its starter was, and
# signalling THAT would hit the caller - so the fallback is deliberately the
# narrow one, and it is the case that leaks.
#
# WHAT CAME BACK IS A WORD, NOT A COUNT, and the difference is a fact about
# kill rather than a preference. Signalling a group returns the number of
# GROUPS reached - always 1 - so how many processes were in it is not knowable
# from here, and the only table this file can reach carries no pgid to count
# them with. Returning 4 would have been a number I made up.
#
#   group    the whole tree was signalled - the monitor is stopped
#   process  only the recorded process was, because it leads no group of its
#            own: a monitor started before TKT-920 shipped. Whatever else it
#            forked is still running and this is the word that says so.
#   gone     nothing was there to signal
#
# THAT DISTINCTION IS THE POINT. job.stop reported success whether it stopped
# a monitor or orphaned three quarters of one, so a leaked stop and a clean one
# read identically from the board - which is why this went a day unseen.
# ASKING FIRST, RATHER THAN TRYING THE GROUP AND FALLING BACK. The first
# version of this did try the group first, and it is worth recording why that
# was dangerous rather than merely wrong: `kill 'TERM', -$pid` signals THE GROUP
# WHOSE ID IS $pid, and says nothing about whether the monitor created that
# group. A pid that leads no group of its own - anything started before this
# shipped, or a plain fork, which is what t/513 hands job.stop - would either
# reach nothing or reach a group that belongs to somebody else entirely.
#
# It was caught by the suite hanging: the group signal took out `prove`'s own
# workers and left an orphaned test file running for ten minutes. A stop verb
# that can kill its caller's siblings is a worse fault than the leak it was
# written to fix, and no fallback ordering makes it safe - the question has to
# be asked before the signal, not inferred from its result.
#
# getpgrp IS THE QUESTION. A process leads its own group when its group id is
# its own pid, which is exactly what the shim in _spawn_monitor arranges and
# exactly what nothing else does by accident.
sub _signal_monitor {
    my ( $pid, %args ) = @_;
    return 'gone' if !defined $pid || $pid !~ /\A[1-9][0-9]*\z/;
    my $killer = $args{killer} || sub { return kill 'TERM', @_ };
    my $grouper = $args{grouper} || sub { return eval { getpgrp( $_[0] ) } };

    my $group = $grouper->($pid);
    if ( defined $group && $group eq "$pid" && $killer->( -$pid ) ) {
        return 'group';
    }

    return 'process' if $killer->($pid);
    return 'gone';
}

1;

__END__

=head1 NAME

Tira::CLI::Job::Monitor - starting and stopping a monitor

=head1 DESCRIPTION

The process lifecycle of a monitor job, lifted out of L<Tira::CLI::Job> when
TKT-920's work took that file past the 500-line rule F<t/524> enforces.

C<_start_monitor> refuses the cases that would leave the board saying something
untrue - a cron job, a disabled job, a job with no command, a job already
running - then spawns and records, killing the child if the record cannot be
written.

C<_spawn_monitor> and C<_signal_monitor> are the pair. They have to agree about
what the recorded pid IS, and for one release they did not: the spawn returned
the pid of the shell that owns the pipe, and the signal sent C<TERM> to that pid
alone while the command and the feeder - and, with C<restart_every>, the loop
subshell - carried on as orphans. The spawn now execs through a shim that makes
that pid a process-group leader, and the signal reaches the group.

=head1 WHAT MUST NOT REGRESS

The two subs stay in one file. Their whole history is a disagreement that was
possible because they were far apart.

C<_signal_monitor> tries the B<group> first and the bare pid only as a fallback.
A monitor started before this shipped leads no group of its own - it sits in
whatever group ran C<job.start> - so a group signal aimed at it would reach the
caller. That is why the fallback is the narrow one, and why it answers
C<process> rather than C<group>: the rest of that monitor is still running, and
something has to say so.

=cut
