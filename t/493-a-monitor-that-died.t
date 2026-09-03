#!/usr/bin/env perl
# A monitor-kind job whose death is noticed.
#
# His msg 6487: "If the user use the scheduler like monitor instead of crontab
# scheduler string on the dashboard or in command line that is kind of a poller
# like TG poller or the TG bridge. I want all the existing running monitors
# handled by this new feature."
#
# TKT-836 made the schedule field accept the literal 'monitor' and recorded
# schedule_kind; TKT-839 showed it on the dashboard. Neither starts one, and
# nothing anywhere notices when one stops. This is that card. TKT-842.
#
# WRITTEN RED, before any liveness check exists.
#
# WHY DEATH IS THE POINT. On 2026-09-02 three hunt loops died and produced
# exactly what three quiet ones produce: nothing. The acceptance criterion says
# it outright - "a monitor whose death is silent fails this ticket" - so the
# assertion this file exists for is the one on line "a stopped monitor is
# reported, by name". Every other assertion here is scaffolding around it.
#
# HOW LIVENESS IS KNOWN, decided on the card as CHK-001 before this file was
# written: a pid recorded on the job when the monitor starts, CONFIRMED by a
# process-table match on that pid's command. pid narrows, command confirms.
# Bare `kill 0` on a stored pid is the board's own precedent
# (police_claim_singleton) and is rejected as sufficient here, because a reused
# pid reports a dead monitor as ALIVE - the exact fooling this card forbids.
# That rejection is not decoration: the "a reused pid is not the monitor"
# assertion below is what makes the choice mean anything, and it is the one
# assertion that a bare-pid implementation would fail.
#
# WHICH ASSERTIONS ARE ACTUALLY RED, stated because a negative assertion passes
# happily against absent code and this project has shipped four vacuous red
# tests already. Red now: the two `can` subjects, the rule being known at all,
# and the three that demand a violation FIRES. The three "stays quiet"
# assertions pass trivially today - a rule that does not exist reports nothing
# about anything - so they are meaningful only once the fires-assertions are
# green, and they are placed after them for that reason.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $tmp   = File::Temp::tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catdir( $tmp, 'store' );

my $tira = Tira->new( clock => sub {'2026-09-02T12:00:00Z'} );
$tira->project_new(
    name => 'Watched', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'WAS', epic_prefix => 'WAE', ticket_prefix => 'WAT',
);

# --- the subjects, established before anything is asserted about silence -----
#
# Required explicitly. Tira loads Tira::Job lazily - every job verb is a
# forwarder that requires it at the call site - so asking an unloaded package
# what it can do answers no, whatever it contains. Asserting on that would
# have been a test of the loading strategy wearing the name of a test about
# monitors.
require Tira::Job;

ok( Tira::Job->can('job_monitor_alive'),
    'the engine can say whether a monitor-kind job is actually running' );
ok( Tira::Job->can('job_started'),
    'and a monitor can record that it started, which is where the pid comes from' );

my $known = eval {
    my $policy = $tira->policy_add(
        project => $root, rule => 'monitor-dead', action => 'log-only' );
    $tira->policy_remove( project => $root, id => $policy->{id} );
    1;
} || 0;
ok( $known, 'the board knows a monitor-dead rule at all' )
  or diag( "policy_add refused it: " . ( $@ || 'no error' ) );

# --- an age is refused, not ignored -----------------------------------------
#
# The rule declares forbids => ['age'], and t/79 requires every rule that
# forbids an option to have a test that actually GIVES it that option - a
# declaration nobody exercises is a promise, not a guarantee.
#
# Why it forbids one at all: the acceptance asks for a dead monitor to be
# visible "within one bridge pass, rather than after somebody notices the
# silence". A grace period is that silence, spelled as policy. Refusing the
# option rather than quietly dropping it is this board's habit everywhere -
# a policy police cannot follow reads as cover.

ok( !eval {
        $tira->policy_add( project => $root, rule => 'monitor-dead',
            action => 'log-only', age => '30m' );
        1;
    },
    'monitor-dead refuses an age rather than ignoring one' );

# --- the jobs -----------------------------------------------------------------

my $monitor = $tira->job_add(
    project => $root, schedule => 'monitor',
    command => 'tira-monitor-under-test --poll',
);
is( $monitor->{schedule_kind}, 'monitor',
    'a monitor-kind job is what TKT-836 already stores' );

