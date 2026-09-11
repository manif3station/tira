#!/usr/bin/env perl
# TKT-963, his report: "tira.job.run reports ran=1 status=0 but leaves last_run
# null, so a job that HAS run still looks like one that never has."
#
# THREE FACTS A JOB CAN REPORT, and until this card the board could only tell
# two of them apart:
#
#   last_due_at     the window came round. Computed from the police ledger and
#                   never stored - t/563 compares the jobs file byte-for-byte
#                   across a pass, because the rule that knows the instant must
#                   not write the record it judges.
#   last_output_at  the job SAID something. Stamped by job_feed.
#   last_run_at     the command was EXECUTED. This card.
#
# WHY A THIRD FIELD RATHER THAN REUSING ONE, decided on CHK-002 and recorded
# there in full. A manual run never came due, so writing last_due_at would
# claim the schedule fired when it did not. And last_output_at cannot answer
# "did it run", because a command that exits 0 silently says nothing - measured
# in a container: /bin/true came back ran=1 status=0 and left last_output_at
# NULL with recent=0, while last_due_at moved for it exactly as it did for a
# talkative job. So "ran" and "was due" read identically, which is his title.
#
# The retirement of last_run in Job.pm's POD does not forbid this. It was
# written when NOTHING ran commands, so due and ran were one event; since
# TKT-944 they are two, and TKT-950's could-not-start job is the third case -
# due, and did not run.
#
# ONE HOME. Both callers - run_due_commands for the schedule and run_now for
# the button - record through one helper, or the two paths drift apart, which
# is the fault this board has already paid for twice (TKT-932/953 on decoding,
# TKT-949/962 on absent versus empty).
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
use Tira::CLI;
use Tira::CLI::Job;
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-06T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'No Trace', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'NTS', epic_prefix => 'NTE', ticket_prefix => 'NTT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub job_named {
    my ( $tira, $root, $id ) = @_;
    my ($job) = grep { $_->{id} eq $id } @{ $tira->job_list( project => $root ) };
    return $job || {};
}

# --- the button leaves a trace ---------------------------------------------
#
# The whole card. Pressing Run now is how somebody tests a job, which is the
# moment the board should record most and currently records least.

{
    my ( $tira, $root ) = board();
    $tira->job_add( project => $root, schedule => '0 3 * * *',
        command => '/bin/sh -c "echo ran-by-hand"' );

    my $outcome = Tira::CLI::Job::run_now( $tira, { project => $root, id => 'JOB-001' } );
    is( $outcome->{ran}, 1, 'the job ran, which was never the part in doubt' );

    my $job = job_named( $tira, $root, 'JOB-001' );
    like( $job->{last_run_at} // '', qr/\A\d{4}-\d{2}-\d{2}T/,
        'and the job now records WHEN it ran - a manual run is a run, and the card that '
          . 'said "Never fired" after one was reading a field nothing had written' );
    is( $job->{last_run_at}, '2026-09-06T09:00:00Z',
        'stamped from the board clock at the moment it ran' );
}

# --- and its output, the way a scheduled run's is --------------------------
#
# The second half of his report: the panel stays empty for a job that has just
# produced output.

{
    my ( $tira, $root ) = board();
    $tira->job_add( project => $root, schedule => '0 3 * * *',
        command => '/bin/sh -c "echo ran-by-hand"' );

    Tira::CLI::Job::run_now( $tira, { project => $root, id => 'JOB-001' } );

    my $job = job_named( $tira, $root, 'JOB-001' );
    is_deeply( $job->{recent}, ['ran-by-hand'],
        "the run's output is on the card afterwards, exactly as a scheduled run leaves it" );
    is( $job->{last_output_at}, '2026-09-06T09:00:00Z',
        'and last_output_at is stamped at the same instant, because the job did say '
          . 'something - the two fields answer different questions about one run' );
}

# --- a command that succeeds silently still records the run ----------------
#
# The case that made the two paths indistinguishable, and the reason the stamp
# goes where the command is EXECUTED rather than where its output arrives.

{
    my ( $tira, $root ) = board();
    $tira->job_add( project => $root, schedule => '0 3 * * *', command => '/bin/true' );

    my $outcome = Tira::CLI::Job::run_now( $tira, { project => $root, id => 'JOB-001' } );
    is( $outcome->{status}, 0, 'the silent command succeeded' );

    my $job = job_named( $tira, $root, 'JOB-001' );
    is( $job->{last_run_at}, '2026-09-06T09:00:00Z',
        'a command that exits 0 with nothing to say STILL records that it ran - otherwise '
          . '"ran" and "was due" are the same reading, which is the whole complaint' );
    # empty is what passes here, and it is the point: the job genuinely said
    # nothing, so recording that it spoke would be an invention. The assertion
    # above proves the record was written, so this is not an unread file.
    ok( !defined $job->{last_output_at},
        'and does not claim it said anything, because it did not' );
}

