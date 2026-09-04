#!/usr/bin/env perl
# The header counts what is fine and says nothing about what is wrong.
#
# TKT-924, EPC-014. His message, 6812, and the second half is easy to read past:
#
#   Add
#   X monitor(s) stopped if any
#   X schedual jobs is disabled if any along the line of
#   `0 questions awaiting - 0 tasks`
#   Same for quesitons and tasks, if 0 no need to show
#   At the top right of the screen
#
# TWO REQUESTS, NOT ONE. The counts he wants added are the obvious half. The
# other is a change to what already ships: today the header prints "0 questions
# awaiting - 0 tasks" on a board with nothing outstanding, and he is asking for
# that to disappear. A card that only added two counts would satisfy the first
# line and miss the request - and would make the header WORSE, because a stopped
# monitor would then arrive beside two zeroes competing for the same corner.
#
# THE PLACE HE IS ALREADY LOOKING is the argument. A stopped monitor is exactly
# the thing somebody needs to notice, and EPC-014 exists because three of them
# died and nobody did.
#
# WHERE THE VERDICT COMES FROM, and it is not a new one. The jobs provider
# already decides liveness with Tira::Job::job_monitor_alive against the process
# table - the same call monitor-dead makes and the same one the row indicator
# shows (TKT-861). The header must read that rather than compute a second
# opinion, or the top of the page and the middle of it can disagree about
# whether a monitor is up.
#
# AND A DISABLED MONITOR IS NOT A STOPPED ONE. It is absent on purpose, which is
# why monitor-dead is silent about it. The provider gives it no `running` field
# at all, so "not counted twice" is a property of the data rather than a rule
# the page has to remember - and that is asserted below as a control, because it
# is what the claim rests on.
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
use Suite ();
use Tira;

my ( $tira, $root );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Header', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'HDS', epic_prefix => 'HDE', ticket_prefix => 'HDT',
    );
}

# --- what the page is given -------------------------------------------------
#
# The controls, and they pass before the change as well as after: the counts
# this card adds are readable from what the provider already sends, and the
# double-count his criteria warn about is impossible rather than avoided.

my %provider = do {
    require Tira::CLI::Browser;
    Tira::CLI::Browser::providers( tira => $tira, project => $root );
};

my $stopped = $tira->job_add( project => $root, schedule => 'monitor',
    command => 'a-poller-that-is-not-running', author => 'claude' );

my $disabled = $tira->job_add( project => $root, schedule => 'monitor',
    command => 'a-poller-switched-off', author => 'claude' );
$tira->job_update( project => $root, id => $disabled->{id}, enabled => 0,
    author => 'claude' );

my $cron = $tira->job_add( project => $root, schedule => '0 * * * *',
    command => 'a-cron-job', author => 'claude' );

my $rows = JSON::PP->new->decode( $provider{jobs}->( {} ) );

# non-empty is the whole claim: an empty listing would make every assertion
# below vacuously true and send a later fix at the wrong layer.
is( scalar @{$rows}, 3, 'the three jobs reached the page' );

my %row = map { $_->{id} => $_ } @{$rows};

is( $row{ $stopped->{id} }{running}, JSON::PP::false,
    'AN ENABLED MONITOR WITH NO PID IS REPORTED NOT RUNNING, by the same '
      . 'job_monitor_alive the monitor-dead rule uses. That is the verdict the '
      . 'header must read rather than one it works out for itself, or the top '
      . 'of the page and the row halfway down it can disagree' );

ok( !exists $row{ $disabled->{id} }{running},
    'A DISABLED MONITOR HAS NO LIVENESS AT ALL - not false, absent. It is off '
      . 'on purpose, which is why monitor-dead is silent about it, and it is '
      . 'what makes "a disabled monitor is not counted twice" a property of '
      . 'the data rather than a rule the page has to remember' );

ok( !$row{ $disabled->{id} }{enabled},
    'and it is the one that answers the disabled count' );

ok( !exists $row{ $cron->{id} }{running},
    'a cron job has none either - it is not supposed to be up between runs' );

# --- and what the header does with it ----------------------------------------
#
# Source-read, the way every view assertion in this suite is, and through
# Suite::view_source rather than by naming a path - t/486's rule, widened on
# TKT-921. This suite drives no browser and browser checks are his.

my $header = Suite::view_source('hero-counts.js');

ok( length $header, 'the header script was read' );

like( $header, qr{fetch\(\s*"/jobs"},
    'THE HEADER ASKS ABOUT JOBS AT ALL. Today it counts two things - waiting '
      . 'cards in the DOM and the tasklist over fetch - and knows nothing '
      . 'about a monitor. A stopped monitor is the thing EPC-014 exists for, '
      . 'and the top right is where he is already looking' );

like( $header, qr/running\s*===\s*false/,
    'and counts a monitor as stopped from the provider\'s own verdict rather '
      . 'than from a pid it reads itself - false rather than falsy, because '
      . 'ABSENT means "not applicable" for a cron job and a disabled one' );

like( $header, qr/\.enabled/,
    'and counts a disabled job separately, which is the second half of his '
      . 'request' );

# THE HALF THAT IS A CHANGE RATHER THAN AN ADDITION.
unlike( $header, qr/const parts\s*=\s*\[\s*questionWord/,
    'A ZERO IS NOT SHOWN. Today the questions part is pushed unconditionally - '
      . '`const parts = [questionWord(questionTotal) + " awaiting"]` - so a '
      . 'board with nothing outstanding reads "0 questions awaiting" in the '
      . 'place somebody looks for a problem. His words: "Same for quesitons '
      . 'and tasks, if 0 no need to show"' );

like( $header, qr/if\s*\(\s*questionTotal\s*\)/,
    'so each part is added only when it has something to say' );

# And the whole thing goes away when there is nothing to report, which is what
# "if any" means and is the assertion that stops the fix being four ifs that
# still leave a separator or an empty bullet behind.
like( $header, qr/parts\.length/,
    'AND THE HEADER IS EMPTY WHEN EVERYTHING IS FINE, rather than showing a '
      . 'stray separator between four counts that are all absent' );

done_testing();

__END__

=head1 NAME

539-a-header-that-counts-what-is-fine.t - the dashboard header, and what it omits

=head1 WHY

TKT-924, from his Telegram 6812. The header prints C<0 questions awaiting - 0
tasks> on a board with nothing outstanding, and says nothing at all about a
monitor that has stopped - which is the one thing EPC-014 was filed for.

=head1 WHAT IS ASSERTED

First the controls, which pass before the change: the jobs provider already
reports an enabled monitor with no pid as C<running: false>, gives a disabled
monitor and a cron job B<no> C<running> field at all, and carries C<enabled>.
So the two new counts are readable from data the page already receives, and "a
disabled monitor is not counted twice" is a property of that data rather than a
rule the view must remember.

Then the claims: that the header asks about jobs, counts stopped monitors from
the provider's own verdict rather than a second opinion, counts disabled jobs,
shows no count that is zero - including the two that ship today - and renders
nothing at all when there is nothing to report.

=head1 WHAT IS NOT ASSERTED

That the rendered header looks right. This suite drives no browser; browser
checks are his.

=cut
