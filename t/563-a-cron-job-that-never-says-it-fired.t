#!/usr/bin/env perl
# TKT-942. Michael, three times in one afternoon (TG 7090, 7094, 7108), asking
# why a job showed no run history and being told each time to go read the
# bridge log. He was right to read it as broken.
#
# WHAT WAS ACTUALLY TRUE, measured on the live board: last_run is a field
# nothing writes. One occurrence assigns it - `last_run => undef` at job
# creation - and that is all of it; every job on the board carried null,
# including the two monitors that were demonstrably alive. The "Last spoke X
# ago" indicator he could see on those two reads a DIFFERENT field,
# last_output_at, which the feeder stamps only for monitors (TKT-851). So no
# cron job of either mode has ever had anything to show.
#
# WHERE THE ANSWER HAS TO COME FROM. lib/Tira/Job.pm's own POD (DUE TOLERATES
# A GAP BETWEEN CHECKS) settles it: the job-due rule keeps its per-job stamp
# "in the same store-backed ledger agent-still's own notified-stamp already
# uses - not on the job record itself, for the same reason no other stateful
# rule here writes the record it is judging." So the due instant is recorded
# in the ledger beside job_checked, and joined onto the job at READ time as
# last_due_at - a computed field, never persisted onto the record.
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

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-05T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Jobs That Fire', dir => $root, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'JFS', epic_prefix => 'JFE', ticket_prefix => 'JFT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    my $store = File::Spec->catdir( $tmp, 'police-store' );
    return ( $tira, $root, $store, \$now );
}

sub job_by_id {
    my ( $tira, $root, $store, $id ) = @_;
    my ($job) = grep { $_->{id} eq $id }
      @{ $tira->job_list( project => $root, store => $store ) };
    return $job;
}

# --- both cron modes report when they last fired ---------------------------
#
# The whole of the report: a message-mode hunt and a command-mode check, the
# two shapes on his own board (JOB-001 and JOB-004), both blank before this.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        message => 'HOURLY HUNT stand-in - a message-mode cron job' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => 'd2 tira.police.outstanding' );

    ${$clock} = '2026-09-05T09:30:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );

    my $message_job = job_by_id( $tira, $root, $store, 'JOB-001' );
    my $command_job = job_by_id( $tira, $root, $store, 'JOB-002' );

    is( $message_job->{mode}, 'message', 'JOB-001 is the message-mode job' );
    is( $command_job->{mode}, 'command', 'JOB-002 is the command-mode job' );

    like( $message_job->{last_due_at}, qr/\A2026-09-05T09:30/,
        'a message-mode cron job reports when it last fired - the blank he kept asking about' );
    like( $command_job->{last_due_at}, qr/\A2026-09-05T09:30/,
        'and so does a command-mode cron job, which was just as blank as the hunts' );
}

# --- never fired reads as never, not as the same blank ---------------------
#
# The distinction that makes the answer worth having. Before this, a job that
# had fired and a job that never had were indistinguishable - both null.

{
    my ( $tira, $root, $store, $clock ) = board();

    # Due only at 03:00, and no pass will happen near it.
    $tira->job_add( project => $root, schedule => '0 3 * * *',
        message => 'a job whose window has not come round' );

    ${$clock} = '2026-09-05T09:30:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );

    my $job = job_by_id( $tira, $root, $store, 'JOB-001' );
    ok( exists $job->{last_due_at},
        'a job that has never been due still carries the field, so a reader is not left guessing why it is absent' );
    ok( !defined $job->{last_due_at},
        'and it is undef - never fired, said distinctly rather than as the same blank a fired job used to show' );
}

