#!/usr/bin/env perl
# A monitor running a police pass, and the pass deciding it is not there.
#
# TKT-874, absorbed into TKT-893, EPC-014. Taken first of the nine because it is
# the instrument: while a monitor that runs a police pass reports ITSELF dead, no
# observation of the other eight members can be believed.
#
# THE FAULT IS ONE LINE, in lib/Tira/CLI/Serve.pm's _processes_from:
#
#     next if $pid == $$;
#
# The process table is built with the CURRENT process removed. So a monitor
# whose command is a police pass - which is the arrangement this project itself
# recommends, and which JOB-006 was a clumsy attempt at - is absent from the very
# table job_monitor_alive searches to decide whether it is alive.
#
# TWO CONSUMERS, OPPOSITE NEEDS, AND ONE LIST. That is the whole of it:
#
#   leftover-process  walks the table looking for things that should have
#                     stopped. It must NOT see the current process, or police
#                     reports itself as a leftover on every pass. That is why
#                     the exclusion was written, and it was right for the only
#                     consumer that existed at the time.
#
#   monitor-dead      walks the same table asking whether a recorded pid is
#                     still there. It MUST see the current process, because a
#                     monitor running this pass is as alive as anything gets.
#
# So the exclusion is in the wrong place rather than wrong: it belongs to the
# rule that needs it, not to the gathering that both share. Removing it without
# putting it back in leftover-process would trade a monitor reported dead for
# police accusing itself, which is the same bug wearing the other coat - and the
# last block here is what stops that.
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
use Tira::CLI::Serve;

# --- the table as it is read, from output where the answer is known -----------
#
# _processes_from is kept apart from asking the machine for the table precisely
# so it can be proved against fixed text. These are real ps lines in the format
# the sub documents - a pid, a start stamp, then the command.

my $mine  = $$;
my $other = $$ + 1;

# BOTH RUN THE SAME COMMAND, deliberately. The last block asks whether
# leftover-process reports one and not the other, and it can only mean anything
# if the pattern matches both - otherwise "it did not report me" is just "the
# pattern missed me".
#
# The first draft used d2 tira.policy.bridge for the other process and proved
# nothing twice over: "tira.police" is not a substring of "tira.policy" (they
# differ at the e), and _is_bridge_tail exempts the bridge from this rule on
# purpose anyway (TKT-379). The fixture has to avoid the one process the rule
# is written never to report.
my $lines = [
    "  $mine Tue Sep  3 19:00:00 2026 perl /usr/bin/d2 tira.police",
    " $other Tue Sep  3 18:00:00 2026 perl /usr/bin/d2 tira.police",
];

my $table = Tira::CLI::Serve::_processes_from($lines);

# non-empty is the whole claim: every assertion below searches this list, and an
# empty one would fail them for the wrong reason.
cmp_ok( scalar @{$table}, '>', 0, 'the table was read at all' );

my %seen = map { $_->{pid} => $_ } @{$table};

ok( $seen{$other}, 'another process is in the table, which is the easy half' );

ok(
    $seen{$mine},
    'AND SO IS THIS ONE. A monitor whose command is a police pass is the '
      . 'current process during that pass, and a table built without it makes '
      . 'job_monitor_alive answer "not there" about something that is running'
);

# --- and it is a whole record, not a placeholder ------------------------------
#
# monitor-dead compares the start time the BOARD recorded against the one the
# process table reports (TKT-860), and falls back to the command only where no
# start time exists. A self-entry missing either would be present and useless.

is( ( $seen{$mine} || {} )->{command},
    'perl /usr/bin/d2 tira.police',
    'with its command, which is what the liveness check confirms a pid with' );

ok( defined( ( $seen{$mine} || {} )->{started_at} ),
    'and its start time, which is what TKT-860 made liveness compare' );

# --- so job_monitor_alive can find a monitor that is running this pass --------

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'SelfDead', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'SDS', epic_prefix => 'SDE', ticket_prefix => 'SDT',
    );

    # The board's clock is fixed to the moment the fixture process claims to
    # have started, because TKT-860 made liveness compare the two within a
    # minute in BOTH directions: later means a recycled pid, earlier means the
    # process predates the spawn and cannot be ours. A live clock against a
    # 2026-09-03 19:00 fixture is hours apart and would be rejected correctly -
    # the test would fail for a reason that has nothing to do with TKT-874.
    $tira->{clock} = sub { '2026-09-03T19:00:00+0000' };

    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'd2 tira.police' );
    $tira->job_started( project => $root, id => $job->{id}, pid => $mine );

    my ($stored) = grep { $_->{id} eq $job->{id} }
      @{ $tira->job_list( project => $root ) };

    ok( Tira::Job::job_monitor_alive( $stored, $table ),
        'a monitor whose pid is the process running this very pass is alive - '
          . 'which is the finding TKT-874 was raised for, seen from the rule '
          . 'that acts on it'
    );
}

# --- and leftover-process still does not accuse itself ------------------------
#
# THIS IS THE BLOCK THAT MAKES THE FIX A FIX. The exclusion exists for a reason:
# leftover-process walks this same table looking for things that should have
# stopped, and police is always in it. Removing the line and stopping there
# would trade "a monitor is reported dead" for "police reports itself as a
# leftover on every pass" - the same fault wearing the other coat.

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Leftover', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'LOS', epic_prefix => 'LOE', ticket_prefix => 'LOT',
    );

    $tira->policy_add(
        project => $root, rule => 'leftover-process',
        pattern => 'tira.police', age => '0s', action => 'log-only' );

    my $store = File::Spec->catdir( $tmp, 'police-store' );
    my $pass  = $tira->police_pass(
        project => $root, store => $store,
        world   => { processes => $table } );
    my $found = $pass->{violations};

    # Both processes carry the same command, so the two cannot be told apart by
    # the detail text - which is the point. What distinguishes them is that one
    # of them is this process, and the rule is asked to report exactly one.
    my @reported = @{ $found || [] };

    is( scalar @reported, 1,
        'leftover-process does not report the process it is running inside - '
          . 'the exclusion moves to the rule that needs it rather than being '
          . 'deleted, or this fix just breaks the other direction'
    );

    # WITHOUT THIS THE ASSERTION ABOVE IS SATISFIED BY SILENCE. Two processes
    # match the pattern and exactly one of them is this one, so "reported none"
    # and "reported the right one" both leave the count at something a careless
    # test would accept. Naming the number is what separates them.
    like( ( $reported[0] || {} )->{detail} // '', qr/still running/,
        'and what it reports is the other process - the rule has not simply '
          . 'gone quiet, which is the other way to pass the assertion above' );
}

done_testing();

__END__

=head1 NAME

511-a-monitor-that-reported-itself-dead.t - the process table, minus the asker

=head1 WHY

TKT-874, inside TKT-893. C<_processes_from> drops the current process
(C<< next if $pid == $$ >>), so a monitor whose command is a police pass is
absent from the table C<job_monitor_alive> searches - and reports itself dead
during its own pass.

The exclusion is not wrong, it is in the wrong place. C<leftover-process> needs
it and C<monitor-dead> is broken by it, and they read one list.

=head1 WHAT IS ASSERTED

That the current process appears in the table with its command and start time;
that C<job_monitor_alive> therefore finds a monitor running the current pass;
and that C<leftover-process> still does not accuse itself while still reporting
another process matching the same pattern.

That last pair is the point. Deleting the line alone trades a monitor reported
dead for police reported as a leftover, and a rule that has simply gone silent
would pass the first half of it.

=cut
