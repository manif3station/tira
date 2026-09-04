#!/usr/bin/env perl
# Running a job now, and refusing a schedule the engine would refuse.
#
# His msg 6484: "Also on the dashboard, each repeated job record has a play
# button. That the user can run them anytime bypass the schedule."
#
# His msg 6485: "Also in the dashboard, the editor job popup modal, for the
# schedule add a tooltips on crontab style scheduler. Also, if the format is
# wrong, will be highlighted red and not letting the user save it until it is
# corrected."
#
# TKT-843. WRITTEN RED, before either exists.
#
# WHAT THIS FILE DOES NOT TEST, deliberately: the browser. He asked to keep
# those - "if you are running the browser test. leace it to me. skip the
# brwoser test" - so this covers the contract underneath the button and the
# modal, which is where the behaviour actually lives. The card stops at the
# browser gate and says so in scope_out.
#
# ONE VALIDATOR, NOT TWO. The modal must refuse a bad cron with the ENGINE's
# own message rather than a second regex written in JavaScript. This project
# already shipped that fault once - the engine and the browser disagreeing
# about attachment content types, TKT-713 - and Tira::CLI::Job's own header
# names this card as the next place the temptation appears. The assertion
# below compares the message the browser layer would show against the message
# Tira::Job::_cron_parse actually dies with, so a second wording cannot pass.
#
# ONE EXECUTOR, NOT TWO. Play is TKT-841's run_due_job with the due-check
# skipped. That executor carries a deadlock fix and a signal-status fix that
# only came out of review; a second one written for a button would carry
# neither.
#
# WHICH ASSERTIONS ARE ACTUALLY RED. All the ones that call something that does
# not exist yet: job.run, and the schedule-check the modal will use. The
# refusal assertions that use eval{} would pass against a missing subroutine
# too - a call to nothing dies just as a refusal does - so each of those first
# establishes that the subject exists, and the die message is matched rather
# than merely counted.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

require Tira::Job;
require Tira::CLI::Job;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-02T12:00:00Z'} );
$tira->project_new(
    name => 'Runnable', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'RNS', epic_prefix => 'RNE', ticket_prefix => 'RNT',
);

# --- the subjects -----------------------------------------------------------

ok( Tira::CLI::Job->can('run_now'),
    'the CLI layer can run one job on demand' );
ok( Tira::Job->can('schedule_refusal'),
    'and the engine can say why a schedule is bad without dying, which is what a modal needs' );

# --- a job that is nowhere near due runs anyway ------------------------------
#
# THE POINT OF THE BUTTON. 03:00 on the first of January is not due at the
# clock above, and that is exactly the case that must run.

my $rare = $tira->job_add(
    project => $root, schedule => '0 3 1 1 *',
    command => 'perl -e print+1',
);
ok( !$tira->job_is_due( $rare, '2026-09-02T12:00:00Z' ),
    'the job is genuinely not due, so "it ran" cannot be the schedule firing' );

