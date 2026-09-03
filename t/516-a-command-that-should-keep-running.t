#!/usr/bin/env perl
# Keeping a process alive, as something the board can see rather than shell typed.
#
# TKT-891, ninth and last member of TKT-893, EPC-014. His voice message 6694 on
# 2026-09-03, and it comes from something he actually did: JOB-006 was
# "while ((1)); do d2 tira.police; sleep 5; done" typed into a command field to
# keep police running. It never ran once - created 17:29, no pid, nothing ever
# fed, 22 monitor-dead alarms before he had it deleted.
#
# HIS SPEC: an option called looping, a CHECKBOX not a radio; ticked, the user
# picks the interval, by default about five seconds; when the process ends, wait
# that long and run it again; then the user types only the middle part rather
# than the loop; off by default; and it does not apply in message mode, because
# a loop can only wrap a command.
#
# THE TENSION, AND WHY IT IS SMALLER THAN THE CARD FEARED. A while loop is
# SHELL, and TKT-851 deliberately took shell away from job commands - the words
# travel as positional parameters so a semicolon or a backtick stays an
# argument, proved against six injection attempts. The card warned that
# string-wrapping the user's command in a loop would put all of that back.
#
# It would. But the pipeline ALREADY runs a shell - "the shell is here only to
# own the pipe; the words it runs arrive as positional parameters" - so a loop
# written into that FIXED script wraps "$@", not user text. Nothing of the job's
# becomes shell source. The guarantee is untouched because the shape is
# unchanged: what is looped is the same "$@" that was exec'd before.
#
# AND IT SETTLES THE PID PROBLEM THE CARD RAISED. KD4 worried that restarting a
# command changes its pid, so every restart would read as a dead monitor. With
# the loop inside the supervising shell, the SHELL is what the board recorded
# and it never exits - so the pid is stable across every restart, and
# monitor-dead needs no special case at all.
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
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Looping', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'LPS', epic_prefix => 'LPE', ticket_prefix => 'LPT',
    );
    return ( $tira, $root );
}

# --- the interval is a field on the job --------------------------------------

{
    my ( $tira, $root ) = board();

    my $job = eval {
        $tira->job_add(
            project => $root, schedule => 'monitor',
            command => 'd2 tira.police', restart_every => 5 );
    };
    my $why = $@;

    ok( $job && ref $job eq 'HASH',
        'a monitor can say it should be restarted when its command ends - the '
          . 'thing he was typing a while loop to get' )
      or diag("job_add refused it: $why");

    is( ( $job || {} )->{restart_every}, 5,
        'and the interval is stored, so the board can SEE that this job is '
          . 'supervised rather than it being invisible inside a command string' );
}

# --- off by default, which is his words --------------------------------------

{
    my ( $tira, $root ) = board();
    my $plain = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'd2 tira.policy.bridge' );

    ok( !defined $plain->{restart_every},
        'a monitor that did not ask for it is not supervised - "by default the '
          . 'loop is off", and a default here would restart things nobody asked '
          . 'to have restarted' );
}

# --- and it is refused where it cannot mean anything -------------------------
#
# His words: it does not apply when message mode is chosen, because a loop can
# only wrap a command. A cron job is the same case from the other side - it
# fires on a tick and is not supposed to be up between runs.

{
    my ( $tira, $root ) = board();

    # any failure is what this means. One call, and the only intended way for it
    # to fail is the refusal being asserted.
    my $ok = eval {
        $tira->job_add(
            project => $root, schedule => '0 * * * *',
            command => 'd2 tira.stale', restart_every => 5 );
        1;
    };
    my $why = $@;
    ok( !$ok, 'a cron job is refused an interval - it is not supposed to be up '
          . 'between runs, so there is nothing to restart' );
    like( $why, qr/monitor/i, 'and the refusal says which kind it belongs to' );
}

{
    my ( $tira, $root ) = board();

    # any failure is what this means. As above.
    my $ok = eval {
        $tira->job_add(
            project => $root, schedule => '0 * * * *',
            message => 'a message job', restart_every => 5 );
        1;
    };
    ok( !$ok, 'and so is a message job, because a loop can only wrap a command '
          . '- which is his own reason, not an inferred one' );
}

# --- it survives an update that names something else -------------------------

{
    my ( $tira, $root ) = board();
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor',
        command => 'd2 tira.police', restart_every => 5 );

    my $touched = $tira->job_update(
        project => $root, id => $job->{id}, schedule => 'monitor' );
    is( $touched->{restart_every}, 5,
        'an update naming something else does not quietly drop it, the way '
          . 'expect_every and the command already do not' );

    my $changed = $tira->job_update(
        project => $root, id => $job->{id}, restart_every => 30 );
    is( $changed->{restart_every}, 30, 'and it can be corrected' );
}

# --- THE LOOP IS IN THE FIXED SCRIPT, AND THE JOB'S WORDS ARE STILL ARGUMENTS -
#
# The whole safety question, asserted against the source rather than described.
# TKT-851's guarantee is that nothing of the job's is shell TEXT: the words
# arrive as positional parameters and the only thing sh parses is a fixed
# script. A loop that interpolated the command would end that.

my $starter = do {
    open my $fh, '<:raw', 'lib/Tira/CLI/Job.pm' or die "Job.pm: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: the assertions below read this source, and an
# unreadable file would fail them for the wrong reason.
like( $starter, qr/\S/, 'the starter is there to be read' );

# THE SCRIPT ITSELF, not the file. A bare /while/ over Job.pm matched ordinary
# Perl loops elsewhere in the module and passed before anything was built - an
# assertion that cannot fail is worth less than none, because it reports success.
my ($script) = $starter =~ /my \$script\s*=\s*(.*?);\n/s;

# non-empty is the whole claim: the three assertions below read this text, and
# an extraction that found nothing would pass the unlike and fail the likes for
# reasons that have nothing to do with the code.
like( $script // '', qr/\S/, 'the pipeline script was found to read' );

like(
    $script // '',
    qr/while/,
    'the loop is IN THE SHELL SCRIPT, so the board restarts the command rather '
      . 'than a person typing a while loop into a command field'
);

unlike(
    $script // '',
    qr/\$job->\{command\}|\@command/,
    'AND THE COMMAND IS NOT IN IT. A loop built by interpolating the job command '
      . 'into shell source would undo TKT-851 exactly - user text inside a loop '
      . 'body is the worst place to put back what that card removed'
);

like(
    $script // '',
    qr/"\$\@"/,
    'the words are still the quoted positional parameters, which is what keeps '
      . 'a semicolon or a backtick an argument rather than syntax'
);

done_testing();

__END__

=head1 NAME

516-a-command-that-should-keep-running.t - supervision the board can see

=head1 WHY

TKT-891, inside TKT-893. Keeping a process alive was something a person typed
into a command field as a C<while> loop - which JOB-006 proves can be typed and
never work, and which the board cannot see: a command containing a loop is one
opaque string, so nothing can report the interval or tell a supervised job from
a plain one.

=head1 WHAT IS ASSERTED

That the interval is a field; that it is off unless asked for; that it is
refused on a cron job and on a message job, which are his own reasons; that it
survives an unrelated update; and that the loop lives in the fixed pipeline
script with the job's words still arriving as positional parameters.

That last one is the safety question. TKT-851 proved the job's words never
become shell source against six injection attempts, and a loop built by
interpolating the command would end that - user text inside a loop body being
the worst possible place to put it back.

=cut