# --- the scheduled path records the same thing, through the same helper -----
#
# One decision, one home. Two callers stamping separately is how the decoding
# and the absent-versus-empty faults each cost this board two cards.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    $tira->job_add( project => $root, schedule => '* * * * *', command => '/bin/true' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my $result = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $job = job_named( $tira, $root, 'JOB-001' );
    is( $job->{last_run_at}, '2026-09-06T09:30:00Z',
        'a scheduled silent command records its run too - the schedule and the button '
          . 'answer "did it run" the same way, because one helper answers for both' );
}

# --- a command whose program is missing was still run -----------------------
#
# MEASURED BEFORE ASSERTING, and it overturned what this section first claimed.
# I wrote it expecting a failed exec to record no run - "it was due and it did
# not run" - and ran it to find out:
#
#   OUTCOME JOB-001 ran=1 status=-1 output=tira-a-program-...: open3: exec of
#   ... failed: No such file or directory
#
# run_due_job answers ran => 1 there, deliberately: its own comment says "a
# program that is not there is a RESULT, not a crash". So `ran` in this
# codebase already means THE BOARD RAN THIS JOB, not THE PROGRAM EXECUTED - and
# last_run_at follows that existing vocabulary rather than inventing a second
# meaning of the same word two functions apart. What went wrong is in the
# output lines, where TKT-950 put it.
#
# The case that genuinely records no run is the one below it: a job that runs
# no command at all.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => 'tira-a-program-that-is-not-installed --please' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my $result = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $job = job_named( $tira, $root, 'JOB-001' );
    is( $job->{last_run_at}, '2026-09-06T09:30:00Z',
        'the board ran it and records that - a job whose program is missing has been '
          . 'attempted every minute, and reading "never ran" against that is the same '
          . 'silence this card is about' );
    like( join( ' ', @{ $job->{recent} || [] } ), qr/No such file|exec of/,
        'while the output lines still say what went wrong, which is where it belongs' );
}

# --- a job that runs no command records no run -----------------------------
#
# The direction that would make the field a lie. A message-mode job is
# announced by the engine and executes nothing at all, and run_due_job says so
# with ran => 0.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        message => 'go and hunt some bugs' );

    ${$clock} = '2026-09-06T09:30:00Z';
    my $result = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $job = job_named( $tira, $root, 'JOB-001' );
    # VACUOUS UNTIL THE FIELD EXISTS, and said so rather than counted as red:
    # before the fix nothing writes last_run_at for any job, so this passes on
    # the shape of absence. It becomes a claim the moment the field is written,
    # and it is the one that stops the recorder stamping everything it sees.
    ok( !defined $job->{last_run_at},
        'a message-mode job records no run, however often it comes due - it announces, '
          . 'and nothing was ever executed for it' );
}

# --- what run_now returns is unchanged -------------------------------------
#
# Its caller displays the value. Adding a record must not change the answer.

{
    my ( $tira, $root ) = board();
    $tira->job_add( project => $root, schedule => '0 3 * * *',
        command => '/bin/sh -c "echo shown-to-the-caller"' );

    my $outcome = Tira::CLI::Job::run_now( $tira, { project => $root, id => 'JOB-001' } );
    is( ref $outcome, 'HASH', 'run_now still answers with the outcome hash' );
    is( $outcome->{ran},    1, 'ran, as before' );
    is( $outcome->{status}, 0, 'status, as before' );
    like( $outcome->{output} // '', qr/shown-to-the-caller/, 'and the output, as before' );
}

# --- the monitor branch is untouched ---------------------------------------
#
# A monitor starts a process; it does not run a command. Giving it a command
# job's recording would be inventing a run that never happened.

{
    my ( $tira, $root ) = board();
    $tira->job_add( project => $root, schedule => 'monitor',
        command => 'tira-a-monitor-nobody-started --poll' );

    my $cli = Suite::cli_source('Job.pm');
    # non-empty is the whole claim: the check below would pass on an
    # unreadable file's emptiness alone.
    like( $cli, qr/\S/, 'the job command source is there to be read' );

    my ($run_now) = $cli =~ /(sub \s+ run_now \b .*?\n\})/xs;
    ok( defined $run_now, 'run_now was found, to read what it does before it records anything' );
    like( $run_now // '', qr/_start_monitor.*?\n.*?monitor/s,
        'the monitor branch still returns before the command path, so a monitor is not '
          . 'given a record of a command run it never made' );
}

