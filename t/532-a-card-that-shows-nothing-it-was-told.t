#!/usr/bin/env perl
# A monitor's card, showing nothing the monitor said.
#
# TKT-922, EPC-014. His Telegram 6814, with a screenshot of three job cards side
# by side: JOB-004 has a black log panel full of lines, JOB-005 and JOB-006 have
# none. "why only 1 job got the tail logs?"
#
# THE PANEL IS FED FROM ONE PLACE. lib/Tira/views/jobs-editor.js builds a logBox
# per card and fills it only inside the play button's click handler:
#
#   post("/jobs/run", { id: job.id }).then((result) => {
#     const output = result && result.output ? String(result.output).trim() : "";
#     if (output) { rememberLines(job.id, output); paintLog(logBox, job.id); }
#
# JOB-004 is a cron job. Its button is "Run now", it ran, the response carried
# output, the box was painted. A MONITOR'S BUTTON IS "Start" - TKT-843 CHK-001
# decided that deliberately, since a monitor has no schedule to bypass - and
# starting one returns a job record rather than output. So that branch can never
# run for a monitor, and its card can never show a line however much it is
# saying. JOB-006 had spoken sixteen minutes before his screenshot.
#
# AND READING job.output WOULD NOT FIX IT. That queue is a HANDOVER, not a
# record: the feeder fills it, the police pass takes what it announced, and it is
# meant to be emptied. A card reading it finds it empty almost always. So the
# record needs a second thing - a bounded tail the drain never touches.
#
# SIZED FROM WHAT THE FEEDER ALREADY USES rather than a number invented here.
# $MONITOR_OUTPUT_HELD is 200 for the queue and $BATCH_LINES is 25 for a
# delivery; a card showing the last delivery's worth is one batch.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use JSON::PP ();
use Tira;
use Tira::Job;

my ( $tira, $root, $monitor );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Cards', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'CDS', epic_prefix => 'CDE', ticket_prefix => 'CDT',
    );
    $monitor = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller', author => 'claude' );
    $tira->job_started( project => $root, id => $monitor->{id}, pid => 4242 );
}

sub record {
    my ($job) = grep { $_->{id} eq $monitor->{id} }
      @{ $tira->job_list( project => $root ) };
    return $job // {};
}

# --- the record keeps a tail the drain does not take -------------------------

ok( Tira::Job->can('monitor_recent_kept'),
    'THE TAIL HAS A DECLARED SIZE, named beside the buffer constants it is '
      . 'derived from rather than written into whichever function needed it '
      . 'first - the same reason $MONITOR_OUTPUT_HELD and $BATCH_LINES are '
      . 'named' );

$tira->job_feed( project => $root, id => $monitor->{id},
    lines => [ 'the first thing it said', 'and the second' ] );

{
    my $job = record();

    # non-empty is the whole claim: a feed that recorded nothing would make the
    # drain assertion below vacuously true, which is exactly how a card that
    # shows nothing passes a test written to catch it.
    is( scalar @{ $job->{output} || [] }, 2,
        'the queue holds what the monitor just said - the handover the police '
          . 'pass reads' );

    is_deeply( $job->{recent} || [],
        [ 'the first thing it said', 'and the second' ],
        'AND THE RECORD KEEPS ITS OWN COPY. Today there is no such field: the '
          . 'only place a monitor\'s words live is the queue, which exists to '
          . 'be emptied' );
}

# --- and it survives the drain ------------------------------------------------
#
# The assertion the card turns on. The queue is emptied on every pass that
# announces; if the tail went with it, a card reading the record would find
# nothing a second after the monitor spoke, which is today's behaviour wearing a
# new field name.

$tira->job_output_drain( project => $root, id => $monitor->{id},
    count => 2, dropped => 0 );

{
    my $job = record();

    is( scalar @{ $job->{output} || [] }, 0,
        'the drain empties the queue, unchanged - the handover happened' );

    is_deeply( $job->{recent} || [],
        [ 'the first thing it said', 'and the second' ],
        'AND THE TAIL SURVIVES IT. This is the whole card: the queue is a '
          . 'handover and the tail is a record, and a card has nothing to show '
          . 'unless they are different things' );
}

# --- bounded, and keeping the newest -----------------------------------------
#
# A monitor runs for weeks. An unbounded tail is a job record that grows without
# limit, which is the fault $MONITOR_OUTPUT_HELD already exists to prevent for
# the queue - and the card wants what is true NOW, so the oldest go first.