my $cron = $tira->job_add(
    project => $root, schedule => '*/5 * * * *',
    command => 'tira-cron-under-test --once',
);
is( $cron->{schedule_kind}, 'cron', 'and a cron-kind job beside it, to be left alone' );

# The pid a started monitor would carry. Recorded through the engine rather
# than written into the file, so the test exercises the path the CLI will use
# when it spawns one.
my $pid = 424242;
eval { $tira->job_started( project => $root, id => $monitor->{id}, pid => $pid ); 1 }
  or diag( "job_started refused: " . ( $@ || 'no error' ) );

sub violations {
    my (%args) = @_;
    my $policy = eval {
        $tira->policy_add(
            project => $root, rule => 'monitor-dead', action => 'log-only' );
    };
    return [] if !$policy;
    my $result = $tira->police_pass(
        project => $root, store => $store, world => $args{world} );
    $tira->policy_remove( project => $root, id => $policy->{id} );
    return $result->{violations};
}

# The process start matches what job_started recorded, because that is the only
# thing that can be true: the board writes started_at immediately after the
# spawn. An earlier fixture here had them an HOUR apart, which cannot happen -
# a process that began before we spawned ours could not have been handed our
# pid while it was still alive. TKT-860 made the start times authoritative, and
# a fixture that disagreed with reality would have hidden that.
my $alive_row = {
    pid => $pid, started_at => '2026-09-02T12:00:00Z',
    command => 'tira-monitor-under-test --poll',
};
my $unrelated = {
    pid => 999001, started_at => '2026-09-02T11:00:00Z',
    command => 'something-else-entirely --run',
};

# --- a stopped monitor is reported, by name ---------------------------------
#
# THE ASSERTION THIS FILE EXISTS FOR. The pid is on the record and the process
# is gone from the table. Nothing else on this board would ever mention it.

