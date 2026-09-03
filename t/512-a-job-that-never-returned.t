#!/usr/bin/env perl
# One command that does not come back, and the only channel stops with it.
#
# TKT-864, absorbed into TKT-893, EPC-014. Second of the nine, after TKT-874,
# because the bridge is how every other member of this card is observed - and a
# blocked bridge is not a slow bridge, it is a silent one.
#
# THE FAULT, in lib/Tira/CLI/Police.pm's run_due_job:
#
#     while ( my @ready = $select->can_read ) {
#
# can_read with no argument blocks until a handle is ready. A child that never
# writes and never exits leaves it blocked for ever - waitpid is never reached,
# the police pass never finishes, and NOTHING ELSE IS EVER REPORTED. One
# command-mode job with a hanging command takes the whole board's reporting
# with it.
#
# THE SHAPE IS THE POINT. It fails as a hang: no error, no exit status, no
# output. A wedged bridge and a quiet board look identical from outside, which
# is the exact silence EPC-014 was raised to end - three standing hunts died
# for hours on 2026-09-02 and nothing said so - arriving through the machinery
# built to end it.
#
# AND IT IS THE SECOND HANG FOUND TODAY. t/70 blocks for ever when a documented
# example reads stdin (TKT-896), and this blocks for ever when a job's command
# does not write. Neither fails; both simply stop. That is worth saying twice
# because a suite or a bridge that stops is read as slow, and slow is tolerated.
#
# THE EXISTING CODE ALREADY KNOWS ABOUT ONE DEADLOCK and says so at length: it
# reads both handles as they become ready, because reading stdout to EOF first
# deadlocks against a child filling the stderr pipe. That comment ends "it would
# have looked like a job that never returned, which is precisely the silence
# this card exists to remove." Correct - and the fix it describes removes one
# way to never return, not the general case.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI::Police;

# --- a command that returns promptly is untouched -----------------------------
#
# The common case, and the one a careless timeout breaks. Every job that works
# today must go on working, at the same speed.

{
    my $result = Tira::CLI::Police::run_due_job(
        job => { mode => 'command', command => 'echo hello' } );

    is( $result->{ran}, 1, 'a command that returns is run' );
    is( $result->{status}, 0, 'and its status is reported' );
    like( $result->{output}, qr/hello/, 'and its output is captured' );
}

# --- a command that fails is still a result, not a hang -----------------------

# NO QUOTES IN THIS FIXTURE, and the reason is worth knowing before writing
# one. run_due_job does `split ' ', $job->{command}` and hands the words
# straight to open3 - deliberately, since TKT-851 kept job commands out of a
# shell. So there is nothing to interpret quotes: `sh -c "exit 3"` arrives as
# four literal arguments, two of them carrying a quote character, and the
# command fails for a reason that has nothing to do with this card. The first
# draft of this block did exactly that and failed green-looking.
{
    my $result = Tira::CLI::Police::run_due_job(
        job => { mode => 'command', command => 'perl -e exit(3)' } );

    is( $result->{status}, 3, 'a non-zero exit is reported as itself' );
}

# --- AND A COMMAND THAT NEVER RETURNS IS GIVEN UP ON --------------------------
#
# `sleep 60` writes nothing and exits nothing, which is exactly the shape that
# blocks can_read. If this test hangs rather than fails, the fault is present
# and this file has demonstrated it the hard way - so it is bounded from the
# outside too, and the bound is deliberately far shorter than the sleep.

{
    my $started = time;
    my $result;

    # any failure is what this means. The eval is not checking a refusal - it is
    # the outer bound on a HANG, and the only way out of it is the alarm. If the
    # call blocks, this dies; if the call throws for some other reason, that is
    # equally a run_due_job that did not return a result, which is the thing
    # being asserted. There is no refusal message to name because a hang does
    # not produce one - which is the whole complaint of this card.
    my $died = !eval {
        local $SIG{ALRM} = sub { die "still blocked after 20s\n" };
        alarm 20;
        $result = Tira::CLI::Police::run_due_job(
            job => {
                mode        => 'command',
                command     => 'sleep 60',
                run_timeout => 2,
            } );
        alarm 0;
        1;
    };
    my $why = $@;
    alarm 0;

    ok( !$died, 'run_due_job returns on a command that never does' )
      or diag("it did not: $why");

    cmp_ok( time - $started, '<', 20,
        'and it returns in something like the timeout it was given, rather '
          . 'than the sixty seconds the command wanted' );

    # non-empty is the whole claim: every assertion below reads this result, and
    # an undef one - which is what a hang leaves behind - would fail them for
    # the wrong reason.
    ok( ref $result eq 'HASH', 'with a result to inspect' );

    isnt( ( $result || {} )->{status}, 0,
        'A TIMED-OUT JOB IS NOT A SUCCESS. This is the inversion the existing '
          . 'code already guards against for signals - a job the system killed '
          . 'read as having exited cleanly - and a timeout must not reintroduce '
          . 'it by returning 0 for a command that never finished' );

    # non-empty is the whole claim: a bridge that finishes the pass and says
    # nothing about this job is indistinguishable from one reporting a job that
    # ran cleanly, so "there is any text at all" is exactly what is being
    # asserted here. What the text SAYS is the next block's assertion.
    like( ( $result || {} )->{output} // '', qr/\S/,
        'and it says something, because the bridge reporting nothing is the '
          . 'silence this whole epic exists to end' );
}

# --- and the bridge is told what happened ------------------------------------
#
# A timeout that is silent would swap a hang for a lie: the pass would finish,
# report nothing about this job, and look exactly like a job that ran cleanly.

{
    my $result = Tira::CLI::Police::run_due_job(
        job => {
            mode        => 'command',
            command     => 'sleep 60',
            run_timeout => 2,
        } );

    like( ( $result || {} )->{output} // '', qr/timed out|timeout/i,
        'the output names the timeout, so a reader of the bridge can tell a '
          . 'job that was given up on from one that failed on its own terms' );
}

done_testing();

__END__

=head1 NAME

512-a-job-that-never-returned.t - a hanging command, and the channel it blocks

=head1 WHY

TKT-864, inside TKT-893. C<run_due_job> calls C<< $select->can_read >> with no
timeout, so a command that neither writes nor exits blocks the police pass for
ever. The bridge is the single reporting path, so one bad job silences
everything.

=head1 WHAT IS ASSERTED

That a prompt command is unaffected in result, status and output; that a failing
one still reports its status; that a command which never returns is given up on
and returns in about the time it was allowed; that the result is NOT a success,
since a timeout returning 0 would rebuild the failure-looks-like-success
inversion the signal handling already guards against; and that the output names
the timeout, so the bridge can tell a job given up on from one that failed on
its own terms.

=cut
