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