SKIP: {
    my $sizer = Tira::Job->can('monitor_recent_kept');
    skip 'no declared tail size to ask for', 5 if !$sizer;
    my $kept = $sizer->();

    cmp_ok( $kept, '>', 0, 'the tail keeps a bounded number of lines' );

    # THE TWO CONSTANTS MUST NOT DRIFT. The tail is one delivery's worth, and
    # the delivery size lives in Tira::CLI::Job - a module the engine must not
    # depend on, which is the same boundary that keeps Tira::Job away from the
    # process table. So the value is mirrored rather than shared, and this is
    # what a shared reference would otherwise have guaranteed.
    require Tira::CLI::Job;
    # Read once, which is what "used only once" warns about - the variable is
    # another module's and this is the only place the suite names it.
    no warnings 'once';
    is( $kept, $Tira::CLI::Job::BATCH_LINES,
        'and it is one feeder delivery, not a number chosen freely - mirrored '
          . 'across the engine/CLI boundary rather than referenced across it' );

    $tira->job_feed( project => $root, id => $monitor->{id},
        lines => [ map {"line $_"} 1 .. $kept + 5 ] );

    my $job = record();

    is( scalar @{ $job->{recent} || [] }, $kept,
        'and never more than that, however long the monitor runs' );

    is( $job->{recent}[-1], 'line ' . ( $kept + 5 ),
        'the NEWEST are what it keeps - a card shows what is true now, and an '
          . 'overflowing tail that dropped the newest would show a monitor\'s '
          . 'first minutes for ever' );

    isnt( $job->{recent}[0], 'the first thing it said',
        'and the oldest have gone, which is what bounded means' );
}

# --- the page is given it ------------------------------------------------------
#
# Where TKT-914 put the same assertion, and for the same reason: it decides
# whether the remaining work is in the browser or the engine. If the provider
# withheld the tail, a fix aimed at the JavaScript would be aimed at nothing.

{
    require Tira::CLI::Browser;
    my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );

    ok( ref $provider{jobs} eq 'CODE', 'the jobs provider is there to call' );

    my $answer = $provider{jobs}->( {} );
    my $decoded = ref $answer ? $answer : JSON::PP->new->decode($answer);
    my $listed = ref $decoded eq 'HASH'
      ? ( $decoded->{jobs} || $decoded->{items} ) : $decoded;

    my ($seen) = grep { ( $_->{id} // '' ) eq $monitor->{id} } @{ $listed || [] };

    # non-empty is the whole claim: an empty listing would report a server-side
    # gap that is not there.
    ok( $seen, 'the monitor came back to the page' );

    cmp_ok( scalar @{ ( $seen || {} )->{recent} || [] }, '>', 0,
        'AND THE PAGE IS GIVEN ITS RECENT OUTPUT. So a card showing nothing is '
          . 'the card not asking, rather than the server not telling' );
}

# --- and the card paints it on render -----------------------------------------
#
# Source-read, the way this suite tests jobs-editor.js - t/500, t/508, t/510,
# t/517, t/528 and t/530 all do; it drives no browser and browser tests are his.
# Scoped to the card-building region, because paintLog is called from the play
# handler too and a whole-file match would pass today.

my $editor = do {
    open my $fh, '<:encoding(UTF-8)', 'lib/Tira/views/jobs-editor.js'
      or die "jobs-editor.js: $!";
    local $/;
    <$fh>;
};

my ($card) = $editor =~ /(const \s logBox \s* = .*? play\.addEventListener)/xs;

ok( defined $card && length $card,
    'the card-building region was extracted - from the log panel down to the '
      . 'play button, which is the only thing that fills it today' );

like( $card // '', qr/paintLog/,
    'and it already knows how to paint one, which is why this is a small '
      . 'change: paintLog restores remembered lines when a card is rebuilt' );

like( $card // '', qr/job\.recent/,
    'THE CARD PAINTS FROM THE RECORD ON RENDER. Today logBox is filled only '
      . 'from the response to a Run-now click, and a monitor has no Run-now - '
      . 'so a monitor\'s card can never show a line, which is exactly what his '
      . 'screenshot shows' );

done_testing();

__END__

=head1 NAME

532-a-card-that-shows-nothing-it-was-told.t - a monitor's card and its output

=head1 WHY

TKT-922. The log panel on a job card is filled only from the response to a
Run-now click. A monitor's button is Start, and starting one returns a job
record rather than output, so a monitor's card can never show a line. His
screenshot: one cron job with a full panel beside two running monitors with none.

Reading C<job.output> would not fix it either. That queue is a handover - the
feeder fills it and the police pass takes what it announced - so a card reading
it finds it empty almost always.

=head1 WHAT IS ASSERTED

That the record keeps a bounded tail of a monitor's own words, separate from the
queue; that the tail survives the drain, which is the whole point; that it keeps
the newest and drops the oldest; that the jobs provider hands it to the page,
which is what places the remaining work in the browser rather than the server;
and that the card paints from it on render.

=head1 WHAT IS NOT ASSERTED, AND WHY

That the rendered panel shows the lines. This suite reads C<jobs-editor.js> as
source and drives no browser; browser checks are his.

Nothing about the drain's own behaviour beyond that it leaves the tail alone.
The queue emptying is correct and is what TKT-925 has just made honest.

=cut