my $ran = Tira::CLI::Job::run_now( $tira, { project => $root, id => $rare->{id} } );
is( ( $ran->{ran}  // 0 ), 1, 'running it on demand runs it' );
is( ( $ran->{status} // -1 ), 0, 'and reports the exit status' );
like( ( $ran->{output} // '' ), qr/1/, 'and gives back what it printed' );

# --- a command that fails says so -------------------------------------------
#
# Silence from a job that ran and failed is indistinguishable from a job that
# never ran, which is the ambiguity EPC-014 exists to remove. A button that
# reports nothing on failure rebuilds it in one click.

my $bad = $tira->job_add(
    project => $root, schedule => '0 3 1 1 *',
    command => 'perl -e exit+3',
);
my $failed = Tira::CLI::Job::run_now( $tira, { project => $root, id => $bad->{id} } );
is( ( $failed->{ran} // 0 ), 1, 'a failing command still counts as having run' );
is( ( $failed->{status} // 0 ), 3, 'and its exit status is reported, not swallowed' );

# --- a monitor is STARTED, not fired ----------------------------------------
#
# CHK-001, decided and recorded before this file was written. A monitor has no
# schedule to bypass; the meaningful action on that row is to start it, which
# is what answers the monitor-dead finding printed beside it.

my $monitor = $tira->job_add(
    project => $root, schedule => 'monitor', command => 'perl -e sleep' );

# A REAL clock for the live-process half, and this is not a detail. The frozen
# clock above would record the start as 12:00 while the process really begins
# now, and TKT-842's liveness check compares those two times on purpose - a pid
# whose process started well after the board wrote the record is a REUSED pid,
# not the monitor. With the frozen clock it correctly reads the live process as
# somebody else's, which is the guard working rather than failing. Production
# records the start at the moment of the spawn, so this is what production does.
my $live = Tira->new;
my $started = Tira::CLI::Job::run_now( $live, { project => $root, id => $monitor->{id} } );
ok( $started->{pid}, 'running a monitor on demand STARTS it and records the pid' );
ok( kill( 0, $started->{pid} ), 'and the process is really there' );

# --- and starting one twice does not make two -------------------------------
#
# The defect this card found in TKT-842. job.start refuses a cron job, a
# disabled job and one with no command - and not a monitor that is ALREADY
# RUNNING. Left alone, a second press spawns a twin and overwrites the pid,
# orphaning the first: a process the board has no pid for, invisible to
# monitor-dead. That is the failure this whole epic exists to end, reintroduced
# by the feature built to expose it. One stray click, from a button.

my $again = eval {
    Tira::CLI::Job::run_now( $live, { project => $root, id => $monitor->{id} } );
};
my $refusal = $@ // '';
ok( !$again, 'starting a monitor that is already running is refused' );
like( $refusal, qr/already running|already up/i,
    'and the refusal says why, rather than quietly starting a second one' );

my ($after) = grep { $_->{id} eq $monitor->{id} }
  @{ $tira->job_list( project => $root ) };
is( $after->{pid}, $started->{pid},
    'and the recorded pid is still the first process, not overwritten by a twin' );

# STOPPED THE WAY THE BOARD STOPS ONE. A monitor is three processes - the shell
# that owns the pipe, the command, and the feeder reading its output - so TERM to
# the recorded pid alone leaves the other two running as orphans. That was
# TKT-920, and these fixtures were written before it: the leak did not fail
# anything, it just left two processes per run holding the test harness's own
# output pipes open, which showed up as `prove -j` hanging with one file
# apparently stuck for ever.
require Tira::CLI::Job;
Tira::CLI::Job::_signal_monitor($started->{pid});
waitpid $started->{pid}, 0;

# --- the modal refuses what the engine refuses, in the engine's words -------

my $engine_said = do {
    local $@;
    eval { Tira::Job::_cron_parse('61 * * * *') };
    my $why = $@ // '';
    $why =~ s/\s+\z//;
    $why;
};
ok( length $engine_said, 'the engine really does refuse a minute of 61' );

my $shown = Tira::Job::schedule_refusal('61 * * * *');
ok( defined $shown, 'and the modal is given a refusal to show' );
is( $shown, $engine_said,
    "and it is the engine's own message, not a second wording of it" );

is( Tira::Job::schedule_refusal('*/5 * * * *'), undef,
    'a valid cron gives nothing to complain about' );
is( Tira::Job::schedule_refusal('monitor'), undef,
    "and so does the literal 'monitor', which is a schedule this board accepts" );

# Established the other way round as well, so "no refusal" cannot pass by the
# subroutine simply never finding fault: the valid cases above are only
# meaningful because the invalid one above them really did produce a message.
ok( defined Tira::Job::schedule_refusal('not a schedule at all'),
    'and nonsense is refused, so silence on a good schedule means something' );

# --- the three providers the browser actually calls -------------------------
#
# The page cannot be driven from here - he keeps the browser tests - but the
# providers behind it are ordinary Perl and are exercised directly. Without
# this they were written, wired, documented and never once run: the coverage
# report showed all three at zero while the suite was green, which is the shape
# of a feature that exists only on paper.

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
my $decode = sub { Tira::json_object()->utf8->decode( $_[0] ) };

for my $name (qw(job_run job_check job_save)) {
    is( ref $providers{$name}, 'CODE', "the browser is given a $name provider" );
}

my $checked = $decode->( $providers{job_check}->( { schedule => '61 * * * *' } ) );
ok( !$checked->{ok}, 'job_check refuses a minute of 61' );
is( $checked->{refusal}, $engine_said,
    "and hands back the engine's own words for the page to show" );

my $fine = $decode->( $providers{job_check}->( { schedule => '*/5 * * * *' } ) );
ok( $fine->{ok}, 'and passes a schedule the engine would accept' );
ok( !defined $fine->{refusal}, 'with nothing to complain about' );

my $through = $decode->( $providers{job_run}->( { id => $rare->{id} } ) );
is( $through->{status}, 0, 'job_run runs a job that is not due, through the provider' );

my $saved = $decode->( $providers{job_save}->(
        { id => $rare->{id}, schedule => '30 4 * * *' } ) );
is( $saved->{schedule}, '30 4 * * *', 'job_save writes a corrected schedule' );

# The engine refuses on write what a stale page might have let through. This is
# not distrust of job_check - it is the same rule asked at the moment it
# actually matters, and it is why the modal shows the save's error too.
ok( !eval { $providers{job_save}->( { id => $rare->{id}, schedule => '61 * * * *' } ); 1 },
    'and refuses a bad one on write, whatever the page believed' );

for my $missing ( 'job_run', 'job_save' ) {
    ok( !eval { $providers{$missing}->( {} ); 1 },
        "$missing without an id is refused rather than acting on nothing" );
}

done_testing();

__END__

=head1 NAME

494-a-job-you-can-run-now.t - the play button and the modal's refusal

=head1 WHY THIS FILE EXISTS

TKT-843, from his msgs 6484 and 6485: a play button on every job row that runs
it regardless of schedule, and an editor modal that highlights a malformed
crontab and blocks the save until it is fixed.

=head1 WHAT IT DELIBERATELY DOES NOT COVER

The browser. He asked to keep those tests himself - "if you are running the
browser test. leace it to me. skip the brwoser test" - so this file covers the
contract underneath the button and the modal, which is where the behaviour
lives. The card stops at the browser gate on purpose rather than leaving it
looking unfinished.

=head1 ONE VALIDATOR AND ONE EXECUTOR

C<schedule_refusal> is asserted to return B<the engine's own message>, compared
against what C<_cron_parse> actually dies with, so a second wording written for
the browser cannot pass. C<run_now> is TKT-841's C<run_due_job> without the
due-check, so the deadlock fix and the signal-status fix that review found
there are not left behind by a second executor.

=head1 THE DOUBLE-START ASSERTION

Starting a monitor that is already running used to spawn a twin and overwrite
the recorded pid, orphaning the first process - one the board has no pid for
and C<monitor-dead> cannot see. That is the failure EPC-014 exists to end,
reachable by one stray click once there is a button. Found while deciding what
play should do on a monitor row.

=cut
