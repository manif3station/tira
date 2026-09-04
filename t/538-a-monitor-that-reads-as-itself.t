#!/usr/bin/env perl
# A monitor's line in ps is the script that runs it, and never says whose it is.
#
# TKT-927, EPC-014. His message, 2026-09-04 16:05, pasting his own JOB-006:
#
#   sh -c PERL="$1"; FEEDER="$2"; ID="$3"; EVERY="$4"; shift 4; if [ "$EVERY"
#   -gt 0 ]; then while :; do "$@"; sleep "$EVERY"; done 2>&1 | exec "$PERL"
#   "$FEEDER" --id "$ID"; else exec "$@" 2>&1 | exec "$PERL" "$FEEDER" --id
#   "$ID"; fi tira-monitor /usr/bin/perl /home/mv/.developer-dashboard/skills/
#   tira/lib/Tira/CLI/../../../skills/job/cli/feed JOB-006 5 tail -F -n0
#   /home/mv/dd-tg/bot.log
#
# and asking for "a helper like tira.job.feeder --command ... --loop --interval
# N --ref <which project>-JOB-NNN / on the ps -ef table show much more tidy
# process list".
#
# THE MISSING WORD IS THE BOARD, and it is not cosmetic. Job ids are per-board
# and this machine runs the skill for several projects, so JOB-006 exists on
# four of them: a monitor cannot be identified from ps at all. That is not a
# hypothetical - on 2026-09-04 I matched processes by `--id JOB-006` across the
# machine, reported another project's monitors as duplicates of his, and
# offered to kill four of them.
#
# WHAT MUST NOT BE UNDONE, which is why this file asserts as much about what
# stays as about what changes:
#
#   TKT-851 - the job's words are positional parameters, never shell text, so a
#             semicolon or a backtick in a command stays an argument.
#   TKT-842 - a pipe with no reader fills at 64KB and blocks the child; the
#             feeder is the reader, so it cannot be forgotten.
#   TKT-920 - the monitor runs in a process group of its own, so the recorded
#             pid stops all of it.
#
# The card's own test of correctness: the helper is a SIMPLIFICATION of those
# three rather than a fourth mechanism beside them, so the sh script and the
# perl -e shim are gone when it lands.
#
# AND THE BOARD'S PATH STILL DOES NOT APPEAR. It travels in TIRA_HOME because a
# --project argument would put it in the process table for anyone running ps -
# so what the line names is the board's NAME.
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
use Tira::CLI::Job;
use Tira::CLI::Job::Feeder;
use Tira::CLI::Job::Monitor;

my $BOARD = 'Feeder Board';

my ( $tira, $root );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => $BOARD, dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'FDS', epic_prefix => 'FDE', ticket_prefix => 'FDT',
    );
}

# --- the line a person reads ---------------------------------------------------
#
# Built by a named sub rather than inline, so this file can assert its shape
# without starting anything - and so the shape has one implementation. The two
# facts his ps line is missing are the verb and the board.

# IN THE FEEDER RATHER THAN THE SPAWN, which is where this file first looked.
# The title is set by the process it describes, as its own first act, so a
# monitor started by hand from a terminal reads the same in ps as one the board
# started - and a sub living in the spawner would have described a process it
# does not run in.
can_ok( 'Tira::CLI::Job::Feeder', 'monitor_process_title' );

SKIP: {
    skip 'no monitor_process_title yet', 5
      if !Tira::CLI::Job::Feeder->can('monitor_process_title');

    my $title = Tira::CLI::Job::Feeder::monitor_process_title(
        'JOB-006', $BOARD, [ 'tail', '-F', '-n0', '/home/mv/dd-tg/bot.log' ] );

    like( $title, qr/\bjob\.feeder\b/,
        'THE LINE NAMES THE VERB, so somebody reading ps knows what they are '
          . 'looking at rather than reading a shell script that happens to '
          . 'mention tira' );

    like( $title, qr/\bJOB-006\b/, 'and which job it is' );

    like( $title, qr/\Q$BOARD\E/,
        'AND WHICH BOARD, which is the fact his line is missing and the one '
          . 'that made me report another project\'s monitors as his. Job ids '
          . 'are per-board and four boards on this machine have a JOB-006' );

    like( $title, qr/tail -F -n0/,
        'and the command it is running, which is what he is usually looking '
          . 'for when he runs ps at all' );

    unlike( $title, qr/\Q$root\E/,
        'AND NOT THE BOARD\'S PATH. It travels in TIRA_HOME precisely so that '
          . 'it is not in the process table, which is the rule the --project '
          . 'argument was kept out of the spawn for' );
}

