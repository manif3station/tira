#!/usr/bin/env perl
# TKT-943. His screenshot, 2026-09-05: "No Tail log windows in the card".
#
# THIS FILE IS A REGRESSION GUARD, NOT A RED TEST, and saying so plainly
# matters. The card was filed when a cron command job's output reached nowhere
# a reader could get to. TKT-944 then wired the execution step, and it feeds
# what the command printed through job_feed - the same pipe a monitor's output
# already travels - so the output now lands on the job's own `recent` tail as
# a side effect of the run actually happening. This file was written GREEN, on
# purpose, to hold that behaviour in place rather than to drive it.
#
# WHY IT IS WORTH HOLDING. Two independent things have to stay true for a cron
# run to be visible, and neither is obvious from the other's side: the run has
# to feed `recent` (engine/CLI), and the view's tail panel must not be gated to
# monitors (browser). The second is the one that would break silently - the
# panel was built for monitors, its comments are all about monitors, and a
# future change narrowing it to them would look like a tidy-up while taking
# this card's answer away with it.
#
# I ALSO GOT THIS CARD WRONG ONCE. I discarded it earlier today claiming
# command-mode jobs already had an output panel. They did not - the jobs that
# had one were MONITORS, and a cron command job had nothing. His next
# screenshot proved it and the card came back out of discard. The assertions
# below are deliberately about a CRON job for that reason.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI::Police;

# --- a cron command job's output reaches the job the card reads from -------

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-05T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Seen Runs', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'SRS', epic_prefix => 'SRE', ticket_prefix => 'SRT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );

    # A CRON job, not a monitor - the distinction this card was filed about.
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/echo a-line-the-card-should-show' );

    my $store = File::Spec->catdir( $tmp, 'store' );
    $now = '2026-09-05T09:30:00Z';
    my $result = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my ($job) = grep { $_->{id} eq 'JOB-001' } @{ $tira->job_list( project => $root ) };
    isnt( ( $job->{schedule} // '' ), 'monitor',
        'the job under test is a cron job, which is the case that had nothing' );

    my $recent = join "\n", @{ $job->{recent} || [] };
    like( $recent, qr/a-line-the-card-should-show/,
        "the cron run's own output is on the job, which is where the card's tail panel reads from" );
}

# --- and the panel that renders it is not gated to monitors ----------------
#
# The half that would break quietly. Everything around this code is written
# about monitors; narrowing it to them would read as a tidy-up and would take
# the answer away.

{
    my $js = Suite::view_source('jobs-editor.js');
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $js, qr/\S/, 'jobs-editor.js is there to be read' );

    my ($seed) = $js =~ /(if\s*\(\s*!runLogs\.has\(job\.id\).*?rememberLines\(job\.id,\s*job\.recent\.join\("\\n"\)\);)/s;
    ok( defined $seed, 'the tail-seeding branch was found to check what it is conditioned on' )
      or diag('the seed branch moved - update this pattern rather than deleting the assertion');

    # Comments stripped: the branch is explained entirely in terms of monitors,
    # so a search of the raw text finds the word and reports a gate that is not
    # there - the same false match qr/select/i made against "querySelector" on
    # TKT-600, and my own comment made against last_output_at on TKT-942.
    my $seed_code = ( $seed // '' ) =~ s{^\s*//.*$}{}mgr;
    unlike( $seed_code, qr/monitor/i,
        'the tail is seeded from job.recent for ANY job, not only a monitor - '
          . 'which is what makes a cron run visible on its own card' );
}

# --- the browser hands the row that field, for a cron job too --------------

{
    my $browser = Suite::cli_source('Browser.pm');
    # non-empty is the whole claim: the denial below needs a real subject.
    like( $browser, qr/\S/, 'the browser provider is there to be read' );

    my ($rows) = $browser =~ /jobs\s*=>\s*sub\s*\{(.*?)\n\s{8}\},/s;
    ok( defined $rows, 'the jobs provider body was found' );

    # It copies the whole job record and then deletes exactly one field. If it
    # ever grew an allow-list instead, `recent` could be dropped without anyone
    # noticing the card had gone quiet again.
    like( $rows, qr/%row\s*=\s*%\{\$job\}/,
        'the row is the whole job record, so recent reaches the page without being listed' );
    unlike( $rows, qr/delete\s+\$row\{recent\}/,
        'and recent is not among the fields scrubbed on the way out' );
}

done_testing();

__END__

=head1 NAME

565-a-cron-run-that-can-be-seen.t - a cron command job's run output is visible on its own card

=head1 DESCRIPTION

TKT-943. Written GREEN as a regression guard: TKT-944's execution step feeds a
cron run's output through C<job_feed>, so it lands on the job's C<recent> tail,
and the jobs editor seeds its log panel from C<job.recent> for any job rather
than for monitors alone. Both halves have to stay true for a cron run to be
visible, and the view half is the one that would break silently, since the
panel and all its comments were written about monitors.

=cut
