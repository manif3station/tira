#!/usr/bin/env perl
# tira.job.feed waits for ever on a job that does not exist.
#
# TKT-928, EPC-014. Found live: TKT-917's coverage gate ran twenty-one minutes
# with t/70-doc-examples.t stuck, burning one CPU tick in twenty seconds, sitting
# in poll_schedule_timeout with prove's standard input on fd 0.
#
# THE VERB NEVER LOOKS THE JOB UP. lib/Tira/CLI/Job.pm:
#
#   my $id = $args->{id} // '';
#   die "A job id is required - which monitor is speaking?\n" if $id eq '';
#   ...
#   $watch->add( \*STDIN );
#   while (1) {
#       if ( !$watch->can_read($QUIET_AFTER_SECONDS) ) { $flush->(); next; }
#       my $line = <STDIN>;
#       last if !defined $line;
#       ...
#   }
#
# An EMPTY id is refused. A NONEXISTENT one is not. With nothing arriving, the
# loop takes the timeout branch, flushes an empty batch, and goes round again -
# for ever, never touching the job record and never discovering the job is gone.
#
# AND IT IS A DOCUMENTED EXAMPLE. SKILLS.md carries `tira.job.feed --id ID`, and
# t/70-doc-examples.t runs every documented example in-process. So the suite runs
# this verb against a job called "ID" on a fixture board, and hangs whenever
# prove hands that worker a standard input that stays open.
#
# REPRODUCED IN A perl-test CONTAINER before this was written, with stdin held
# open and silent the way prove holds one:
#
#   timeout 20 perl probe.pl < <(sleep 60)
#   calling job.feed --id ID on a board with no such job
#   EXIT: 124        <- timed out; it never returned
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

my ( $tira, $root, $monitor, $cron );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Feed', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'FDS', epic_prefix => 'FDE', ticket_prefix => 'FDT',
    );
    $monitor = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller', author => 'claude' );
    $cron = $tira->job_add( project => $root, schedule => '*/30 * * * *',
        command => 'a-cron-job', author => 'claude' );
}

