#!/usr/bin/env perl
# A schedule that never fires looks exactly like a schedule with nothing to say.
#
# That is not a hypothetical. On 2026-09-02 the three standing hunts - the
# hourly bug hunt, the two-hourly improvement hunt, the three-hourly doc-gap
# hunt - had been dead for hours as in-session monitors, and nobody noticed,
# because a loop that has stopped and a loop with nothing to report produce
# the same output: none. Michael noticed the absence and asked. The agent
# could not have.
#
# EPC-014 moves that schedule onto the board so it is visible, survives a
# session, and can be policed. TKT-836 is its foundation: the record, and the
# question "is this due right now".
#
# WRITTEN RED, before any of it exists.
#
# THE ONE RULE THIS FILE EXISTS FOR is the refusal. A malformed cron
# expression must be refused AT WRITE TIME, naming what was wrong - not
# stored and left silently inert. Storing it would rebuild the exact
# ambiguity the epic was filed to remove, one layer down: a job that never
# fires because its schedule is nonsense is indistinguishable from a job with
# nothing to announce, and the board would be asserting a schedule it does
# not have.
#
# BOTH MODES AND BOTH SCHEDULE KINDS ARE HERE FROM THE START, per his
# msg 6487 - 'either set to run a command and output to the police bridge or
# direct message to the bridge', and a schedule that may be a crontab string
# OR the literal 'monitor'. An earlier draft of this epic recorded
# message-only as a constraint; that was an over-reading of his first
# message and is corrected on the cards.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-02T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Scheduled', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

# --- a message-mode job, on a cron schedule ---------------------------------

{
    my $job = $tira->job_add(
        project  => $root,
        schedule => '0 * * * *',
        message  => 'go hunt some bugs',
    );
    ok( $job, 'a message-mode job can be created' );
    is( $job->{schedule}, '0 * * * *', 'and keeps the schedule it was given' );
    is( $job->{message},  'go hunt some bugs', 'and the message it announces' );
    is( $job->{mode},     'message', 'its mode is message, explicitly rather than inferred' );
    ok( $job->{enabled}, 'and it is enabled when created' );

    my ($read) = grep { $_->{id} eq $job->{id} } @{ $tira->job_list( project => $root ) };
    is_deeply( $read, $job, 'and it reads back from the board unchanged' );
}

# --- a command-mode job, whose output goes to the bridge --------------------
#
# His msg 6487: "either set to run a command and output to the police bridge
# or direct message to the bridge".

{
    my $job = $tira->job_add(
        project  => $root,
        schedule => '*/5 * * * *',
        command  => 'd2 tira.police.outstanding',
    );
    is( $job->{mode}, 'command', 'a job given a command is command-mode' );
    is( $job->{command}, 'd2 tira.police.outstanding', 'and keeps the command' );
    ok( !defined $job->{message}, 'and carries no message' );
}

# --- a job may not be both, and may not be neither --------------------------

{
    eval { $tira->job_add( project => $root, schedule => '0 * * * *' ) };
    like( $@, qr/command|message/i,
        'a job with neither a command nor a message is refused, naming what is missing' );

    eval {
        $tira->job_add( project => $root, schedule => '0 * * * *',
            command => 'x', message => 'y' );
    };
    like( $@, qr/command|message/i,
        'and a job given both is refused rather than one being silently dropped' );
}

# --- the schedule may be the literal 'monitor' ------------------------------
#
# His msg 6487: "If the user use the scheduler like 'monitor' instead of
# crontab scheduler string ... that is kind of a poller".

{
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor',
        command => 'd2 tira.policy.bridge',
    );
    is( $job->{schedule}, 'monitor', "a job's schedule may be the literal 'monitor'" );
    is( $job->{schedule_kind}, 'monitor',
        'and its kind says so, so a caller need not re-parse the schedule to tell' );
}

{
    my $job = $tira->job_add( project => $root, schedule => '0 * * * *', message => 'x' );
    is( $job->{schedule_kind}, 'cron', 'while a crontab string is kind cron' );
}

# --- THE REFUSAL: a malformed schedule cannot be saved ----------------------

