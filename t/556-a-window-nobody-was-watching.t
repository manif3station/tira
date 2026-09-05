#!/usr/bin/env perl
# TKT-935. job_is_due() compares only the CURRENT minute against a job's cron
# expression, with no memory of minutes it did not get to check. Nothing on
# this machine ticks police on an independent per-minute schedule - the only
# thing that calls it is a CLI command an agent happens to run, or a real
# watch daemon, and neither was running standing. Measured live: JOB-001
# through JOB-004 all showed last_run: null after 2-3 days on the board, and
# job-due only fired the instant an unrelated command happened to land on the
# job's exact due minute.
#
# Michael's decision (Q-124, 2026-09-05): job_is_due tolerates a gap between
# checks, an engine change, rather than a standing supervised monitor.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

sub board {
    my ($clock) = @_;
    my $tmp   = tempdir( CLEANUP => 1 );
    my $root  = File::Spec->catdir( $tmp, 'board' );
    my $store = File::Spec->catdir( $tmp, 'police' );
    my $tira  = Tira->new( clock => $clock );
    $tira->project_new(
        name => 'Due', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'DUS', epic_prefix => 'DUE', ticket_prefix => 'DUT',
    );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    return ( $tira, $root, $store );
}

sub said_texts {
    my ($pass) = @_;
    return map { join ' ', grep { defined && length } @{$_}{qw(message detail)} }
      @{ $pass->{violations} || [] };
}

# --- THE MEASURED BUG: an irregular caller misses an hourly job's own minute ---
#
# A hunt due at :00, but the only two checks that ever happen land at :58 (not
# due yet) and :04 (already past it, and not itself a match under exact-minute
# matching). Pre-fix this reports nothing at all - the exact failure measured
# live on JOB-001..004.

{
    my $now = '2026-09-05T09:58:00Z';
    my ( $tira, $root, $store ) = board( sub { $now } );
    $tira->job_add(
        project => $root, schedule => '0 * * * *', message => 'the hunt is due' );

    my $first = $tira->police_pass( project => $root, store => $store, world => {} );
    ok( !grep { /hunt is due/ } said_texts($first),
        'not due yet at 09:58 - the control before the gap' );

    $now = '2026-09-05T10:04:00Z';
    my $second = $tira->police_pass( project => $root, store => $store, world => {} );
    ok( ( grep { /hunt is due/ } said_texts($second) ),
        'the 10:00 window is caught on the very next check, even though 10:04 '
          . 'is not itself a due minute - an irregular caller no longer misses it' )
      or diag( 'violations: ' . scalar( @{ $second->{violations} || [] } ) );
}

# --- SETTLES: the same missed window is not re-announced every later pass ----

{
    my $now = '2026-09-05T09:58:00Z';
    my ( $tira, $root, $store ) = board( sub { $now } );
    $tira->job_add(
        project => $root, schedule => '0 * * * *', message => 'the hunt is due' );

    $tira->police_pass( project => $root, store => $store, world => {} );
    $now = '2026-09-05T10:04:00Z';
    $tira->police_pass( project => $root, store => $store, world => {} );

    $now = '2026-09-05T10:07:00Z';
    my $third = $tira->police_pass( project => $root, store => $store, world => {} );
    ok( !grep { /hunt is due/ } said_texts($third),
        'the same 10:00 window does not announce again on a third, closer check' );
}

# --- NOT APPLIED BACKWARDS: a job's first-ever check is exact-minute only ----
#
# The same reasoning unproven() already gives for cards that shipped before it
# existed: a job that has sat unchecked since before this fix landed must not
# flood the bridge with every hour it silently missed the moment it is first
# read under the new code. Its first check behaves exactly as it always did.

{
    my $now = '2026-09-05T14:37:00Z';
    my ( $tira, $root, $store ) = board( sub { $now } );
    $tira->job_add(
        project => $root, schedule => '0 * * * *', message => 'the hunt is due' );

    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    ok( !grep { /hunt is due/ } said_texts($pass),
        "a job's very first check, landing off its own minute, is not treated "
          . 'as though every hour since it was created had gone unseen' );
}

# --- A LARGE GAP STILL COMPLETES, rather than scanning without end ----------
#
# Once checked at least once, an agent stopping for a long stretch must not
# make the next check hang scanning minute by minute back to the last one.

{
    my $now = '2026-09-05T00:00:00Z';
    my ( $tira, $root, $store ) = board( sub { $now } );
    $tira->job_add(
        project => $root, schedule => '0 0 * * *', message => 'the daily hunt is due' );

    $tira->police_pass( project => $root, store => $store, world => {} );

    my $started = time;
    $now = '2026-09-08T00:05:00Z';    # three days and five minutes later - well
                                      # inside the gap cap, so still tolerated
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    cmp_ok( time - $started, '<', 10,
        'a multi-day gap resolves quickly rather than scanning minute by minute' );
    ok( ( grep { /daily hunt is due/ } said_texts($pass) ),
        'and the job still catches up rather than staying silent' );
}

# --- BEYOND THE CAP, treated as a first-ever check, not a flood -------------
#
# A gap wider than the cap falls back to exact-minute matching - the same
# "not applied backwards" reasoning as a job's genuine first check - rather
# than reporting once for a week of missed windows collapsed into one line
# that says nothing about which of them actually happened.

{
    my $now = '2026-09-05T00:00:00Z';
    my ( $tira, $root, $store ) = board( sub { $now } );
    $tira->job_add(
        project => $root, schedule => '0 0 * * *', message => 'the daily hunt is due' );

    $tira->police_pass( project => $root, store => $store, world => {} );

    $now = '2026-09-20T00:05:00Z';    # two weeks later - past the cap
    my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
    ok( !grep { /daily hunt is due/ } said_texts($pass),
        'a gap past the cap does not announce - it is treated as a fresh, '
          . 'exact-minute-only check rather than a flood of two weeks of misses' );
}

# --- job_is_due() ITSELF, the unit the rule above wires in -------------------

{
    my $tira = Tira->new( clock => sub { '2026-09-05T10:04:00Z' } );
    my $job = { schedule => '0 * * * *', enabled => 1 };

    ok( !$tira->job_is_due( $job, '2026-09-05T10:04:00Z' ),
        'unchanged: with no $since given, only the exact minute matches' );
    ok( $tira->job_is_due( $job, '2026-09-05T10:04:00Z', '2026-09-05T09:58:00Z' ),
        'given $since, a window that passed in between is caught' );
    ok( !$tira->job_is_due( $job, '2026-09-05T09:59:00Z', '2026-09-05T09:58:00Z' ),
        'and a $since that has not yet reached the due minute still says no' );
}

done_testing();

__END__

=head1 NAME

556-a-window-nobody-was-watching.t - job_is_due tolerates a gap between checks

=head1 DESCRIPTION

TKT-935. C<job_is_due()> compared only the current minute against a job's
cron expression, so an irregularly-invoked caller - the only kind this board
had running - missed almost every due window. Michael's decision (Q-124):
change C<job_is_due> to tolerate a gap, rather than run a standing supervised
monitor.

C<job_is_due> now takes an optional third argument, the timestamp it was last
checked; given one, it treats the whole span since then as due if any minute
in it matches. Omitted, it behaves exactly as before - unchanged for every
existing caller and test. The C<job-due> police rule now tracks a
last-checked timestamp per job in the same store-backed ledger
C<agent-still>'s own notified-stamp already uses, so an irregular caller (an
agent running commands every few minutes, not every one) still catches
windows it would otherwise have stepped over.

=cut