# --- the rule still writes no job record -----------------------------------
#
# Job.pm's own stated constraint, and t/86 fingerprints the board across a
# pass for the same reason. Asserted here too, because this card is the one
# that would have been tempted to break it.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', message => 'fires every minute' );

    my $jobs_file = File::Spec->catfile( $root, '.tira', 'jobs.json' );
    $jobs_file = File::Spec->catfile( $root, '.tira', 'jobs.yml' ) if !-f $jobs_file;
    ok( -f $jobs_file, 'the jobs record is on disk to be compared' ) or diag("looked for $jobs_file");

    my $before = do { open my $fh, '<:raw', $jobs_file or die $!; local $/; <$fh> };
    ${$clock} = '2026-09-05T09:30:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );
    my $after = do { open my $fh, '<:raw', $jobs_file or die $!; local $/; <$fh> };

    is( $after, $before,
        'a pass that announced a due job left the job record byte-identical - the stamp went to the ledger, not the record' );
}

# --- last_due_at is computed, never persisted ------------------------------
#
# Asked without a store, the answer is simply absent rather than stale: a
# field that survived onto the record would be the same dead-field problem
# this card exists to end, one name along.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', message => 'fires every minute' );
    ${$clock} = '2026-09-05T09:30:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );

    my ($storeless) = @{ $tira->job_list( project => $root ) };
    ok( !defined $storeless->{last_due_at},
        'read without a store, nothing is claimed - the instant lives in the ledger, not on the record' );
}

# --- and it reaches the two places he actually looks ----------------------
#
# His words, once both tickets were filed: "I want these 2 to be fixed and
# show on the dashboard." An engine field nothing renders would be this card
# solved everywhere except where he was asking.

{
    my $js = Suite::view_source('jobs-editor.js');
    # non-empty is the whole claim: every check below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $js, qr/\S/, 'jobs-editor.js is there to be read' );

    like( $js, qr/last_due_at/,
        'the jobs editor reads last_due_at, so a cron row has something to show' );
    like( $js, qr/Last fired/,
        'and says "Last fired" on a cron row - the line that was missing from his screenshot' );
    like( $js, qr/Never fired/,
        'with never-fired kept as its own state rather than painted as a fault' );

    # The monitor heartbeat must not be what answers for a cron job: that
    # field is monitor-only, and reusing it here would report a cron job as
    # silent forever.
    my ($cron_branch) = $js =~ /schedule_kind\s*!==\s*"monitor"(.*?)li\.appendChild\(firedEl\)/s;
    ok( defined $cron_branch, 'the cron branch was found to check what it reads' );

    # Comments stripped before the denial. The branch EXPLAINS that
    # last_output_at is the monitor's field and not this one, so a search of
    # the raw text finds the name in prose and reports a fault that is not
    # there - the same false match qr/select/i made against "querySelector"
    # on TKT-600.
    my $cron_code = $cron_branch =~ s{^\s*//.*$}{}mgr;
    like( $cron_code, qr/last_due_at/,
        'the cron branch reads last_due_at in code, not only in its comments' );
    unlike( $cron_code, qr/last_output_at/,
        'and does not borrow the monitor-only field to answer with' );
}

{
    # The CLI half, so the same answer is available without the browser.
    my $cli = Suite::cli_source('Job.pm');
    # non-empty is the whole claim: the denial below needs a real subject.
    like( $cli, qr/\S/, 'the job CLI is there to be read' );
    like( $cli, qr/job_list\s*\(\s*%list\s*\)|store/,
        'tira.job.list resolves a store, so job_list has a ledger to join the instant from' );
}

done_testing();

__END__

=head1 NAME

563-a-cron-job-that-never-says-it-fired.t - cron jobs of both modes report when they last fired

=head1 DESCRIPTION

TKT-942. C<last_run> was written by nothing: a single C<< last_run => undef >>
at job creation and no other assignment anywhere, so every job read null
forever. The "Last spoke" indicator belongs to C<last_output_at>, which the
feeder stamps for monitors only, leaving cron jobs of both modes with nothing
to show. The C<job-due> rule now records each genuinely-due window in the same
store-backed ledger it already keeps C<job_checked> in, and C<job_list> joins
it on at read time as C<last_due_at> when given a store - computed, never
persisted, so the rule still writes no record it judges.

=cut