{
    for my $bad ( 'not a cron', '99 * * * *', '* * * *', '* * * * * *', '' ) {
        eval { $tira->job_add( project => $root, schedule => $bad, message => 'x' ) };
        isnt( $@, '', "a malformed schedule '$bad' is refused" );
    }

    eval { $tira->job_add( project => $root, schedule => '99 * * * *', message => 'x' ) };
    like( $@, qr/99|minute|range|schedule/i,
        'and the refusal names what was wrong rather than saying only that it failed' );

    my @stored = grep { ( $_->{schedule} // '' ) eq '99 * * * *' }
      @{ $tira->job_list( project => $root ) };
    is_deeply( \@stored, [],
        'and nothing was written - a refused schedule is absent, not stored inert' );
}

# --- is it due? asked against an injected clock, never the wall clock -------

{
    my $hourly = { schedule => '0 * * * *' };
    ok( $tira->job_is_due( $hourly, '2026-09-02T03:00:00Z' ),
        'an hourly job is due on the hour' );
    ok( !$tira->job_is_due( $hourly, '2026-09-02T03:30:00Z' ),
        'and is not due half past' );

    # The three cadences his examples use.
    ok( $tira->job_is_due( { schedule => '0 */1 * * *' }, '2026-09-02T05:00:00Z' ),
        'every hour matches at 05:00' );
    ok( $tira->job_is_due( { schedule => '0 */2 * * *' }, '2026-09-02T04:00:00Z' ),
        'every two hours matches at 04:00' );
    ok( !$tira->job_is_due( { schedule => '0 */2 * * *' }, '2026-09-02T05:00:00Z' ),
        'and not at 05:00' );
    ok( $tira->job_is_due( { schedule => '0 */3 * * *' }, '2026-09-02T06:00:00Z' ),
        'every three hours matches at 06:00' );

    ok( !$tira->job_is_due( { schedule => 'monitor' }, '2026-09-02T06:00:00Z' ),
        'a monitor job is never "due" - it runs continuously rather than on a tick' );

    ok( !$tira->job_is_due( { schedule => '0 * * * *', enabled => 0 }, '2026-09-02T03:00:00Z' ),
        'and a disabled job is never due, whatever its schedule says' );
}

# --- a range, and a field that is not a number at all -----------------------
#
# Both branches the first draft of this file never reached. 'not a cron' is
# rejected for having three fields, so it never got as far as asking what a
# field means - a refusal that fires early hides whether the later check
# works at all. These two ask directly.

{
    my $office = { schedule => '0 9-17 * * *' };
    ok( $tira->job_is_due( $office, '2026-09-02T09:00:00Z' ), 'a range matches its start' );
    ok( $tira->job_is_due( $office, '2026-09-02T13:00:00Z' ), 'and the middle' );
    ok( $tira->job_is_due( $office, '2026-09-02T17:00:00Z' ), 'and its end, inclusively' );
    ok( !$tira->job_is_due( $office, '2026-09-02T18:00:00Z' ), 'and nothing past it' );

    # Five fields, so the shape check passes and the field check is what has
    # to refuse it.
    eval { $tira->job_add( project => $root, schedule => '* * * * abc', message => 'x' ) };
    like( $@, qr/day of week|abc|valid/i,
        'a five-field schedule whose field is not a number is refused, naming the field' );

    eval { $tira->job_add( project => $root, schedule => '5-2 * * * *', message => 'x' ) };
    isnt( $@, '', 'and a range that runs backwards is refused' );
}

# --- update and delete ------------------------------------------------------

{
    my $job = $tira->job_add( project => $root, schedule => '0 * * * *', message => 'first' );
    my $changed = $tira->job_update( project => $root, id => $job->{id}, message => 'second' );
    is( $changed->{message}, 'second', 'a job\'s message can be updated' );

    eval { $tira->job_update( project => $root, id => $job->{id}, schedule => 'nonsense' ) };
    isnt( $@, '', 'and an update to a malformed schedule is refused too, not only creation' );

    $tira->job_delete( project => $root, id => $job->{id} );
    my @left = grep { $_->{id} eq $job->{id} } @{ $tira->job_list( project => $root ) };
    is_deeply( \@left, [], 'a deleted job is gone from the list' );
}

done_testing();

__END__

=head1 NAME

t/487-a-schedule-that-cannot-be-saved-broken.t - the repeated-job record and its schedule

=head1 DESCRIPTION

TKT-836, the foundation of EPC-014. A repeated job carries a schedule - a
crontab string or the literal C<monitor> - and either a command to run or a
message to announce, and the engine can say whether a cron job is due at a
given instant.

The rule this file exists for is the refusal: a malformed schedule is rejected
when it is written, naming what was wrong, and nothing is stored. A schedule
that never fires is indistinguishable from a job with nothing to say, and that
ambiguity is exactly what EPC-014 was filed to remove after three standing
hunts died unnoticed.

Every due-check takes the instant as an argument rather than reading the
clock, so the assertions are about the schedule rather than about when the
suite happened to run.

=cut
