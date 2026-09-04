package Tira::CLI::Job::Feeder;

use strict;
use warnings;

use Tira::Job ();

our $VERSION = '5.52';

# THE PROCESS A MONITOR IS. One, since TKT-927.
#
# It was three, or four with a loop: a perl shim that set a process group and
# exec'd sh, an sh script that owned a pipe and looped, the command itself, and
# the feeder on the other end of the pipe. His own JOB-006 in ps was that entire
# script plus a resolved absolute path into the install - and it never said
# which board the job belonged to, which is the part that is not cosmetic. Job
# ids are per-board and this machine runs the skill for several projects, so
# JOB-006 exists four times over; on 2026-09-04 I matched processes by
# `--id JOB-006` across the machine, reported another project's monitors as his,
# and offered to kill four of them.
#
# His words, 2026-09-04 16:05: "can you create a helper like tira.job.feeder
# --command "something arg1 ..." --loop --interval N --ref <which project>-JOB-NNN
# / on the ps -ef table show much more tidy process list".
#
# THIS IS A SUBTRACTION FROM THREE CARDS, NOT A FOURTH MECHANISM BESIDE THEM,
# which is the card's own test of whether it was written correctly:
#
#   TKT-851 - the job's words are positional parameters and never shell text, so
#             a semicolon or a backtick in a command stays an argument. Kept by
#             construction now: there is no shell to keep it away from.
#   TKT-842 - a pipe with no reader fills at about 64KB and blocks the child for
#             ever. The reader is this process, so it cannot be forgotten.
#   TKT-920 - the monitor runs in a process group of its own so the recorded pid
#             stops all of it. The setpgrp is inside the process that owns the
#             child rather than wrapped around a pipeline.

# What ps shows. Set into $0 as the feeder's first act, so the tidy line is what
# a person sees however the process was invoked.
#
# THE BOARD'S NAME, NEVER ITS PATH. The path travels in TIRA_HOME precisely
# because a --project argument would put it in the process table for anyone
# running ps, and this skill does not disclose it.
sub monitor_process_title {
    my ( $id, $board, $command ) = @_;
    my @words = @{ $command || [] };
    my $said  = join ' ', @words;
    my $whose = defined $board && length $board ? " [$board]" : '';
    return "tira.job.feeder $id$whose -- $said";
}

# READING WHAT A MONITOR SAYS, from wherever it is being said.
#
# Lifted out of the job.feed branch on TKT-927 so that the verb a person pipes
# into and the feeder that owns its own pipe share one implementation rather
# than two that drift. The loop is TKT-851's and its shape is load-bearing:
#
# A BATCH THAT NEVER FILLS MUST STILL GO IN. An earlier version flushed at 25
# lines or at end of input - and a monitor never ends, so a poller printing a
# line a minute sat unheard for twenty-five minutes and one printing hourly for
# a day. The board read "never called in" while the monitor was talking, which
# is the silence this epic exists to end, rebuilt inside the fix for it.
#
# So the wait is bounded: block for at most $quiet seconds, and if nothing
# arrived hand over whatever is held.
sub feed_from_handle {
    my ( $tira, $args, $id, $handle, $quiet, $batch_size ) = @_;

    my @batch;
    my $flush = sub {
        return if !@batch;
        $tira->job_feed( %{$args}, id => $id, lines => [@batch] );
        @batch = ();
        return;
    };

    require IO::Select;
    my $watch = IO::Select->new();
    $watch->add($handle);

    while (1) {
        # can_read returns on timeout with nothing, which is the quiet this is
        # watching for - not an error and not end of input.
        if ( !$watch->can_read($quiet) ) {
            $flush->();
            next;
        }

        my $line = <$handle>;
        last if !defined $line;    # the monitor's output really did end
        $line =~ s/\r?\n\z//;
        push @batch, $line;
        $flush->() if @batch >= $batch_size;
    }
    $flush->();
    return;
}

# What the feeder does between runs of a command that ends. A named sub rather
# than a bare `sleep` so that the looping branch above can be run in a test with
# a wait of its own - the loop otherwise has no end, which is the point of it.
sub _wait {
    my ($seconds) = @_;
    sleep $seconds;
    return 1;
}

