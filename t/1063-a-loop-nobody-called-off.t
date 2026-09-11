#!/usr/bin/env perl
# TKT-1063. restart_every restarted a command forever, however many times in
# a row it crashed - a genuinely crash-looping command (bad config, a
# dependency missing after a deploy) restarted silently forever with no
# escalation to a human, because monitor-dead never fires while the
# supervisor's own pid stays alive throughout. Raised while triaging
# TKT-1061 (his own auto-restart-on-crash request, discarded as a duplicate
# of TKT-891's already-shipped mechanism) - he confirmed via TG (msg #8055,
# "Yes please") that this narrower gap should be filed and fixed on its own.
#
# THE CAP IS ON CONSECUTIVE FAST EXITS, not on restarts overall: a monitor
# that crashes once a month and otherwise runs for weeks must not be judged
# by a streak from six months ago, so a run at least as long as the crash-loop
# threshold resets the count. Both the wait between restarts and the clock
# measuring each run's duration are injectable, for the same reason t/538
# injects the wait: a monitor that restarts itself has no end, and a
# crash-loop cap measured in real seconds cannot be exercised by actually
# crashing for real seconds in a test.
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
use Tira::CLI::Job::Feeder;

my $BOARD = 'Capped Board';

my ( $tira, $root );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => $BOARD, dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'CPS', epic_prefix => 'CPE', ticket_prefix => 'CPT',
    );
}

# --- a command that always exits at once hits the cap and stops -------------

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => '/bin/true', restart_every => 3, author => 'claude' );

    my @waited;
    my $clock_tick = 0;
    my $ran = Tira::CLI::Job::Feeder::run_feeder( $tira,
        { project => $root, id => $job->{id},
          wait => sub { push @waited, $_[0]; return 1 },

          # Every run measures as zero seconds - always under the cap's
          # threshold - since the clock never advances between the start and
          # end of a run, only between runs (which this loop does not read).
          now => sub { return $clock_tick } },
        1, 25 );

    is( scalar @waited, 4,
        'the loop restarted four times before the cap stopped it on the '
          . 'fifth crash, rather than waiting for ever' );
    my @wrong_interval = grep { $_ != 3 } @waited;
    ok( !@wrong_interval, 'every wait used the job\'s own interval' );

    my ($capped) = grep { ( $_->{id} // '' ) eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    is( $capped->{restart_cap_hit}, 5,
        'the job record carries the attempt count the cap was hit at' );
    ok( defined $capped->{restart_cap_hit_at}, 'and when it happened' );

    my $recent = $capped->{recent} || [];
    ok( ( grep { /cap reached/ } @{$recent} ),
        'and the card\'s own log says why auto-restart stopped, not just '
          . 'that it did' );
}

# --- a command that runs a while resets the count, and is never capped ------

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => '/bin/true', restart_every => 3, author => 'claude' );

    my @waited;
    my $tick = 0;
    my $ran = Tira::CLI::Job::Feeder::run_feeder( $tira,
        { project => $root, id => $job->{id},

          # Ten restarts, none capped - the count resets every run since
          # each pair of calls to $now (once before the command, once after)
          # advances by more than the crash threshold, regardless of how
          # many times wait() itself has been called.
          wait => sub { push @waited, $_[0]; return @waited < 10 },
          now  => sub { return $tick += 100 } },
        1, 25 );

    is( scalar @waited, 10,
        'ten restarts of a command that keeps actually running are none of '
          . 'them capped - the count resets each time, so a monitor that '
          . 'restarts often but genuinely runs is never mistaken for one '
          . 'crash-looping' );

    my ($uncapped) = grep { ( $_->{id} // '' ) eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    ok( !defined $uncapped->{restart_cap_hit},
        'and its record carries no cap marker at all' );
}