# --- both callers record through one helper --------------------------------
#
# The registry point. Two functions run a job; if each stamps for itself, the
# next person changing one will not know to change the other.

{
    # TKT-1043 lifted record_run and run_due_commands together into
    # Tira::CLI::Police::Jobs - both are read from there now, so the
    # "same recorder" relationship between them is still visible in one
    # file. 'Jobs.pm' alone is ambiguous with Tira::CLI::Browser::Jobs
    # (TKT-1042), so the path is qualified.
    my $police = Suite::cli_source('Police/Jobs.pm');
    my $jobcli = Suite::cli_source('Job.pm');

    # non-empty is the whole claim: the checks below would pass on unreadable
    # files' emptiness alone.
    like( $police, qr/\S/, 'the police source is there to be read' );
    like( $jobcli, qr/\S/, 'the job source is there to be read' );

    my ($helper) = $police =~ /sub \s+ (\w*record_run\w*) \b/x;
    ok( defined $helper,
        'there is a named recorder for a run, rather than the stamp written out twice' );

    like( $jobcli, qr/\Q$helper\E/,
        'run_now records through it' ) if defined $helper;
    my ($due) = $police =~ /(sub \s+ run_due_commands \b .*?\n\})/xs;
    like( $due // '', qr/\Q$helper\E/,
        'and the scheduled path records through the same one' ) if defined $helper;
}

# --- and the card stops saying "Never fired" -------------------------------
#
# Acceptance criterion 1 is about what the CARD READS, not only about what is
# stored. The beat line painted "Never fired" from last_due_at alone, which a
# manual run never moves - so a job he had just run by hand went on reading as
# one that never had.

{
    my $view = Suite::view_source('jobs-editor.js');
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone.
    like( $view, qr/\S/, 'the jobs view is there to be read' );

    like( $view, qr/last_run_at/,
        'the beat line reads last_run_at, so a job that ran by hand does not go on '
          . 'reading "Never fired" - which is the sentence he was looking at' );
    like( $view, qr/Last ran/,
        'and says it RAN rather than that it fired, because those are now different '
          . 'facts and the window is the less interesting half once something executed' );
    like( $view, qr/Never fired/,
        'while a job that has neither run nor come due still says so - never fired is a '
          . 'state, not a failure, and a job added minutes ago is in it' );
}

# --- and the field reaches the page ----------------------------------------
#
# THE GAP THIS SECTION EXISTS TO CLOSE, found by probing the provider rather
# than by reading it. Everything above proves the field is STORED and that the
# view READS it - and neither says it arrives. The jobs provider copies every
# stored key (%row = %{$job}), so it does today; a whitelist added there later
# would break the card face silently while every assertion above stayed green.
#
# Probed before asserting, on a board with one job run by hand:
#
#   {"id":"JOB-001",...,"last_due_at":null,"last_run_at":"2026-09-06T09:00:00Z",...}
#
# which is exactly his case: no window ever came round, and the job ran.

{
    my ( $tira, $root ) = board();
    $tira->job_add( project => $root, schedule => '0 3 * * *', command => '/bin/true' );
    Tira::CLI::Job::run_now( $tira, { project => $root, id => 'JOB-001' } );

    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    my $payload = $providers{jobs}->();

    like( $payload, qr/"last_run_at"\s*:\s*"2026-09-06T09:00:00Z"/,
        'the jobs provider carries last_run_at to the page, so the card face can read it - '
          . 'stored and rendered are two different claims and this is the one between them' );
    like( $payload, qr/"last_due_at"\s*:\s*null/,
        'while last_due_at is still null, which is his case exactly: the window never came '
          . 'round and the job ran anyway' );
}

done_testing();

__END__

=head1 NAME

576-a-run-that-left-no-trace.t - a job that ran records that it ran, by either path

=head1 DESCRIPTION

TKT-963, from the owner's report: C<tira.job.run> answers C<ran=1 status=0> and
leaves the job record untouched, so a job that has run reads as one that never
has. The dashboard's beat line paints "Never fired" from C<last_due_at>, which
is the police ledger's record of a window coming round - a manual run never
comes due, so nothing moved.

A job can now report three facts rather than two: C<last_due_at>, the window
came round; C<last_run_at>, the command was executed; C<last_output_at>, it
said something. The new one is stamped where the command is executed, so a
command that exits 0 silently still records its run, and a command that could
not start records none. Both the schedule and the button record through one
helper, so the two paths cannot answer the same question differently.

=cut
