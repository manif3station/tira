#!/usr/bin/env perl
# A green light that means the process exists, where a person reads "working".
#
# TKT-863, EPC-014. His title, verbatim: "List the monitors heatbeat with a
# red/green dim and light up on and off". He asked again by name on Telegram on
# 2026-09-03: "which ticket to show the monitors indicators on the top of the
# page? has it been done? I cannot see them."
#
# WHAT THE PAGE SAYS TODAY. TKT-861 gave each monitor row a running indicator
# taken from job_monitor_alive - the same call the monitor-dead police rule
# makes, so the page and the rule cannot disagree. It answers one question: is
# the process there.
#
# WHAT IT CANNOT SAY. A monitor that is alive but WEDGED - process up, polling
# stopped - reads as running, in green, for ever. docs/POLICIES.md admits this in
# its own words, in the monitor-dead entry: "a monitor that is alive but WEDGED
# - process up, polling stopped - reads as alive. Catching that needs the
# monitor to report progress, which needs it to cooperate."
#
# THE MONITORS NOW COOPERATE. TKT-851's feeder pipes a monitor's output through
# tira.job.feed, which stamps last_output_at as the moment it called in
# (lib/Tira/Job.pm:333). The precondition that entry called out of reach now
# holds, and nothing on the page reads the field.
#
# AND THE FIELD ALREADY REACHES THE BROWSER. lib/Tira/CLI/Browser.pm:432 copies
# every stored field into the row (%row = %{$job}) and scrubs only `running`.
# jobs-editor.js reads command, enabled, id, message, mode, running, schedule and
# schedule_kind - and not last_output_at. This is a view ignoring something it is
# already handed.
#
# WHAT THIS FILE DOES *NOT* ASSERT, and the omission is deliberate rather than an
# oversight. It says nothing about when silence becomes RED. That threshold has
# no source in the data - a monitor's schedule field is the literal string
# 'monitor', so there is no cadence to derive from, and JOB-005 on the real board
# is legitimately silent for ninety-three minutes at a time because it only
# speaks when the owner has gone quiet. Q-115 asks him where the expectation
# should come from; TKT-873 needs the same number for the police rule. Asserting
# a threshold now would be inventing his answer and then testing that I had
# invented it.
#
# So this covers what is settled: the heartbeat is rendered for a live monitor,
# it is absent where it would be a lie, and a monitor that has never spoken is
# UNKNOWN rather than fresh or stale.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

my $js = Suite::view_source('jobs-editor.js');

my $css = Suite::view_source('dashboard.css');

# non-empty is the whole claim: every assertion below reads something out of
# these two files, and an unreadable one would fail them all for the wrong
# reason.
like( $js,  qr/\S/, 'the jobs editor is there to be read' );
like( $css, qr/\S/, 'the stylesheet is there to be read' );

# --- the premise, established rather than assumed -----------------------------
#
# TKT-861's indicator is what this sits beside. If it ever stops being rendered
# from `running`, every assertion below is about a page that no longer exists.

like(
    $js,
    qr/jobs-card__up/,
    'the running indicator TKT-861 built is still on the row'
);

like(
    $js,
    qr/hasOwnProperty\.call\(\s*job,\s*"running"\s*\)/,
    'and it is still rendered on PRESENCE of running, which is what keeps a '
      . 'cron row from saying "not running" at something never meant to be up'
);

# --- the field the page is already handed and does not read -------------------

like(
    $js,
    qr/last_output_at/,
    'the heartbeat reads last_output_at - the field the feeder stamps and the '
      . 'jobs provider already sends to the page'
);

# --- a light of its own, beside the running one and not instead of it ---------
#
# Up and speaking are two facts. A monitor can be up and silent, which is the
# entire case this card exists for, so one element carrying both would rebuild
# the fault rather than fix it.

like(
    $js,
    qr/jobs-card__beat/,
    'the heartbeat is its own element, so "up" and "speaking" stay two facts '
      . 'rather than one light meaning whichever the reader assumes'
);

