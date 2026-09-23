#!/usr/bin/env perl
# TKT-1143. job_schedule_words describes cron's day-of-month/weekday OR rule
# explicitly and deliberately (Michael's own answer to Q-119, documented in
# SKILLS.md: "0 0 1 * 1 -> At 00:00 on the 1st of each month, and also every
# Monday" - real POSIX cron semantics: a schedule with BOTH day fields
# restricted fires when EITHER matches). But _cron_minute_matches, the
# function job_is_due actually calls to decide whether a job fires, ANDs
# every field including day-of-month and weekday - so a schedule described
# as firing on the 1st AND ALSO every Monday actually only fired on days
# that were both.
#
# WRITTEN RED.
#
# INCIDENT NOTE: an earlier pass at this exact fix was written, tested green,
# and stashed - then destroyed by an unrelated `git reflog expire --all` +
# `git gc --prune=now` during a different ticket's cleanup (see MISTAKE.md,
# CODE: RESET-WIPED-THE-NEIGHBOR). This file is a full reimplementation from
# the ticket's own preserved acceptance criteria, not a recovery.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-23T12:00:00Z'} );
$tira->project_new(
    name => 'Either Day', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'EDS', epic_prefix => 'EDE', ticket_prefix => 'EDT',
);

# --- both restricted: OR, not AND -------------------------------------------
#
# '0 0 1 * 1': midnight, the 1st of the month, OR any Monday.

my $both = $tira->job_add(
    project => $root, schedule => '0 0 1 * 1',
    command => 'perl -e print+1',
);

# 2026-09-21 is a Monday, not the 1st.
ok( $tira->job_is_due( $both, '2026-09-21T00:00:00Z' ),
    'a Monday that is not the 1st is due - the weekday half of the OR' );

# 2026-09-01 is a Tuesday, not a Monday, but is the 1st.
ok( $tira->job_is_due( $both, '2026-09-01T00:00:00Z' ),
    'the 1st that is not a Monday is due - the day-of-month half of the OR' );

# 2026-09-15 is a Tuesday, and not the 1st - neither half matches.
ok( !$tira->job_is_due( $both, '2026-09-15T00:00:00Z' ),
    'a day that is neither the 1st nor a Monday is not due' );

# --- only one restricted: existing single-field behavior, unchanged --------

my $dom_only = $tira->job_add(
    project => $root, schedule => '0 0 1 * *',
    command => 'perl -e print+1',
);
ok( $tira->job_is_due( $dom_only, '2026-09-01T00:00:00Z' ),
    'day-of-month only: due on the 1st' );
ok( !$tira->job_is_due( $dom_only, '2026-09-21T00:00:00Z' ),
    'day-of-month only: not due on a Monday that is not the 1st - unaffected by the OR fix' );

my $dow_only = $tira->job_add(
    project => $root, schedule => '0 0 * * 1',
    command => 'perl -e print+1',
);
ok( $tira->job_is_due( $dow_only, '2026-09-21T00:00:00Z' ),
    'weekday only: due on a Monday' );
ok( !$tira->job_is_due( $dow_only, '2026-09-01T00:00:00Z' ),
    'weekday only: not due on the 1st when it is not a Monday - unaffected by the OR fix' );

# --- neither restricted: unaffected, fires every day -----------------------

my $daily = $tira->job_add(
    project => $root, schedule => '0 0 * * *',
    command => 'perl -e print+1',
);
ok( $tira->job_is_due( $daily, '2026-09-21T00:00:00Z' ), 'daily: due on a Monday' );
ok( $tira->job_is_due( $daily, '2026-09-15T00:00:00Z' ), 'daily: due on an ordinary Tuesday' );

# --- restricted-but-full-range: still "restricted" - cron's rule is
# syntactic (not "*"), not "does the expanded set happen to cover the whole
# range". Codex review caught this: an earlier version of the fix checked
# the parsed value set's size, which wrongly treated '1-31' as unrestricted.

my $explicit_dom = $tira->job_add(
    project => $root, schedule => '0 0 1-31 * 1',
    command => 'perl -e print+1',
);
ok( $tira->job_is_due( $explicit_dom, '2026-09-15T00:00:00Z' ),
    "'1-31' is still restricted (not the literal '*'), so ORs with weekday - due on an ordinary Tuesday, since 1-31 covers it" );
ok( $tira->job_is_due( $explicit_dom, '2026-09-21T00:00:00Z' ),
    "and due on a Monday too" );

# The 0/7 Sunday-alias interaction: '0-7' explicitly names every weekday
# value cron stores (including both spellings of Sunday), so it is a
# full-range set, but still written as an explicit range, not '*'.

my $explicit_dow = $tira->job_add(
    project => $root, schedule => '0 0 1 * 0-7',
    command => 'perl -e print+1',
);
ok( $tira->job_is_due( $explicit_dow, '2026-09-01T00:00:00Z' ),
    "'0-7' is still restricted, so ORs with day-of-month - due on the 1st" );
ok( $tira->job_is_due( $explicit_dow, '2026-09-15T00:00:00Z' ),
    "and due on an ordinary Tuesday too, since 0-7 covers every weekday" );

# */1 - a step-off-star form, which real cron treats the same as a bare '*':
# unrestricted, so with only weekday actually restricted this stays AND
# (single-field behavior, same as dom_only/dow_only above), not OR.

my $step_dom = $tira->job_add(
    project => $root, schedule => '0 0 */1 * 1',
    command => 'perl -e print+1',
);
ok( !$tira->job_is_due( $step_dom, '2026-09-15T00:00:00Z' ),
    "'*/1' is unrestricted like '*' - an ordinary Tuesday is not due (AND with the restricted weekday field)" );
ok( $tira->job_is_due( $step_dom, '2026-09-21T00:00:00Z' ),
    'and a Monday is due' );

done_testing();

__END__

=head1 NAME

1157-a-day-that-promised-either.t - both day fields restricted means OR, not AND

=head1 DESCRIPTION

TKT-1143. C<job_schedule_words> already described cron's day-of-month/weekday
OR rule correctly; C<_cron_minute_matches> did not implement it, ANDing every
field unconditionally. Fixed with a C<_both_days_restricted> helper in
C<Tira::Job::Schedule> that detects when both fields are restricted (cover
less than their full value range) and, only in that case, matches on EITHER
field rather than both - matching real POSIX cron semantics and the wording
this project already promised.

=cut