# --- what the spawn no longer is ----------------------------------------------
#
# Source-read, and scoped to the command surface through Suite rather than by
# naming the file - t/486's rule, widened this evening on TKT-921.

my $cli = Suite::cli_source();

ok( length $cli, 'the command surface was read' );

unlike( $cli, qr/PERL="\$1";\s*FEEDER="\$2"/,
    'THE sh SCRIPT IS GONE. It is what he pasted, and every part of it is now '
      . 'the helper\'s job: the loop, the redirect, the pipe and the exec. A '
      . 'helper added BESIDE it would leave his ps line exactly as it is' );

unlike( $cli, qr/eval \{ setpgrp 0, 0 \}; exec \@ARGV/,
    'and so is the perl -e shim. TKT-920 put it there to make the pipeline a '
      . 'process group; a single helper that owns its child sets its own group '
      . 'from inside, which is the same guarantee with one less process' );

like( $cli, qr/setpgrp/,
    'THE GROUP ITSELF STAYS, though - this is the assertion that stops the '
      . 'line above being satisfied by deleting the guarantee rather than by '
      . 'moving it. TKT-920: the recorded pid must stop all of the monitor' );

like( $cli, qr/job_command_words/,
    'and the command is still split by the engine\'s own splitter rather than '
      . 'by a shell - TKT-851, and the reason a semicolon in a command stays an '
      . 'argument' );

# --- and what it still does ----------------------------------------------------
#
# The controls, and they pass BEFORE the change as well as after. Each is a
# guarantee this card is at risk of undoing rather than a claim it makes.

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => '/bin/echo a;b', author => 'claude' );

    # A LIST, not a reference - it returns one, and reading it in scalar
    # context gets the count. That is how the first version of this assertion
    # failed against correct code, which is worth leaving in the file: a
    # control that fails is checked before the product is blamed.
    my @words = Tira::Job::job_command_words( $job->{command} );

    is_deeply( \@words, [ '/bin/echo', 'a;b' ],
        'A SEMICOLON IN A COMMAND IS ONE ARGUMENT, not two commands. The '
          . 'splitter is the engine\'s, so nothing about the helper changes '
          . 'it - and if the helper ever passed --command to a shell instead, '
          . 'this is the assertion that would still pass while the behaviour '
          . 'changed underneath it, which is why the ps assertions above are '
          . 'about the LIST that gets exec\'d' );
}

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'echo `whoami`', author => 'claude' );

    my @words = Tira::Job::job_command_words( $job->{command} );

    is( scalar @words, 2, 'a backtick makes no extra words either' );
    like( $words[1], qr/\A`whoami`\z/,
        'and arrives with its backticks intact, as text - TKT-851 removed the '
          . 'shell that would have run it' );
}

done_testing();

__END__

=head1 NAME

538-a-monitor-that-reads-as-itself.t - what a monitor looks like in ps

=head1 WHY

TKT-927, from his own message. A monitor's line in C<ps> is the entire wrapper
script plus a resolved absolute path into the install, and it does not say which
board the job belongs to. Job ids are per-board and this machine runs the skill
for several projects, so C<JOB-006> exists four times over and a monitor cannot
be identified from C<ps> at all - which is how another project's monitors came
to be reported as his.

=head1 WHAT IS ASSERTED

That a named sub builds the process title, and that the title carries the verb,
the job, B<the board> and the command - and B<not> the board's path, which
travels in C<TIRA_HOME> for exactly that reason.

Then that the C<sh> script and the C<perl -e> shim are gone from the command
surface, with two assertions beside them that stop those being satisfied by
deletion: C<setpgrp> still appears, because TKT-920's guarantee is that the
recorded pid stops all of the monitor, and the command is still split by
C<job_command_words>.

The last two blocks are controls that pass before the change as well as after:
a semicolon and a backtick in a command stay single arguments, which is
TKT-851's guarantee and the thing a C<--command> string is most likely to undo.

=head1 WHAT IS NOT ASSERTED HERE

The ps line of a running monitor. That belongs to the card's own checklist item
- read C<ps> in a container and record the line - because a test that starts a
monitor to read the process table is asserting on its neighbours' processes as
much as its own, which F<t/529> learned the hard way.

=cut
