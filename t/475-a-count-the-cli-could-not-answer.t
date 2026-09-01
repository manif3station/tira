#!/usr/bin/env perl
# TKT-808. TKT-797 added a live aggregate count to the browser dashboard's
# sticky header: how many cards have an unanswered question, and how many
# tasklist items are outstanding, both computed project-wide in one glance.
# The CLI had no equivalent - tira.question.list requires --ref (one card
# at a time), and tira.search --text needs a text term, not a status
# filter, so there was no single command answering "how many questions are
# outstanding right now" project-wide without iterating every card by hand
# or opening the browser. An agent working purely through the CLI (the
# common case for this whole project) had strictly less visibility into
# this than a human looking at the browser.
#
# Deliberately does NOT match hero-counts.js's current task-count behavior:
# that browser display counts every tasklist item regardless of status
# (TKT-817, a separate, tracked bug), while this command counts only
# pending and working items - what "outstanding" actually means.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T13:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Outstanding', dir => $root, members => ['ada'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'OSS', epic_prefix => 'OSE', ticket_prefix => 'OST',
);

my $waiting = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Waiting on an answer' );
$tira->question_add( project => $root, ref => $waiting->{ref}, author => 'ada', text => 'Which way?', reason => 'unsure' );

my $answered = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Already answered' );
my $q = $tira->question_add( project => $root, ref => $answered->{ref}, author => 'ada', text => 'Which way?', reason => 'unsure' );
$tira->question_answer( project => $root, ref => $answered->{ref}, id => $q->{id}, text => 'This way', author => 'ada' );

my $clean = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'No questions at all' );

my $summary = $tira->outstanding_summary( project => $root );
is( $summary->{questions}, 1, 'exactly the one card with a genuinely unanswered question is counted - the fix' );

$tira->tasklist_add( project => $root, text => 'pending task' );
my $working = $tira->tasklist_add( project => $root, text => 'working task' );
$tira->tasklist_update( project => $root, id => $working->{id}, status => 'working' );
my $done = $tira->tasklist_add( project => $root, text => 'done task' );
$tira->tasklist_update( project => $root, id => $done->{id}, status => 'done' );

my $after_tasks = $tira->outstanding_summary( project => $root );
is( $after_tasks->{tasks}, 2, 'only pending and working items count as outstanding - a done item does not, unlike hero-counts.js\'s current (buggy, TKT-817) count' );
is( $after_tasks->{questions}, 1, 'the question count is unaffected by tasklist activity' );

# --- an unexpected status value is never counted as outstanding, only ------
# --- pending (0) and working (1) are explicitly matched - Codex review -----

{
    my $path = File::Spec->catfile( $root, '.tira', 'tasklist.json' );
    open my $fh, '<', $path or die "Cannot read $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw =~ s/"status"\s*:\s*0/"status":99/;    # corrupt the pending task's status
    open my $out, '>', $path or die "Cannot write $path: $!";
    print {$out} $raw;
    close $out;
}
my $after_corrupt = $tira->outstanding_summary( project => $root );
is( $after_corrupt->{tasks}, 1,
    'a status outside {0,1} (a stored value neither pending nor working) is not counted as outstanding - '
      . 'explicit membership, not merely "not done"' );

done_testing;

__END__

=head1 NAME

t/475-a-count-the-cli-could-not-answer.t - a CLI command answers
project-wide outstanding question/task counts

=head1 DESCRIPTION

TKT-797 gave the browser dashboard a live header count of unanswered
questions and outstanding tasklist items, project-wide. No CLI command
answered the same question - an agent working purely through the CLI
had to iterate every card by hand, or open a browser, to know what a
human glancing at the dashboard already saw.

C<outstanding_summary> answers it directly: C<questions> counts cards
with at least one genuinely unanswered question (matching the same
C<_card_blocked>/C<_policy_questions> logic the dashboard itself uses),
and C<tasks> counts tasklist items in status pending or working -
deliberately NOT matching hero-counts.js's own current task count,
which is a separate, tracked bug (TKT-817) counting every item
regardless of status. TKT-808.

=cut
