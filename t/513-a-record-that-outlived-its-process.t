#!/usr/bin/env perl
# Three verbs, three different silences, and one process nobody is watching.
#
# TKT-868, TKT-869 and TKT-870, absorbed into TKT-893, EPC-014. Taken as one
# because they are one question asked three times: when a running monitor's
# record changes so that the recorded pid no longer describes it, what happens?
#
# TODAY EACH ANSWERS DIFFERENTLY AND NONE OF THEM SAYS SO:
#
#   update   changes the command. The pid still runs the OLD one, so the board
#            now claims the new command is what is running. TKT-868.
#   delete   removes the record. The process lives on with nothing pointing at
#            it, and monitor-dead cannot even report the orphan, because the
#            job it would have reported is gone. TKT-869.
#   disable  clears nothing. monitor-dead is deliberately silent about a
#            disabled monitor - it is absent on purpose - so it keeps running
#            and is invisible in both directions at once. TKT-870.
#
# THE DECISION, recorded on the card as KD13 before this file was written:
# THE BOARD NEVER SILENTLY CLAIMS SOMETHING FALSE. Each of the three either acts
# on the process or refuses and says why. To refuse actionably there has to be
# something to act with, so a stop verb exists - which also answers TKT-892,
# whose Stop button had no verb behind it.
#
# WHY REFUSE RATHER THAN QUIETLY STOP THE PROCESS. Stopping something is not
# what a caller asked for when they typed "update". A refusal naming
# tira.job.stop leaves the decision with the person and costs one command;
# killing a process because a field was edited is the kind of helpfulness
# nobody asks for twice.
#
# AND ONLY WHEN IT IS RUNNING. A monitor with no pid - never started, or started
# and stopped - is edited and deleted exactly as it is today. That is the
# ordinary case, and JOB-006 (created 17:29, no pid, never ran) would have been
# deleted precisely as it was.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

# A pid that is certainly running and is certainly not a monitor: this test.
# Using $$ means the liveness check finds a real process rather than depending
# on whatever happens to be on the machine.
my $alive = $$;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Outlived', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'OLS', epic_prefix => 'OLE', ticket_prefix => 'OLT',
    );
    return ( $tira, $root );
}

sub running_monitor {
    my ( $tira, $root ) = @_;
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'sleep 600' );
    $tira->job_started( project => $root, id => $job->{id}, pid => $alive );
    return $job->{id};
}

# --- the verb exists ----------------------------------------------------------

{
    my ( $tira, $root ) = board();
    ok( $tira->can('job_stop'),
        'there is a way to stop a monitor - TKT-892 needs one for its Stop '
          . 'button, and the three refusals below are only actionable if it '
          . 'exists' );
}

# --- changing a running monitor's command ------------------------------------

{
    my ( $tira, $root ) = board();
    my $id = running_monitor( $tira, $root );

    # any failure is what this means. There is one call here and one way for it
    # to fail: the refusal being asserted. A different exception would mean the
    # command did not reach the check at all, which is equally a failure of the
    # thing being tested.
    my $ok = eval {
        $tira->job_update( project => $root, id => $id, command => 'sleep 900' );
        1;
    };
    my $why = $@;

    ok( !$ok, 'changing a running monitor command is refused, rather than '
          . 'leaving the board claiming the new one is what is running' );
    like( $why, qr/tira\.job\.stop|stop/i,
        'and the refusal names what to do about it, so it costs one command '
          . 'rather than a search' );
}

# --- deleting a running monitor ----------------------------------------------

{
    my ( $tira, $root ) = board();
    my $id = running_monitor( $tira, $root );

    # any failure is what this means. As above: one call, one intended refusal.
    my $ok = eval { $tira->job_delete( project => $root, id => $id ); 1 };
    my $why = $@;

    ok( !$ok, 'deleting a running monitor is refused - the record would go and '
          . 'the process would not, and monitor-dead cannot report an orphan '
          . 'whose job no longer exists' );
    like( $why, qr/tira\.job\.stop|stop/i, 'and it says what to do first' );
}

# --- disabling a running monitor ---------------------------------------------