# STANDARD INPUT IS HELD OPEN AND SILENT, which is the whole point and is what
# a first version of this file got wrong. Under prove, a worker's stdin is
# sometimes already at end of file - and then <STDIN> returns undef, the loop
# ends, and the bug does not appear. That is exactly why the suite hung only
# sometimes, and a test inheriting prove's stdin would pass for the wrong reason.
#
# So the test supplies its own: a pipe whose write end is kept open for the
# duration, which is the state prove leaves a worker in when it hangs.
#
# AND AN ALARM AROUND EVERY CALL, because the fault is a HANG. Without it a red
# run of this file would block the suite rather than fail it - which is the very
# thing the card is about.
sub feeding {
    my (@argv) = @_;
    my $out = '';
    my $err = '';
    my $timed_out = 0;

    pipe my $reader, my $writer or die "pipe: $!";
    {
        local *STDIN = $reader;
        local $SIG{ALRM} = sub { $timed_out = 1; die "TIMED OUT\n" };
        open my $capture, '>', \$out or die $!;
        my $old = select $capture;
        local *STDERR = $capture;
        eval {
            alarm 5;
            Tira::CLI::Job::dispatch( $tira, { project => $root, @argv },
                {}, 'job.feed' );
            alarm 0;
            1;
        } or do { $err = $@ // ''; alarm 0 };
        select $old;
        close $capture;
    }
    close $writer;
    close $reader;
    return ( $timed_out, $err );
}

# --- an id that names nothing is refused, not waited on -----------------------

{
    my ( $hung, $why ) = feeding( id => 'NOSUCHJOB' );

    ok( !$hung,
        'FEEDING A JOB THAT DOES NOT EXIST RETURNS. Today it does not: the verb '
          . 'adds standard input to a watcher and loops on a two-second poll for '
          . 'ever, never looking the job up. That is what hung the coverage gate '
          . 'for twenty-one minutes' );

    like( $why, qr/NOSUCHJOB/,
        'and the refusal NAMES the id, because somebody who got here typed it' );
}

# --- an empty id is still refused, as it already was --------------------------
#
# The control. This is the one case the verb DID check, and a fix that replaced
# the check rather than adding to it would pass the assertion above and lose this.

{
    my ( $hung, $why ) = feeding( id => '' );

    ok( !$hung, 'an empty id still returns rather than waiting' );
    like( $why, qr/job id is required/,
        'and still says a job id is required - the check that was already there '
          . 'is added to, not replaced' );
}

# --- a cron job is refused too ------------------------------------------------
#
# Nothing feeds on a cron job's behalf: it is not up between runs. job_started
# already refuses to record a pid for one for the same reason, and a feed
# against one is a mistake somebody wants told about rather than a wait.

{
    my ( $hung, $why ) = feeding( id => $cron->{id} );

    ok( !$hung, 'feeding a CRON job returns rather than waiting' );
    like( $why, qr/cron/i,
        'and says so - a cron job is not up between runs, so nothing is feeding '
          . 'on its behalf' );
}

# --- and a real monitor is still fed ------------------------------------------
#
# THE ASSERTION THAT STOPS THE FIX GOING TOO FAR. The loop exists as it does
# because of TKT-851: a monitor that speaks rarely must be heard within seconds,
# so the wait is bounded and whatever is held is flushed on the timeout. A fix
# that refused its way out of the loop, or moved the lookup inside it, would
# take that back.

{
    my $before = ( grep { $_->{id} eq $monitor->{id} }
          @{ $tira->job_list( project => $root ) } )[0];

    # non-empty is the whole claim: if the monitor were not there, "it is still
    # fed" would be vacuous.
    ok( $before, 'the monitor is on the board to be fed' );

    $tira->job_feed( project => $root, id => $monitor->{id},
        lines => ['a line the monitor said'] );

    my $after = ( grep { $_->{id} eq $monitor->{id} }
          @{ $tira->job_list( project => $root ) } )[0];

    is( scalar @{ $after->{output} || [] }, 1,
        'and feeding it still records what it said - the engine half is '
          . 'untouched by this card' );

    ok( $after->{last_output_at},
        'and stamps when it called in' );
}

# --- the loop's shape is unchanged --------------------------------------------
#
# Source-read, and narrow. TKT-851's bounded wait is the reason a monitor that
# speaks once an hour is heard in seconds rather than after twenty-five lines,
# and it is the thing a careless fix here would remove.

my $source = do {
    open my $fh, '<:encoding(UTF-8)', 'lib/Tira/CLI/Job.pm' or die "Job.pm: $!";
    local $/;
    <$fh>;
};

my ($feed) = $source =~ /(if \s* \( \s* \$command \s+ eq \s+ 'job\.feed' .*? \n \s{4} \})/xs;

ok( defined $feed && length $feed, 'the job.feed branch was extracted' );

like( $feed // '', qr/can_read\(\s*\$QUIET_AFTER_SECONDS/,
    'the bounded wait survives - a monitor that speaks rarely is still heard '
      . 'within seconds, which is what TKT-851 put it there for' );

like( $feed // '', qr/\$flush->\(\)/,
    'and so does the flush on that timeout, which is the half that makes the '
      . 'bound useful rather than merely short' );

done_testing();

__END__

=head1 NAME

535-a-feed-for-a-job-that-is-not-there.t - job.feed and a job id that names nothing

=head1 WHY

TKT-928. C<tira.job.feed> refuses an B<empty> job id and accepts a B<nonexistent>
one, then watches standard input for ever without ever looking the job up. It is
a documented example, so F<t/70-doc-examples.t> runs it in-process against a job
called C<ID> - and the suite hangs whenever C<prove> hands that worker a standard
input that stays open. It cost two gate runs, twenty-one and twenty-nine minutes.

=head1 WHAT IS ASSERTED

That a nonexistent id returns and names itself; that an empty one still does, so
the existing check is added to rather than replaced; that a cron job is refused
for the reason C<job_started> already refuses one; that a real monitor is still
fed; and that TKT-851's bounded wait and its timeout flush both survive.

Every call is wrapped in an alarm, because the fault is a B<hang>: without that,
a red run of this file would block the suite rather than fail it.

=cut
