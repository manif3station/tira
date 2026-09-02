#!/usr/bin/env perl
# A live monitor reported dead, because d2 is a wrapper.
#
# Found in production at 16:46 on 2026-09-02, on the first real use of the
# feature shipped an hour earlier. JOB-005 was created with the command
# "d2 is-agent-sleeping" and started by tira.job.start, which recorded pid
# 1217031. That process was alive. The bridge said:
#
#   NOTE | VIO-2522 | board | monitor JOB-005 is not running: d2 is-agent-sleeping
#
# d2 execs perl with the resolved path, so the process table holds
#
#   /usr/bin/perl -I /home/mv/perl5/lib/perl5 /home/mv/.developer-dashboard/cli/is-agent-sleeping
#
# and "d2 is-agent-sleeping" is not a substring of that. TKT-860.
#
# WHY THE ORIGINAL REASONING WAS WRONG, since the comment asserting it is still
# in lib/Tira/Job.pm: "ps reports the command as the kernel has it, which
# carries the interpreter, the absolute path and whatever the shell expanded -
# none of which the stored command has to match character for character". True
# when the stored command IS the program that ends up running. False for a
# WRAPPER, whose own name is gone from the child's argv the moment it execs.
# Nearly every command on this board begins with d2, so this is the normal case
# rather than an edge one.
#
# THE FIX IS TO STOP GUESSING, and it turns out to need no new stored field.
# The start times already identify the process: we record the moment we spawned
# it, and a pid that was REUSED belongs to something that started later. So when
# both stamps are known, the pid and the start time settle identity by
# themselves, and the command comparison is only needed where no start time
# exists - which is Windows, where tasklist supplies none.
#
# That reordering is the whole change. It also makes the check STRONGER against
# the failure TKT-842 was written for: a reused pid is rejected on its start
# time, which is a fact, rather than on its command text, which can coincide.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
require Tira::Job;

ok( Tira::Job->can('job_monitor_alive'), 'the liveness check is there to be asked' );

my $STARTED = '2026-09-02T16:46:15+0100';

# Exactly what the board stored and exactly what ps showed, transcribed from
# the incident rather than invented, so this test fails for the reason the
# bridge failed.
my $wrapped = {
    schedule_kind => 'monitor',
    pid           => 1217031,
    command       => 'd2 is-agent-sleeping',
    started_at    => $STARTED,
};
my $real_argv =
  '/usr/bin/perl -I /home/mv/perl5/lib/perl5 /home/mv/.developer-dashboard/cli/is-agent-sleeping';

# The control: the containment test really does fail on this pair, so the
# assertion below is about the fix and not about a mistyped fixture.
is( index( $real_argv, $wrapped->{command} ), -1,
    'the stored command is genuinely not a substring of the argv - the bug, in one line' );

# --- the assertion this card exists for -------------------------------------

ok( Tira::Job::job_monitor_alive( $wrapped,
        [ { pid => 1217031, started_at => $STARTED, command => $real_argv } ] ),
    'a d2-wrapped monitor whose process is running reads as ALIVE' );

# --- and the guarantee it must not buy back ---------------------------------
#
# The whole point of TKT-842 was that a dead monitor must never read as alive.
# Accepting the pid on its start time must not weaken that: a pid taken over by
# something else started LATER, and that is what rejects it.

ok( !Tira::Job::job_monitor_alive( $wrapped,
        [ { pid => 1217031, started_at => '2026-09-02T18:30:00+0100',
                command => $real_argv } ] ),
    'the same pid running the same program, started hours later, is a REUSED pid and dead' );

ok( !Tira::Job::job_monitor_alive( $wrapped,
        [ { pid => 999999, started_at => $STARTED, command => $real_argv } ] ),
    'and a pid that is not in the table at all is dead' );

ok( Tira::Job::job_monitor_alive( $wrapped,
        [ { pid => 1217031, started_at => '2026-09-02T16:46:45+0100',
                command => $real_argv } ] ),
    'a few seconds of slack is still allowed, since the pid is recorded after the spawn' );

# --- where no start time exists, the command is still what decides ----------
#
# Windows supplies none: tasklist reports a program name and nothing else. The
# command comparison is not deleted, it becomes the fallback for exactly that
# case - which is why the two Windows assertions in t/493 still hold.

ok( Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => 42, command => 'tira-poll --once' },
        [ { pid => 42, started_at => undef, command => 'tira-poll --once' } ] ),
    'with no start times the command still settles it' );

ok( !Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => 42, command => 'tira-poll --once' },
        [ { pid => 42, started_at => undef, command => 'something-else' } ] ),
    'and a different command with no start times is still dead' );

# A record written before this change carries no started_at of its own. It must
# keep working by the old comparison rather than becoming permanently dead.
ok( Tira::Job::job_monitor_alive(
        { schedule_kind => 'monitor', pid => 7, command => 'tira-legacy --poll' },
        [ { pid => 7, started_at => '2026-09-02T10:00:00+0100',
                command => '/usr/bin/tira-legacy --poll' } ] ),
    'a record with no recorded start time falls back to the command rather than reading dead' );

done_testing();

__END__

=head1 NAME

495-a-wrapper-is-not-its-own-argv.t - a live monitor reported dead

=head1 THE INCIDENT

TKT-860. On 2026-09-02 at 16:46, C<monitor-dead> reported JOB-005 as not
running while its process was alive. C<d2> is a wrapper: it execs C<perl> with
the resolved cli path, so the stored command C<d2 is-agent-sleeping> never
appears in the child's argv and the containment check in
C<job_monitor_alive> returned false.

Nearly every command on this board begins with C<d2>, so the rule written to
end a silence would have cried on every pass about every monitor - the failure
mode the card that built it explicitly set out to avoid, arrived at from the
other direction.

=head1 THE FIX NEEDS NO NEW FIELD

The start times already identify the process. The board records the moment it
spawned the monitor, and a pid that has been B<reused> belongs to something
that started later. So when both stamps are known the pid and the start time
settle identity between them, and the command comparison is only required where
no start time exists - Windows, where C<tasklist> supplies none.

That is a reordering rather than a loosening: a reused pid is now rejected on a
B<fact> (when it started) instead of on its command text, which can coincide.

=cut