# --- a run of exactly the threshold counts as healthy, not a crash ---------
#
# < not <=, so a run lasting exactly the threshold is NOT a crash - the
# boundary itself, asserted directly rather than left to the two tests
# either side of it whose margins are wide enough to hide an off-by-one.

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => '/bin/true', restart_every => 3, author => 'claude' );

    my @waited;
    my $tick = 0;
    Tira::CLI::Job::Feeder::run_feeder( $tira,
        { project => $root, id => $job->{id},
          wait => sub { push @waited, $_[0]; return @waited < 6 },

          # Every run measures as EXACTLY 5 seconds - the threshold itself,
          # not one second either side of it.
          now => sub { return $tick += 5 } },
        1, 25 );

    is( scalar @waited, 6,
        'six restarts of a command that runs exactly the threshold length '
          . 'are none of them capped - the boundary itself counts as '
          . 'healthy, not a crash' );

    my ($job_now) = grep { ( $_->{id} // '' ) eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    ok( !defined $job_now->{restart_cap_hit},
        'and its record carries no cap marker' );
}

# --- and a genuine police pass folds the count into its own alert ----------
#
# Not a source-read: the previous SEE ALSO block confirms the WORDING exists
# in the engine's source, but reading the source proves nothing about
# whether it is ever actually reached. This runs the real monitor-dead rule
# against a real capped, dead monitor and reads what it actually said.

{
    $tira->policy_add( project => $root, rule => 'monitor-dead', action => 'log-only' );

    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => '/bin/does-not-exist-and-is-not-running', author => 'claude' );
    $tira->job_restart_capped( project => $root, id => $job->{id}, count => 5 );

    my $world = { branches => [], worktrees => [], processes => [], containers => [] };
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $root, 'police-state' ), world => $world );
    my ($found) = grep { ( $_->{detail} // '' ) =~ /\Q$job->{id}\E/ }
      @{ $pass->{violations} || [] };
    ok( $found, 'monitor-dead fired for the capped, not-running monitor' );
    like( $found->{detail} // '', qr/stopped auto-restarting after 5 attempts/,
        'and the alert itself named the attempt count, live from a real '
          . 'police pass rather than merely being present in the source' )
      if $found;
}

# --- a fresh manual start clears any cap a previous run left behind ---------

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => '/bin/true', author => 'claude' );
    $tira->job_restart_capped( project => $root, id => $job->{id}, count => 5 );

    my ($before) = grep { ( $_->{id} // '' ) eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    is( $before->{restart_cap_hit}, 5, 'sanity: the cap marker is there before the start' );

    $tira->job_started( project => $root, id => $job->{id}, pid => 99999 );

    my ($after) = grep { ( $_->{id} // '' ) eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    ok( !defined $after->{restart_cap_hit},
        'a fresh start clears the previous cap - a deliberate restart is a '
          . 'fresh chance, not a continuation of the crash streak that '
          . 'stopped the last run' );
}

# --- monitor-dead names the attempt count when a capped monitor is dead ----

{
    my $source = Suite::engine_source();
    like( $source, qr/restart_cap_hit/,
        'monitor-dead reads the cap marker from the job record' );
    like( $source,
        qr/stopped auto-restarting after \$capped attempts/,
        'and folds the attempt count into its own message, so the alert '
          . 'says restart was already attempted rather than reading like a '
          . 'cold start' );
}

done_testing();

__END__

=head1 NAME

t/1063-a-loop-nobody-called-off.t - restart_every stops after a crash-loop cap

=head1 DESCRIPTION

C<restart_every> restarted a crashing command for ever, with no bound and no
escalation to a human - C<monitor-dead> never fires while the supervisor's
own pid stays alive. C<Tira::CLI::Job::Feeder::run_feeder> now counts
consecutive runs shorter than a crash-loop threshold (5 seconds); a run at
least that long resets the count, and 5 short runs in a row stops
auto-restart, writes a line to the job's own log explaining why, and calls
the new C<Tira::Job::job_restart_capped> to record the attempt count on the
job. C<monitor-dead> reads that count and folds it into its own alert.
C<job_started> clears any previous cap marker, since a deliberate fresh
start is a fresh chance rather than a continuation of whatever crash streak
stopped the last run.

=head1 SEE ALSO

L<t/538-a-monitor-that-reads-as-itself.t>

=cut
