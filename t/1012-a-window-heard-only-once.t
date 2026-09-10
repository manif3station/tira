#!/usr/bin/env perl
# A repeated job's due window is announced once, even when several real
# police processes race the same store at once.
#
# TKT-1012. His report: a repeated job's due notice sometimes arrives as
# several separate Telegram messages, seconds apart, for the same due
# window. Explicitly a Tira defect in his account, not a project-specific
# one - the mechanism itself misbehaving.
#
# NOT REPRODUCED IN CURRENT CODE, investigated rather than assumed fixed.
# Two independent dedup layers were traced end to end: (1) the job-due
# rule's own $checked ledger read, made atomic with its write under
# _with_enforcement_lock by TKT-995 (5.86, 2026-09-07) - his report is
# dated one day later, 2026-09-08, and names exactly TKT-995's own
# symptom ("the same message logged three times, 33 seconds apart, on a
# job scheduled every three hours" - TKT-995's own Changes entry); (2)
# violation_record's speak/quiet gate, which sets quiet=>1 on a violation
# still true but not yet due to speak again, and bridge_write skips any
# violation carrying it - already lock-protected independently of TKT-995.
#
# Run 8 REAL forked processes (not sequential calls in one process) racing
# the full production sequence - police_pass then bridge_write, exactly
# as the watch loop in Police.pm's bridge_follow does - against the same
# store, four times over, in a throwaway container: every trial wrote
# exactly one job-due line, never more. The most likely explanation for
# his report is that the board he was watching had not yet received
# 5.86 - "a version pushed but not installed has not reached the machine
# that runs it" is this project's own standing caveat, measured before
# for agent-still (2.59) - and this is the same fault confirmed already
# fixed on 2026-09-10 the same way TKT-1032 (a zombie job-stop bug) was
# confirmed already fixed by TKT-1014.
#
# This test does not reproduce the bug NOW; it guards against it coming
# BACK, forking real processes rather than only asserting on one call -
# released together through a start barrier so they actually contend for
# the lock rather than merely running one after another by scheduling
# luck, and each checked for a clean exit so a child that silently died
# cannot pass by leaving less competition behind it.
#
# WRITTEN GREEN, deliberately: no known regression exists in this
# codebase to make it red against, and pretending otherwise would be
# dishonest about what was found.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    project => $root, name => 'Repro', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
);
$tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
$tira->job_add(
    project => $root, kind => 'message', message => 'test message',
    schedule => '* * * * *', author => 'claude',
);

my $store = File::Spec->catdir( $tmp, 'store' );

# Real forked processes, not sequential in-process calls - a fork is a
# real, separate process image, which is the shape "several police
# daemons" (his own words, and TKT-995's) actually takes.
#
# A START BARRIER, not just eight forks - without one, the OS is free to
# schedule each child to completion before the next even starts, which
# would prove only that the store survives repeated SEQUENTIAL calls, not
# that the lock holds under real contention. Each child blocks reading a
# pipe that stays open until every fork has happened, then all eight are
# released together.
pipe( my $barrier_read, my $barrier_write ) or die "pipe: $!";

my @pids;
for ( 1 .. 8 ) {
    my $pid = fork();
    die "fork failed: $!" if !defined $pid;
    if ( $pid == 0 ) {
        close $barrier_write;
        # Blocks until the parent closes its write end, below - the
        # release signal every child waits on together.
        my $buf;
        sysread( $barrier_read, $buf, 1 );
        my $child = Tira->new;
        my $pass = $child->police_pass( project => $root, store => $store, world => {} );
        $child->bridge_write(
            store => $store, project => $root,
            violations => $pass->{violations}, settled => $pass->{settled},
        );
        exit 0;
    }
    push @pids, $pid;
}
close $barrier_read;
close $barrier_write;    # Releases every waiting child at once.

my @bad_exit;
for my $pid (@pids) {
    waitpid( $pid, 0 );
    push @bad_exit, $pid if $? != 0;
}
is( scalar(@bad_exit), 0, 'every racing child exited cleanly' )
  or diag( "child(ren) failed: @bad_exit - a silently-crashing child could make the count below a false green" );

my $lines = $tira->bridge_backlog( store => $store, lines => 1_000_000 );
my @job_due_lines = grep { /job-due/ } @{$lines};

is( scalar(@job_due_lines), 1,
    'one due window, announced exactly once, even with 8 real processes racing the same store' )
  or diag( "bridge log carried @{[ scalar @job_due_lines ]} job-due line(s): @job_due_lines" );

done_testing();

__END__

=head1 NAME

1012-a-window-heard-only-once.t - a due job's window is announced once,
under real concurrent load

=head1 WHY

TKT-1012. His report named repeated Telegram messages for one due
window. Investigated rather than reproduced: two independent dedup
layers (the job-due rule's own $checked ledger, atomic since TKT-995
5.86; violation_record's speak/quiet gate, independently lock-protected)
were traced and confirmed correct, then tested against 8 real forked
processes racing bridge_write on the same store, four times over, with
never more than one job-due line written. His report is dated one day
after TKT-995 shipped and names its exact symptom - the most likely
explanation is his board had not yet received that release.

=head1 WHAT IS ASSERTED

That 8 real, concurrently forked processes running the full production
police_pass -> bridge_write sequence against one store produce exactly
one job-due bridge line for one due window, not one per racing process.

=cut