my $stopped = violations( world => { processes => [$unrelated] } );
is( scalar @{$stopped}, 1, 'a monitor that has stopped is reported' );
like( ( $stopped->[0]{detail} // '' ), qr/\Q$monitor->{id}\E/,
    'and is named, so the message says WHICH monitor died' );
like( ( $stopped->[0]{detail} // '' ), qr/\Qtira-monitor-under-test\E/,
    'and says what it was supposed to be running' );

# --- a reused pid is not the monitor ----------------------------------------
#
# The case that makes the CHK-001 decision worth making. The pid is alive - a
# bare `kill 0` would say the monitor is fine - but the process wearing it is
# somebody else's. A dead monitor reported as alive is the silent death this
# card forbids, so this must still fire.

my $reused = violations(
    world => { processes => [ { %{$unrelated}, pid => $pid } ] } );
is( scalar @{$reused}, 1,
    'a pid that has been reused by another process is not a living monitor' );

# --- a monitor that was never started ---------------------------------------

my $never = $tira->job_add(
    project => $root, schedule => 'monitor',
    command => 'tira-never-started --poll',
);
my $unstarted = violations( world => { processes => [$alive_row] } );
is( scalar @{$unstarted}, 1,
    'an enabled monitor that was never started is reported too, having no pid' );
like( ( $unstarted->[0]{detail} // '' ), qr/\Q$never->{id}\E/,
    'and it is the never-started one that is named, not the running one' );
$tira->job_delete( project => $root, id => $never->{id} );

# --- a running monitor is left alone ----------------------------------------
#
# Meaningful only because the three assertions above prove the rule can fire.

my $running = violations( world => { processes => [ $alive_row, $unrelated ] } );
is( scalar @{$running}, 0, 'a monitor that is running is not reported' );

# --- a cron-kind job is not a dead monitor ----------------------------------
#
# A cron job is not supposed to be up between runs. Reporting one would make
# the rule noise, and a channel that cries every five minutes is one nobody
# reads - which is how the original silence got missed.

my $cron_quiet = violations( world => { processes => [$alive_row] } );
is( scalar @{$cron_quiet}, 0,
    'a cron-kind job that is not running is not a death' );

# --- a disabled monitor is not a death --------------------------------------
#
# Established against the same job that fired above: it was reported when
# enabled, so silence here is the enabled flag being read, not the rule being
# broken.

# STOPPED FIRST, which the board began requiring in TKT-893. Disabling a
# monitor the board still has a pid for is refused, because monitor-dead is
# deliberately silent about a disabled monitor - so disabling one that is
# running is the single change that hides a live process in both directions at
# once (TKT-870). The engine cannot tell a stale pid from a live one, so the
# refusal fires on this fixture's invented pid too, and job_stop is how a record
# pointing at a process nobody is responsible for is cleared either way.
$tira->job_stop( project => $root, id => $monitor->{id} );
$tira->job_update( project => $root, id => $monitor->{id}, enabled => 0 );
my $disabled = violations( world => { processes => [$unrelated] } );
is( scalar @{$disabled}, 0,
    'a disabled monitor is absent on purpose, and its absence is not reported as a death' );

# --- starting one, which is where a pid comes from at all -------------------
#
# Without this the liveness check guards a state nothing on the board can
# produce: no pid is ever recorded, every enabled monitor reads as dead, and
# the rule that was written to end a silence becomes a rule that cries every
# pass. So the CLI half is exercised here rather than left for the card that
# migrates the real monitors.

require Tira::CLI::Job;

$tira->job_update( project => $root, id => $monitor->{id}, enabled => 1 );

# A monitor's output no longer has "somewhere to go" - it goes THROUGH the
# feeder to the job record. TKT-851, his Q-112 answer. The assertion that used
# to stand here checked the per-job log path, which is the thing his original
# instruction said should not exist; it is gone with the file it named, and
# t/503 asserts what replaced it.
ok( Tira::Job->can('job_feed'),
    'a monitor has somewhere for its output to go - the job record it is '
      . 'registered against, rather than a log beside it' );

# perl -e sleep, and not "sleep 30": the command is split on whitespace, so an
# argument with a space in it is two arguments. Bare sleep with no argument
# sleeps until killed, which is what a monitor does.
my $started = $tira->job_update(
    project => $root, id => $monitor->{id}, command => 'perl -e sleep' );
my $ran = Tira::CLI::Job::dispatch(
    $tira, { project => $root, id => $monitor->{id} }, {}, 'job.start' );

ok( $ran->{pid}, 'starting a monitor records the pid it started as' );
ok( kill( 0, $ran->{pid} ), 'and the process is really there' );

# started_at taken from the record rather than written by hand: this monitor was
# started with a REAL clock a moment ago, so the only stamp that matches it is
# its own. TKT-860.
my $live = [ { pid => $ran->{pid}, started_at => $ran->{started_at},
        command => 'perl -e sleep' } ];
ok( Tira::Job::job_monitor_alive( $ran, $live ),
    'a monitor started this way reads as alive' );

my $watched = violations( world => { processes => $live } );
is( scalar @{$watched}, 0, 'and police says nothing about it' );

kill 'TERM', $ran->{pid};
waitpid $ran->{pid}, 0;

my $after = violations( world => { processes => [$unrelated] } );
is( scalar @{$after}, 1,
    'kill it, and the very next pass reports it - the whole card, end to end' );

# --- the refusals -----------------------------------------------------------

my %refused = (
    'a cron job is not started, it runs when due' => sub {
        Tira::CLI::Job::dispatch(
            $tira, { project => $root, id => $cron->{id} }, {}, 'job.start' );
    },
    'a job that is not on the board' => sub {
        Tira::CLI::Job::dispatch(
            $tira, { project => $root, id => 'JOB-999' }, {}, 'job.start' );
    },
    'a pid on a cron job, which would be a fact about an exited process' => sub {
        $tira->job_started( project => $root, id => $cron->{id}, pid => 4242 );
    },
    'job_started without a pid' => sub {
        $tira->job_started( project => $root, id => $monitor->{id} );
    },
    'job_started with something that is not a pid' => sub {
        $tira->job_started( project => $root, id => $monitor->{id}, pid => 'soon' );
    },
    'job_started without an id' => sub {
        $tira->job_started( project => $root, pid => 4242 );
    },
    'feeding output without an id' => sub {
        $tira->job_feed( project => $root, lines => ['orphaned'] );
    },
    'draining output without an id' => sub {
        Tira::Job::job_output_drain( $tira, project => $root );
    },
);
for my $why ( sort keys %refused ) {
    ok( !eval { $refused{$why}->(); 1 }, "refused: $why" );
}

# A monitor whose command is not a program is a result, not a crash - the same
# judgement run_due_job makes about a command that is not there.
#
# STOPPED FIRST, for the reason given above: since TKT-893 the board refuses to
# change the command of a monitor it still holds a pid for, because the pid
# would go on running the old one while the record named the new. This fixture
# recorded a pid earlier in the file, so it has to let go of it before editing.
$tira->job_stop( project => $root, id => $monitor->{id} );
$tira->job_update(
    project => $root, id => $monitor->{id},
    command => 'tira-no-such-program-anywhere' );
ok( !eval {
        Tira::CLI::Job::dispatch(
            $tira, { project => $root, id => $monitor->{id} }, {}, 'job.start' );
        1;
    },
    'a monitor whose command does not exist is refused, naming it' );

# STOPPED FIRST, which the board began requiring in TKT-893. Disabling a
# monitor the board still has a pid for is refused, because monitor-dead is
# deliberately silent about a disabled monitor - so disabling one that is
# running is the single change that hides a live process in both directions at
# once (TKT-870). The engine cannot tell a stale pid from a live one, so the
# refusal fires on this fixture's invented pid too, and job_stop is how a record
# pointing at a process nobody is responsible for is cleared either way.
$tira->job_stop( project => $root, id => $monitor->{id} );
$tira->job_update( project => $root, id => $monitor->{id}, enabled => 0 );
ok( !eval {
        Tira::CLI::Job::dispatch(
            $tira, { project => $root, id => $monitor->{id} }, {}, 'job.start' );
        1;
    },
    'refused: a disabled monitor is not started' );

# --- a jobs record that cannot be read says so -------------------------------
#
# Raised in review. The rule used to read the jobs with `eval { ... } || []`,
# so a locked or corrupt file became "there are no monitors" and every death
# went unreported for that pass, silently. That is this card's own thesis
# broken inside its own implementation: silence standing in for an answer.
# The failure is reported instead.

{
    no warnings 'redefine';
    my $real = \&Tira::job_list;
    local *Tira::job_list = sub { die "jobs.json is locked by another process\n" };
    my $broken = violations( world => { processes => [] } );
    is( scalar @{$broken}, 1, 'a jobs record that cannot be read produces a finding' );
    like( ( $broken->[0]{detail} // '' ), qr/could not be read/,
        'and the finding says so, rather than the pass going quiet' );
    like( ( $broken->[0]{detail} // '' ), qr/locked by another process/,
        'and carries the reason, which is the part somebody can act on' );
}

# --- a monitor that starts but cannot be recorded ---------------------------
#
# Also from review. open3 returns a running process; the pid reaches the board
# on the next line. If that write fails, the old code left a LIVE monitor the
# board had no pid for - reported dead every pass by this very rule, and
# started a second time by the next job.start. The child is killed instead, so
# the caller is left with nothing running and something to retry.

{
    my $startable = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'perl -e sleep' );
    no warnings 'redefine';
    local *Tira::job_started = sub { die "could not write the jobs record\n" };

    ok( !eval {
            Tira::CLI::Job::dispatch(
                $tira, { project => $root, id => $startable->{id} }, {}, 'job.start' );
            1;
        },
        'a monitor that starts but cannot be recorded is a failure, not a success' );
    like( ( $@ // '' ), qr/stopped again rather than left running unrecorded/,
        'and the refusal says the process was stopped rather than orphaned' );

    my ($after) = grep { $_->{id} eq $startable->{id} }
      @{ $tira->job_list( project => $root ) };
    ok( !$after->{pid}, 'and no pid was left on the record' );
    $tira->job_delete( project => $root, id => $startable->{id} );
}

# --- the liveness check on its own ------------------------------------------

ok( !Tira::Job::job_monitor_alive( undef, [] ), 'nothing is not alive' );
ok( !Tira::Job::job_monitor_alive( $cron, [] ),
    'a cron job is never asked to be alive' );
ok( !Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => '', command => 'x' }, [] ),
    'a monitor with an empty pid is not alive' );
ok( !Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => 7, command => 'x' },
        [ { pid => 9, command => 'x' } ] ),
    'a pid that is not in the table is not alive' );
ok( !Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => 7, command => '' },
        [ { pid => 7, command => 'anything' } ] ),
    'a monitor with nothing to run has nothing to be alive as' );