{
    my ( $tira, $root ) = board();
    my $id = running_monitor( $tira, $root );

    # any failure is what this means. One call, one intended refusal.
    my $ok = eval {
        $tira->job_update( project => $root, id => $id, enabled => 0 );
        1;
    };
    my $why = $@;

    ok( !$ok, 'disabling a running monitor is refused - monitor-dead is silent '
          . 'about a disabled monitor on purpose, so this is the one change '
          . 'that makes a running process invisible in both directions' );
    like( $why, qr/tira\.job\.stop|stop/i, 'and it says what to do first' );
}

# --- and a schedule change that would stop it being a monitor ----------------
#
# THIS ASSERTION EXISTS BECAUSE A REVIEW CHALLENGED A SENTENCE, not because a
# test failed. The first version of this card documented, three times, that
# "changing the schedule of a running monitor is harmless - it is already
# running, and monitor is what it stays". The second half is false: a schedule
# of "0 * * * *" makes it a CRON job and keeps the pid, and job_monitor_alive
# answers 0 for anything that is not a monitor - so the process ran on with
# nothing on the board watching it.
#
# Measured before this was written: kind=cron, pid=424242, and monitor_alive
# NOT ALIVE. That is TKT-870's own fault, reached through the guard written to
# close it.

{
    my ( $tira, $root ) = board();
    my $id = running_monitor( $tira, $root );

    # any failure is what this means. One call, one intended refusal.
    my $ok = eval {
        $tira->job_update( project => $root, id => $id, schedule => '0 * * * *' );
        1;
    };
    my $why = $@;

    ok( !$ok, 'turning a running monitor into a cron job is refused - the pid '
          . 'would stay on a record monitor-dead no longer watches, which is '
          . 'the same live-process-nobody-sees fault by another door' );
    like( $why, qr/tira\.job\.stop|stop/i, 'and it says what to do first' );

    # AND THE HARMLESS CASE IS STILL ALLOWED, or this refusal has gone too far:
    # a monitor staying a monitor is not a change the board can be wrong about.
    my $same = $tira->job_update(
        project => $root, id => $id, schedule => 'monitor' );
    is( $same->{schedule_kind}, 'monitor',
        'while a monitor staying a monitor is untouched' );
}

# --- and stopping it makes all three ordinary again ---------------------------
#
# The refusals are only reasonable if the way past them works. A gate that can
# only be satisfied by giving up is the shape TKT-895 was filed about.

{
    my ( $tira, $root ) = board();
    my $id = running_monitor( $tira, $root );

    $tira->job_stop( project => $root, id => $id );

    my ($after) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    ok( !$after->{pid},
        'stopping clears the pid, so the board stops pointing at a process it '
          . 'is no longer responsible for' );

    my $changed = $tira->job_update(
        project => $root, id => $id, command => 'sleep 900' );
    is( $changed->{command}, 'sleep 900',
        'and then the command changes, as it always could' );

    $tira->job_delete( project => $root, id => $id );
    my @left = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    is( scalar @left, 0, 'and it deletes' );
}

# --- what must not change: a monitor that is not running ---------------------
#
# THE ORDINARY CASE, and the one a careless refusal breaks. A monitor with no
# pid - never started, or started and stopped - must be edited and deleted
# exactly as it is today. JOB-006 on the real board was precisely this, and it
# had to be deletable.

{
    my ( $tira, $root ) = board();
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'sleep 600' );

    my $changed = $tira->job_update(
        project => $root, id => $job->{id}, command => 'sleep 900' );
    is( $changed->{command}, 'sleep 900',
        'a monitor that was never started is edited as before' );

    my $off = $tira->job_update( project => $root, id => $job->{id}, enabled => 0 );
    is( $off->{enabled}, 0, 'and disabled as before' );

    $tira->job_delete( project => $root, id => $job->{id} );
    my @left = grep { $_->{id} eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    is( scalar @left, 0, 'and deleted as before' );
}

# --- and a cron job is untouched by any of it --------------------------------

{
    my ( $tira, $root ) = board();
    my $cron = $tira->job_add(
        project => $root, schedule => '0 * * * *', command => 'd2 tira.stale' );

    my $changed = $tira->job_update(
        project => $root, id => $cron->{id}, command => 'd2 tira.doctor' );
    is( $changed->{command}, 'd2 tira.doctor',
        'a cron job is edited freely - it is not supposed to be up between '
          . 'runs, so there is no process for the board to be wrong about' );

    $tira->job_delete( project => $root, id => $cron->{id} );
    my @left = grep { $_->{id} eq $cron->{id} }
      @{ $tira->job_list( project => $root ) };
    is( scalar @left, 0, 'and deleted freely' );
}