# --- and it is absent exactly where it would be a lie ------------------------
#
# A cron job is not meant to be up between runs and a disabled monitor is absent
# on purpose - the two silences monitor-dead already keeps. The `running` key is
# present ONLY for an enabled monitor, so rendering the heartbeat inside that
# same branch gives both silences by construction rather than by a second test
# somebody can forget.

my ($up_branch) = $js =~ /hasOwnProperty\.call\(\s*job,\s*"running"\s*\)\s*\)\s*\{(.*?)\n\s{4}\}/s;
$up_branch //= '';

# non-empty is the whole claim: the assertion below looks for the heartbeat
# inside this branch, and an empty branch would fail it for the wrong reason.
like( $up_branch, qr/\S/, 'the enabled-monitor branch has a body to inspect' );

like(
    $up_branch,
    qr/jobs-card__beat/,
    'and the heartbeat is built inside it, so a cron row and a disabled '
      . 'monitor get no heartbeat without anybody writing a second check'
);

# --- a monitor that has never spoken is unknown, not fresh and not stale ------
#
# His own word for it is already in the title: "red/green DIM". A monitor
# started before the feeder existed, or one that genuinely has not emitted a
# line, has no last_output_at - and showing that as either colour is a lie.

like(
    $js,
    qr/dataset\.beat\s*=/,
    'the heartbeat state is a data attribute, the way the running one is'
);

like(
    $js,
    qr/"unknown"/,
    'and a monitor with no last_output_at renders as unknown rather than '
      . 'being quietly counted as fresh or as stale'
);

# --- and the stylesheet can draw all of it -----------------------------------

like(
    $css,
    qr/\.jobs-card__beat/,
    'the heartbeat has styling of its own, rather than inheriting whatever '
      . 'surrounds it - the complaint TKT-859 was raised for'
);

like(
    $css,
    qr/\.jobs-card__beat\[data-beat="unknown"\]/,
    'including the dim state, which is the one a stylesheet written from the '
      . 'happy path would leave out'
);

# --- what must not change ----------------------------------------------------
#
# The running indicator is TKT-861's and this card does not get to alter it. A
# test that only demanded a new light would be satisfied by replacing the old
# one, which is the single worst outcome available here.

like(
    $css,
    qr/\.jobs-card__up\[data-running="1"\]/,
    'the running indicator keeps its own lit rule'
);

like(
    $css,
    qr/\.jobs-card__up\[data-running="0"\]/,
    'and its own unlit rule - the heartbeat is added beside it, not over it'
);

like(
    $js,
    qr/job\.running \? "Running" : "Not running"/,
    'and it still says Running or Not running, in those words'
);

done_testing();

__END__

=head1 NAME

508-a-light-that-only-says-it-is-up.t - the monitor heartbeat, beside the pulse

=head1 WHY

TKT-863. The dashboard's monitor rows showed whether the process existed and
nothing about whether it was still doing anything, so a wedged monitor - up,
polling stopped - read as green indefinitely. C<docs/POLICIES.md> named that gap
itself and said catching it needed the monitor to cooperate; TKT-851's feeder
made them cooperate, and C<last_output_at> has been arriving at the browser
unread ever since.

=head1 WHAT IS ASSERTED

That the page reads C<last_output_at>; that the heartbeat is its own element so
"up" and "speaking" stay two facts; that it is built inside the branch which
already means "an enabled monitor", so cron rows and disabled monitors stay
silent by construction; and that a monitor which has never spoken renders as
unknown rather than as either colour.

=head1 WHAT IS DELIBERATELY NOT ASSERTED

When silence becomes red. A monitor has no cadence in the record - its schedule
is the literal string C<monitor> - and the only monitor on the real board is
legitimately quiet for over an hour at a stretch. Q-115 asks the owner where
that expectation should come from, and TKT-873 needs the same answer for the
police rule. A threshold asserted here would be this file inventing his answer
and then confirming it.

=cut