# --- a monitor that announces instead of running ----------------------------
#
# Found reading this diff, not by a failing test, and it would have shipped as
# noise rather than as an error. A job could be created with schedule =>
# 'monitor' and a MESSAGE, and such a record can do nothing at all: never due,
# so job-due never speaks for it; refused by job.start for having nothing to
# run; and no command for the liveness check to look for. It would have been
# reported dead on every pass forever - a rule written to end a silence turned
# into one that cries about a record nobody can fix except by deleting it.
#
# Refused at the point of writing, and separately survivable if a board already
# carries one. Both halves are asserted, because refusing new ones does not
# clean up old ones.

ok( !eval {
        $tira->job_add( project => $root, schedule => 'monitor',
            message => 'a monitor cannot announce anything' );
        1;
    },
    'a monitor with a message instead of a command is refused when it is written' );
like( ( $@ // '' ), qr/monitor.*runs a command|--command/i,
    'and the refusal says what to give instead' );

ok( !Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => 7,
            message => 'not a thing any process is running' },
        [ { pid => 7, command => 'not a thing any process is running' } ] ),
    'a message is never matched against a process, even when the text lines up' );

{
    # A record written before the refusal existed, put on disk the way an old
    # board would carry it, so the rule is tested against the thing it has to
    # survive rather than against a hypothetical.
    my $legacy = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'tira-legacy-placeholder' );
    my $path = File::Spec->catfile( $root, '.tira', 'jobs.json' );
    open my $in, '<:raw', $path or die "cannot read jobs: $!";
    my $body = do { local $/; <$in> };
    close $in;
    $body =~ s/"tira-legacy-placeholder"/null/;
    open my $out, '>:raw', $path or die "cannot write jobs: $!";
    print {$out} $body;
    close $out;

    my $quiet = violations( world => { processes => [$unrelated] } );
    my @named = grep { ( $_->{detail} // '' ) =~ /\Q$legacy->{id}\E/ } @{$quiet};
    is( scalar @named, 0,
        'a commandless monitor already on disk is skipped, not reported every pass' );
    $tira->job_delete( project => $root, id => $legacy->{id} );
}

# --- a pid reused by the SAME command, which start times settle -------------
#
# Raised in review, and it is the sharpest version of this card's failure: the
# monitor died, its pid was taken by a process whose argv carries the same
# text - the same command started again by hand is the obvious way - and the
# containment check says alive. The death then goes unreported, which the
# acceptance forbids outright.
#
# The one fact that separates them is WHEN. A reused pid started later than the
# pid we recorded, so the stamps are compared rather than left unread.

my $recorded_at = '2026-09-02T12:00:00';
my $reused_job  = { schedule_kind => 'monitor', pid => 5150,
    command => 'tira-monitor-under-test --poll', started_at => $recorded_at };

ok( Tira::Job::job_monitor_alive( $reused_job,
        [ { pid => 5150, started_at => $recorded_at,
                command => 'tira-monitor-under-test --poll' } ] ),
    'the process we started, at the time we recorded, is alive' );

ok( !Tira::Job::job_monitor_alive( $reused_job,
        [ { pid => 5150, started_at => '2026-09-02T14:30:00',
                command => 'tira-monitor-under-test --poll' } ] ),
    'the same command on the same pid, started hours later, is NOT that monitor' );

ok( Tira::Job::job_monitor_alive( $reused_job,
        [ { pid => 5150, started_at => '2026-09-02T12:00:30',
                command => 'tira-monitor-under-test --poll' } ] ),
    'and a few seconds of slack is allowed, since the pid is recorded after the spawn' );

ok( Tira::Job::job_monitor_alive(
        { %{$reused_job}, started_at => undef },
        [ { pid => 5150, started_at => '2026-09-02T14:30:00',
                command => 'tira-monitor-under-test --poll' } ] ),
    'with no recorded time the check falls back rather than guessing a death' );

is( Tira::Job::_stamp_seconds('not a timestamp'), undef,
    'a stamp that carries no time is refused rather than read as zero' );

# --- Windows, where the process table has no command line -------------------
#
# `tasklist /fo csv /nh` reports the process NAME and no command line, so the
# substring match every other platform uses can never succeed there. Left
# alone, that would have reported every running monitor on Windows as dead -
# a rule against silence turned into a rule that cries constantly, which gets
# read past exactly the same way. Asserted on both settings of the flag so the
# platform difference is proved rather than assumed.

my $windows_job = { schedule_kind => 'monitor', pid => 7,
    command => 'perl -e sleep' };
my $tasklist = [ { pid => 7, command => 'perl.exe', started_at => undef } ];

{
    local $Tira::WINDOWS = 0;
    ok( !Tira::Job::job_monitor_alive( $windows_job, $tasklist ),
        'off Windows a bare program name is not accepted as the command' );
}
{
    local $Tira::WINDOWS = 1;
    ok( Tira::Job::job_monitor_alive( $windows_job, $tasklist ),
        'on Windows the program name is matched, since it is all tasklist gives' );
    ok( !Tira::Job::job_monitor_alive( $windows_job,
            [ { pid => 7, command => 'notepad.exe', started_at => undef } ] ),
        'and a different program on that pid is still a dead monitor' );
    ok( Tira::Job::job_monitor_alive(
            { %{$windows_job}, command => 'C:\\strawberry\\perl\\bin\\perl.exe -e sleep' },
            $tasklist ),
        'a full path and a .exe on either side still name the same program' );

    # Against what the real parser produces, not against a hash shaped by hand
    # to suit the matcher. The two halves have to fit each other, and a test
    # that builds its own input proves only that the matcher matches itself.
    # This stands in for the Windows lab, which cannot be booted today - see
    # tickets/TESTING.md - and it is the half a lab would not have caught
    # faster anyway.
    require Tira::CLI::Serve;
    my $real = Tira::CLI::Serve::_processes_from_windows( [
        '"perl.exe","4321","Console","1","52,000 K"',
        '"prove.exe","4322","Console","1","9,000 K"',
    ] );
    ok( Tira::Job::job_monitor_alive(
            { schedule_kind => 'monitor', pid => 4321, command => 'perl -e sleep' },
            $real ),
        'a monitor is found alive in output the real tasklist parser produced' );
    ok( !Tira::Job::job_monitor_alive(
            { schedule_kind => 'monitor', pid => 4322, command => 'perl -e sleep' },
            $real ),
        'and prove.exe on another pid is not that monitor' );
}

done_testing();

__END__

=head1 NAME

493-a-monitor-that-died.t - a monitor-kind job whose death is noticed

=head1 WHY THIS FILE EXISTS

On 2026-09-02 three standing hunt loops on this board had been dead for hours
and nothing said so, because a loop that has stopped and a loop with nothing to
report produce identical output: none. EPC-014 was filed for that, and this is
the card that ends it. The acceptance criterion is unusually blunt - "a monitor
whose death is silent fails this ticket" - so the assertion this file is for is
the one that kills a real process and demands the next police pass name it.

=head1 WHICH ASSERTIONS WERE ACTUALLY RED

Nine of the first fourteen: both C<can> subjects, the rule being unknown to the
engine, and every assertion demanding a violation fire. The three "stays quiet"
assertions - a running monitor, a cron job, a disabled monitor - B<passed
before any code existed>, because a rule that does not exist reports nothing
about anything. They are meaningful only once the fires-assertions are green,
and they are placed after them for that reason.

That is written down rather than left to be noticed because this project has
shipped four red tests that passed on the shape of absence.

=head1 THE PID-REUSE ASSERTION IS THE DESIGN DECISION

Liveness is the recorded pid B<confirmed by a command match>. Asking
C<kill 0, $pid> alone is this distribution's own precedent in
C<police_claim_singleton>, and it is rejected here: pids are reused, a reused
pid answers in the affirmative, and a dead monitor reported as alive is exactly
the silence this card exists to remove. The assertion that a reused pid is not
a living monitor is the one a bare-pid implementation would fail, which is what
makes the choice mean something rather than being a preference on a card.

=head1 WINDOWS IS ASKED A SMALLER QUESTION

C<tasklist /fo csv /nh> reports a process name and no command line, so the
command match cannot succeed there and every running monitor on Windows would
have been reported dead. The program-name fallback is asserted on both settings
of C<$Tira::WINDOWS>, so the platform difference is proved rather than assumed,
and the last two assertions run against output from the real
C<_processes_from_windows> parser rather than a hash shaped by hand to suit the
matcher.

=cut