# --- and the command the refusals name actually EXISTS -----------------------
#
# THIS ASSERTION WAS ADDED AFTER THE FACT AND IT SHOULD HAVE BEEN HERE FIRST.
# Every refusal above tells the reader to run `d2 tira.job.stop --id ...`, and
# all of them passed while that command did not exist: the engine sub was
# written and reachable from Perl, but nothing routed the verb, no entrypoint
# was installed, and a person following the message would have got "command not
# found".
#
# That is the same shape as TKT-895, filed today - a refusal whose way out is
# not actually available. A test proving the engine while the message names the
# CLI proves the half nobody reads.

{
    my $entrypoint = File::Spec->catfile( 'skills', 'job', 'cli', 'stop' );
    ok( -f $entrypoint && -x $entrypoint,
        'tira.job.stop is an installed entrypoint, not just an engine sub - '
          . 'the refusals above name it, and a person follows the message '
          . 'rather than calling Perl' );

    my $cli = Suite::cli_source();

    # non-empty is the whole claim: the assertion below searches this text.
    like( $cli, qr/\S/, 'the dispatcher is there to be read' );

    like( $cli, qr/job\\\.\(\?:[a-z|]*\bstop\b/,
        'and the dispatcher routes it, so the verb reaches the code rather '
          . 'than being refused as unknown' );
}

# --- and the CLI layer really signals, which is the half the engine cannot do -
#
# ANOTHER LESSON FROM THE SAME MISTAKE. The block above asserts the entrypoint
# exists and the dispatcher routes the verb; gate-run then refused the card with
# lib/Tira/CLI/Job.pm at 97.5%, naming the three lines of the job.stop branch.
# Asserting a route exists is not exercising it - which is exactly what went
# wrong when the verb was missing entirely.
#
# A REAL CHILD, so the kill is real. Using a made-up pid would exercise the
# branch and prove nothing about whether the signal lands; using $$ would
# terminate the test. So this forks something that would outlive the test, hands
# its pid to the board, and asks the dispatcher to stop it.

SKIP: {
    my $child = fork();
    skip 'fork is unavailable here', 3 if !defined $child;

    if ( !$child ) {
        # The child: long enough that only the signal can end it.
        sleep 60;
        exit 0;
    }

    my ( $tira, $root ) = board();
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'sleep 60' );
    $tira->job_started( project => $root, id => $job->{id}, pid => $child );

    require Tira::CLI::Job;
    my $stopped = Tira::CLI::Job::dispatch(
        $tira, { project => $root, id => $job->{id} }, {}, 'job.stop' );

    is( $stopped->{stopped_pid}, $child,
        'the dispatcher hands back the pid it let go of, so the CLI knows what '
          . 'to signal - the engine cannot, being forbidden the process table' );

    ok( !$stopped->{pid},
        'and the record is cleared, which happens BEFORE the signal so a signal '
          . 'that fails cannot leave the board pointing at it' );

    # Reaped rather than left: waitpid confirms the child actually ended, and
    # without it the test would leave a zombie for the harness to trip over.
    my $reaped = waitpid $child, 0;
    is( $reaped, $child,
        'and the process is gone - the CLI layer signals for real, which is the '
          . 'half of stopping the engine is not allowed to do' );
}

done_testing();

__END__

=head1 NAME

513-a-record-that-outlived-its-process.t - update, delete, disable, and a pid

=head1 WHY

TKT-868, TKT-869 and TKT-870 inside TKT-893. Each is the board's record of a
running monitor being changed so the recorded pid stops describing it, and each
was silent about it in a different way.

=head1 WHAT IS ASSERTED

That C<job_stop> exists; that changing the command of, deleting, or disabling a
RUNNING monitor is refused with a message naming the way past; that stopping it
makes all three ordinary again; and that a monitor which is not running, and any
cron job, behave exactly as they did before.

That last pair is the point. A refusal that also caught the ordinary case would
have made JOB-006 - created, never started, and needing to be deleted -
undeletable.

=cut