# The verb itself: run the monitor's command, read what it says, and feed it.
#
# NO fork OF ITS OWN. open3 does the forking, which keeps the child's branch
# out of this file - a branch that execs cannot report coverage, and a gate that
# demands 100% would have been answered with an exemption instead of a design.
# It also merges the child's standard error into the same handle, which is what
# the old script's `2>&1` did.
sub run_feeder {
    my ( $tira, $args, $quiet, $batch_size ) = @_;

    my $id = $args->{id} // '';
    die "A job id is required - which monitor is speaking?\n" if $id eq '';

    my ($job) = grep { ( $_->{id} // '' ) eq $id } @{ $tira->job_list( %{$args} ) };
    die "Job '$id' is not on this board - which monitor is speaking?\n" if !$job;
    die "Job $id is a cron job, not a monitor - it runs when due, so nothing "
      . "feeds on its behalf\n"
      if ( $job->{schedule_kind} // '' ) ne 'monitor';

    # THE COMMAND MAY BE GIVEN OR TAKEN FROM THE RECORD, and either way it is
    # split by the engine's own splitter rather than by a shell. That is
    # TKT-851's guarantee restated in the one place a --command string could
    # have undone it.
    my @command = Tira::Job::job_command_words( $args->{command} // $job->{command} );
    die "Job $id has no command to run\n" if !@command;

    my $board = eval { $tira->project_show( %{$args} )->{name} } // '';
    $0 = monitor_process_title( $id, $board, \@command );    ## no critic

    # IN AN eval BECAUSE WINDOWS HAS NONE, the same way the shim it replaces
    # did. There the feeder runs anyway and stopping reaches the recorded pid
    # alone, which is what _signal_monitor's answer says out loud.
    eval { setpgrp 0, 0 };

    my $every = $args->{interval} // $job->{restart_every} // 0;

    # THE WAIT IS INJECTABLE, and for the reason t/529 made _signal_monitor's
    # killer injectable: the looping branch cannot be asserted by running it,
    # because a monitor that restarts itself does not end. A caller that hands
    # in a wait which answers false gets exactly one pass and the branch is
    # exercised rather than exempted. Nothing in the command surface passes it;
    # the default is _wait, which is what the verb actually does.
    my $wait = $args->{wait} || \&_wait;

    require IPC::Open3;
    while (1) {
        my $pid = IPC::Open3::open3( my $in, my $out, undef, @command );
        close $in;
        feed_from_handle( $tira, $args, $id, $out, $quiet, $batch_size );
        close $out;
        waitpid $pid, 0;

        last if !$every;
        last if !$wait->($every);
    }

    return { id => $id, board => $board, command => [@command],
        restart_every => $every, ran => 1 };
}

1;

__END__

=head1 NAME

Tira::CLI::Job::Feeder - the single process a monitor is

=head1 DESCRIPTION

C<tira.job.feeder> runs a monitor's command, reads what it says and feeds the
board. One process where there were three, and the ps line says which board's
job it is - the fact that was missing, and not a cosmetic one, since job ids are
per-board and one machine runs this skill for several projects.

=head1 FUNCTIONS

=head2 monitor_process_title

The line C<ps> shows, assigned to C<$0>: the verb, the job, the board's B<name>
in brackets, and the command. Never the board's path - that travels in
C<TIRA_HOME> exactly so it stays out of the process table.

=head2 feed_from_handle

Reads lines from a handle and hands them to C<job_feed> in batches, flushing
whatever is held after a bounded quiet. Shared by C<tira.job.feed>, which reads
standard input, and by the feeder, which reads its own pipe - one
implementation, because the bounded wait is what lets a monitor speaking once an
hour be heard within seconds and two copies of that would drift.

=head2 run_feeder

Looks the job up, refuses an id that names nothing and a cron job, splits the
command with L<Tira::Job>'s C<job_command_words>, sets the process title, puts
itself in a process group of its own, and then runs the command with its output
on a pipe this process reads. With an interval it starts the command again after
it ends.

It does no C<fork> of its own: C<IPC::Open3> does that, which keeps a branch
that C<exec>s - and therefore can never report coverage - out of this file.

=cut
