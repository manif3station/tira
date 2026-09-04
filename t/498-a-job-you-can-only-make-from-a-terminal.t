#!/usr/bin/env perl
# Creating a repeated job from the page that shows them.
#
# TKT-858, his msg at 16:39 on 2026-09-02: "On the HTML Dashboard. Repeated Job
# section. Add new UI for ..." - filed the same afternoon the five standing
# monitors were migrated onto board-owned jobs, which is what turned that
# section from a read-only curiosity into where he watches them.
#
# THE GAP IS NARROWER THAN THE TITLE. The editor modal, the crontab validation
# and the save route all exist from TKT-839 and TKT-843. What is missing is one
# branch:
#
#     job_save => sub {
#         die "A job id is required\n"
#           if !defined $payload->{id} || $payload->{id} eq '';
#         return $json->encode( $tira->job_update( ... ) );
#     },
#
# It refuses a payload without an id and only ever updates. So a job can be run,
# edited and listed from the page, and created only from a terminal.
#
# WRITTEN RED, before the branch exists.
#
# WHAT THIS DELIBERATELY DOES NOT COVER: the browser. He keeps those - "if you
# are running the browser test. leace it to me. skip the brwoser test" - so this
# covers the contract underneath the control, which is where the behaviour is.
#
# THE ASSERTION THAT MATTERS MOST is not that a job appears. It is that the job
# a browser creates is the SAME RECORD tira.job.add would have made. A create
# path that set its own defaults would give the board two kinds of job that
# differ in ways nobody declared - the two-implementations fault this project
# already shipped once, when the engine and the browser disagreed about
# attachment content types (TKT-713).
#
# WHICH ASSERTIONS ARE ACTUALLY RED: every one that posts a payload with no id.
# The refusal assertions use eval{}, which would pass against a provider that
# does not exist at all, so each establishes its subject first and matches the
# message rather than merely counting a failure.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

require Tira::Job;
require Tira::CLI::Browser;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-02T22:40:00Z'} );
$tira->project_new(
    name => 'Jobbed', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'JBS', epic_prefix => 'JBE', ticket_prefix => 'JBT',
);

my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

# --- the subject exists at all -----------------------------------------------
#
# Established first so the refusal assertions below cannot pass by calling
# nothing: a call to a missing coderef dies exactly as a refusal does.

ok( ref $provider{job_save} eq 'CODE',
    'the page has a provider it saves jobs through' );

my $decode = Tira::json_object();

# --- what he can do today ----------------------------------------------------

my $seed = $tira->job_add(
    project => $root, schedule => '0 * * * *', command => 'd2 tira.police' );
is( $seed->{id}, 'JOB-001', 'a job made from the command line is there to edit' );

{
    my $answer = $provider{job_save}->(
        { id => $seed->{id}, command => 'd2 tira.police.outstanding' } );

    # non-empty is the whole claim: the decode below would throw on empty input
    # and the failure would read as a JSON fault rather than as a provider that
    # answered nothing.
    like( $answer, qr/\S/, 'saving an existing job answers something' );
    my $saved = $decode->decode($answer);
    is( $saved->{command}, 'd2 tira.police.outstanding',
        'and the update path still works, which this card must not break' );
}

# --- what he cannot, and this card is about ----------------------------------

my $before = scalar @{ $tira->job_list( project => $root ) };
is( $before, 1, 'one job on the board before the browser creates one' );

