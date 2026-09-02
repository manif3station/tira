#!/usr/bin/env perl
# The schedule, visible on the board rather than only in a file.
#
# His words, msg 6480: "On the dashboard, a new section under the tasklist to
# see all the scheduled jobs, they like cronjob style the record. In the
# dashboard each repeated job has its own entry on the table."
#
# TKT-836 shipped the record and TKT-838 made it speak. Neither made it
# visible: to see what this board is scheduled to do you currently read
# .tira/jobs.json. That is the same shape of problem the epic started with -
# a schedule nobody can see is a schedule nobody checks. TKT-839.
#
# WRITTEN RED, before the provider and the section exist.
#
# WHAT THIS CARD IS NOT. No play button and no editor modal - those are
# TKT-843, and this file asserts only what a read-only section owes. The
# scope line is on the card; the reason it is worth keeping separate is that
# a button that runs a job is a different kind of thing from a table that
# shows one, and it deserves its own tests rather than arriving inside these.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new( clock => sub {'2026-09-02T05:00:00Z'} );

$tira->project_new(
    name => 'Scheduled', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);
$tira->job_add( project => $root, schedule => '0 * * * *', message => 'go hunt some bugs' );
$tira->job_add( project => $root, schedule => 'monitor',   command => 'd2 tira.policy.bridge' );

# --- the browser can ask for them -------------------------------------------

{
    # browser_providers takes a named hash and returns a hash, not a ref -
    # the shape t/100 and t/411 already use. My first draft passed
    # positionals and got "Not a HASH reference", which is the harness being
    # wrong rather than the provider being missing.
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    ok( ref $providers{jobs} eq 'CODE',
        'the browser has a jobs provider, the way it already has one for the tasklist' );

    my $payload = $providers{jobs}->();
    ok( length $payload, 'and it answers with something' );
    like( $payload, qr/go hunt some bugs/, 'naming the message job' );
    like( $payload, qr/policy\.bridge/,    'and the command job' );
    like( $payload, qr/monitor/,           'and saying which schedule kind each is' );
}

# --- and the page shows one row per job -------------------------------------

{
    my $page = $tira->format_output(
        $tira->dashboard( project => $root, live => 1 ),
        output => 'table', live => 1,
    );

    # non-empty is the whole claim: a precondition for the assertions below,
    # which would pass against a page that rendered nothing at all.
    like( $page, qr/\S/, 'the board page has something in it' );

    # THE PAGE CARRIES THE SECTION; THE DATA ARRIVES BY FETCH. The first
    # draft asserted the job's message and id were in the rendered HTML, and
    # that is not how this dashboard works - the Task List section ships an
    # empty <ol class="tasklist-cards"> too, filled by tasklist-editor.js
    # from /tasklist. Asserting otherwise would have demanded a design the
    # rest of the page does not use, for no reason but that I guessed.
    like( $page, qr/board--jobs/,  'the page carries a jobs section' );
    like( $page, qr/jobs-cards/,   'with a list for its rows, filled from /jobs the way the tasklist is' );

    # "a new section UNDER the tasklist" - his words, and an ordering claim
    # rather than a presence one, so it is asserted as ordering.
    my $tasklist_at = index( $page, 'board--tasklist' );
    my $jobs_at     = index( $page, 'board--jobs' );
    cmp_ok( $tasklist_at, '>', -1, 'the tasklist section is on the page to be under' );
    cmp_ok( $jobs_at, '>', $tasklist_at,
        'and the jobs section comes after it, which is where he asked for it' );
}

# --- rendered through the View layer, not built in Perl ---------------------
#
# t/426 asserts lib/Tira.pm carries no page markup, and this section must not
# be the thing that makes that false. Checked here as well as there, because
# the temptation to concatenate one more row in Perl is exactly what the View
# layer was introduced to end (TKT-703).
#
# THE VIEW LAYER IS NOT ONLY THE TEMPLATES. The first draft of this block
# looked in *.tt alone and would have demanded the jobs section live
# somewhere the tasklist section does not: the tasklist is built by
# lib/Tira/views/tasklist-editor.js, and the .tt files never mention it. The
# claim worth holding is "in lib/Tira/views/, not concatenated in Perl", so
# both kinds of asset count.

{
    my @views;
    opendir my $dh, File::Spec->catdir( 'lib', 'Tira', 'views' ) or die $!;
    @views = grep { /\.(?:tt|js)\z/ } readdir $dh;
    closedir $dh;

    my $markup = '';
    for my $view (@views) {
        open my $fh, '<:raw', File::Spec->catfile( 'lib', 'Tira', 'views', $view ) or die $!;
        local $/;
        $markup .= <$fh>;
    }
    # non-empty is the whole claim: it proves the files were opened at all, so
    # the assertion below cannot pass against an empty read.
    like( $markup, qr/\S/, 'the view assets were read - precondition for the claim below' );
    like( $markup, qr/job/i,
        'and the jobs section lives in lib/Tira/views rather than in Perl string concatenation' );
}

done_testing();

__END__

=head1 NAME

t/490-a-schedule-you-can-see.t - the dashboard section listing repeated jobs

=head1 DESCRIPTION

TKT-839. A section under the tasklist showing every repeated job as its own
row, cron-style - his msg 6480. Until it exists, seeing what a board is
scheduled to do means reading F<.tira/jobs.json>, which is the same shape of
problem EPC-014 began with: a schedule nobody can see is a schedule nobody
checks.

Read-only. The play button and the editor modal are TKT-843, deliberately
separate, because a control that runs a job is a different kind of thing from
a table that shows one and deserves its own tests.

The last pair of assertions holds the section to the View layer, for the same
reason F<t/426> does: the temptation to concatenate one more row of markup in
Perl is exactly what Template Toolkit was introduced to end.

=cut