{
    my $answer = eval {
        $provider{job_save}->(
            { schedule => '*/5 * * * *', command => 'd2 tira.police' } );
    };

    # $@ read immediately and asserted on directly: ok(!eval{...}) passes
    # against any failure at all, including a typo in the provider name, so the
    # message is what says WHICH failure happened. Today it is the id refusal.
    is( $@, '', 'a payload with no id is NOT refused - the page can create a job' );

    # non-empty is the whole claim: the create is proved by the assertions
    # below, which read the board rather than the answer. This one only says
    # the provider replied with something instead of an empty body, so an
    # empty answer failing here is exactly the point.
    like( $answer // '', qr/\S/, 'and the provider answers with the job it made' );
}

my $after = $tira->job_list( project => $root );
is( scalar @{$after}, 2, 'the board now carries the job the page created' );

# --- and it is the same record the command line would have made --------------
#
# The point of the card. A browser-created job that differed in its defaults
# would be a second kind of job nobody declared.

{
    my ($made) = grep { $_->{schedule} eq '*/5 * * * *' } @{$after};
    ok( $made, 'the created job is findable by what was asked for' );

    my $reference = $tira->job_add(
        project => $root, schedule => '*/7 * * * *', command => 'd2 tira.police' );

    for my $field (qw(enabled last_run)) {
        is( $made->{$field}, $reference->{$field},
            "a browser-created job's $field matches what tira.job.add sets" );
    }
    like( $made->{id}, qr/\AJOB-\d+\z/,
        'and it is given a real JOB- id from the same counter' );
    isnt( $made->{id}, $seed->{id},
        'distinct from the job that already existed, rather than overwriting it' );
}

# --- the refusals the create path must inherit, not rewrite ------------------
#
# _job_fields owns these. A create path that validated for itself would be the
# second validator this section already refused to grow on TKT-843.

{
    my $count = scalar @{ $tira->job_list( project => $root ) };

    ok( !eval { $provider{job_save}->( { command => 'd2 tira.police' } ); 1 },
        'a payload with no schedule is refused' );
    like( $@, qr/schedule/i,
        'and says the schedule is what is missing, not merely that something failed' );
    is( scalar @{ $tira->job_list( project => $root ) }, $count,
        'and no half-job was written before the refusal' );
}

{
    my $count = scalar @{ $tira->job_list( project => $root ) };

    ok( !eval {
            $provider{job_save}->(
                { schedule => 'monitor', message => 'a monitor that only speaks' } );
            1;
        },
        'a message-mode monitor is refused through the create path too' );

    # The refusal belongs to _job_fields, added on TKT-842 because a monitor
    # with no command can never be found alive in the process table and would
    # be reported dead forever. Matching the message proves the create path
    # INHERITED that rule rather than growing its own weaker one.
    like( $@, qr/monitor|command/i,
        'with the engine\'s own reason, inherited rather than rewritten' );
    is( scalar @{ $tira->job_list( project => $root ) }, $count,
        'and again nothing was written' );
}

# --- a monitor created here is started, because he said so -------------------
#
# Q-109 on TKT-858, answered 2026-09-02T22:37:33+0100: "Create it and start it,
# for monitor-kind only. The page then does what somebody adding a monitor
# obviously meant, at the cost of a save that launches a process."
#
# My own default had been the other way - create it stopped and say so - so this
# is his decision rather than a fallback, and the cost he accepted is that
# saving a form spawns a process. What it buys is that a monitor created on this
# page is not immediately reported dead by monitor-dead, which would be correct
# and baffling for whoever just made it.
#
# STARTED THROUGH run_now, not a spawn written for this path: that executor
# carries the already-running refusal and the spawn/record atomicity fix that
# only came out of review, and a second one would carry neither.

{
    my $made = $decode->decode(
        $provider{job_save}->(
            { schedule => 'monitor', command => "$^X -e 'sleep 30'" } ) );

    is( $made->{schedule_kind}, 'monitor', 'the page created a monitor-kind job' );
    ok( $made->{pid}, 'and it was STARTED - the record carries a pid' );
    ok( $made->{started_at},
        'with the moment it started, which is what monitor-dead compares against' );

    # STOPPED THE WAY THE BOARD STOPS ONE. A monitor is three processes - the shell
# that owns the pipe, the command, and the feeder reading its output - so TERM to
# the recorded pid alone leaves the other two running as orphans. That was
# TKT-920, and these fixtures were written before it: the leak did not fail
# anything, it just left two processes per run holding the test harness's own
# output pipes open, which showed up as `prove -j` hanging with one file
# apparently stuck for ever.
if ( $made->{pid} ) {
    require Tira::CLI::Job;
    Tira::CLI::Job::_signal_monitor($made->{pid});
}
}

# --- and a cron job is not, because there is nothing to start ----------------

{
    my $cron = $decode->decode(
        $provider{job_save}->(
            { schedule => '0 4 * * *', command => 'd2 tira.police' } ) );

    isnt( $cron->{schedule_kind}, 'monitor', 'a cron schedule is not a monitor' );
    ok( !$cron->{pid},
        'and nothing was spawned for it - a cron job runs when due' );
}

# --- a start that fails must not read as a create that failed ----------------
#
# Raised in review. By the time the monitor is started the job is already
# written, so letting run_now's die escape would answer the page with an error
# over a job that exists - and the obvious response to an error on Add is to
# press Add again, which makes a second job. The refusal has to say what
# actually happened.

{
    my $before = scalar @{ $tira->job_list( project => $root ) };

    my $answer = eval {
        $provider{job_save}->(
            { schedule => 'monitor', command => '/nonexistent/monitor/binary' } );
    };
    my $why = $@;

    ok( !defined $answer, 'a monitor that cannot start is reported, not answered with a job' );

    # Asserted on the message rather than merely on failure: the whole point is
    # WHICH failure it says, and ok(!eval{...}) would pass against the create
    # itself breaking.
    like( $why, qr/was created but not started/,
        'and the refusal says the job WAS created' );
    like( $why, qr/tira\.job\.start/,
        'naming what to do about it instead of leaving Add as the obvious retry' );

    is( scalar @{ $tira->job_list( project => $root ) }, $before + 1,
        'the job really is on the board, which is why the message must say so' );
}

done_testing();

__END__

=head1 NAME

498-a-job-you-can-only-make-from-a-terminal.t - creating a repeated job from the board page

=head1 WHY

TKT-858. The Repeated Jobs section can run, edit and list jobs but not create
one, because C<job_save> refuses a payload without an id and only ever calls
C<job_update>. He asked for it the afternoon the standing monitors moved onto
board-owned jobs, which is when the section became the place he watches them.

=head1 WHAT IS ACTUALLY BEING PROVED

Not that a job appears - that a browser-created job is the SAME record
C<tira.job.add> makes, and that the refusals belong to C<_job_fields> rather
than being written a second time for the create path. Two implementations of one
rule is how the engine and the browser came to disagree about attachment content
types on TKT-713.

=head1 NOT COVERED

The browser itself. He keeps those tests.

=cut
