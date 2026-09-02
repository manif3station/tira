#!/usr/bin/env perl
# The CLI half of repeated jobs: tira.job.add / list / update / delete.
#
# TKT-836 shipped the record and the validator. Nothing can reach them from a
# command line yet, which means an agent wanting a schedule would have to
# write .tira/jobs.json by hand - the exact thing every other Tira record has
# a verb for. TKT-837, EPC-014.
#
# WRITTEN RED, before the verbs exist.
#
# THE REFUSAL COMES FROM THE ENGINE, NOT FROM A SECOND COPY OF THE RULE.
# What makes a schedule valid is Tira::Job::_cron_parse, and the CLI's job is
# to surface its message, not to re-decide it. Two validators for one format
# is how the browser and the engine ended up disagreeing about attachment
# content types (TKT-713), which cost a whole card to unpick - and TKT-843
# will face the same temptation in JavaScript. So this file asserts that the
# CLI refusal carries the ENGINE's words.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;
use Tira::CLI;

# Tira::CLI->run takes a hash - command => 'job.add', argv => [...] - and the
# command name carries no 'tira.' prefix. The first draft of this helper
# passed a flat @argv the way a shell would, and every assertion failed with
# "Unsupported Tira command ''" rather than with anything about jobs: the
# harness was wrong, not the code under test. Worth the comment, because a
# red test that fails for the wrong reason is indistinguishable from one that
# fails for the right one until somebody reads the error.
my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );
Tira->new->project_new(
    name => 'Scheduled', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

# Two things the first draft got wrong, both in the harness rather than in
# the code under test - which is worth the comment, because a red test that
# fails for the wrong reason looks exactly like one that fails for the right
# one until somebody reads the error.
#
#   1. Tira::CLI->run takes a hash - command => 'job.add', argv => [...] -
#      and the command name carries no 'tira.' prefix. A flat @argv gave
#      "Unsupported Tira command ''".
#   2. There is no --project option. The board is found from TIRA_HOME, the
#      way t/08 and every other CLI test does it. Passing --project gave
#      "Unknown option: project" on every call.
sub run_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    my $status = do {
        local $ENV{TIRA_HOME} = $root;
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$out or die $!;
        open STDERR, '>', \$err or die $!;
        Tira::CLI->run( command => $command, argv => \@argv );
    };
    return { status => $status, out => $out, err => $err };
}


# --- add, in both modes -----------------------------------------------------

{
    my $r = run_cli( 'job.add',
        '--schedule', '0 * * * *', '--message', 'go hunt some bugs', '-o', 'json' );
    is( $r->{status}, 0, 'tira.job.add exits zero for a message-mode job' )
      or diag( $r->{err} );
    like( $r->{out}, qr/"mode"\s*:\s*"message"/, 'and -o json emits the record, mode included' );
    like( $r->{out}, qr/go hunt some bugs/, 'carrying the message it was given' );

    my $c = run_cli( 'job.add',
        '--schedule', 'monitor', '--command', 'd2 tira.policy.bridge', '-o', 'json' );
    is( $c->{status}, 0, 'and zero for a command-mode monitor job' ) or diag( $c->{err} );
    like( $c->{out}, qr/"mode"\s*:\s*"command"/, 'whose mode is command' );
    like( $c->{out}, qr/"schedule_kind"\s*:\s*"monitor"/, 'and whose schedule kind is monitor' );
}

# --- the refusal is the engine's, word for word -----------------------------

{
    my $engine_said = '';
    eval {
        Tira->new->job_add( project => $root, schedule => '99 * * * *', message => 'x' );
        1;
    } or $engine_said = $@;
    like( $engine_said, qr/minute/, 'the engine refuses a bad minute field, naming it' );

    my $r = run_cli( 'job.add',
        '--schedule', '99 * * * *', '--message', 'x' );
    isnt( $r->{status}, 0, 'and the CLI refuses it too' );
    unlike( $r->{err} . $r->{out}, qr/Unsupported Tira command/,
        'refused because the SCHEDULE is bad, not because job.add does not exist - '
          . 'this assertion passed against the pre-fix code for exactly that wrong reason' );

    # The whole point: the same words, not a second opinion.
    my ($core) = $engine_said =~ /(The minute field[^\n]*)/;
    ok( $core, 'the engine refusal has a quotable core' );
    like( $r->{err} . $r->{out}, qr/\Q$core\E/,
        'and the CLI surfaces the ENGINE\'s message rather than re-deciding validity' );
}

# --- list, update, delete ---------------------------------------------------

{
    my $l = run_cli( 'job.list', '-o', 'json' );
    is( $l->{status}, 0, 'tira.job.list exits zero' ) or diag( $l->{err} );
    like( $l->{out}, qr/JOB-\d+/, 'and names the jobs by id' );

    my $human = run_cli( 'job.list' );
    is( $human->{status}, 0, 'and the default output works without -o' );
    like( $human->{out}, qr/JOB-\d+/,
        'whose human output names a job - established first, because the unlike below '
          . 'is satisfied by empty output and passed that way against the pre-fix code' );
    unlike( $human->{out}, qr/^\s*\{/, 'which is a human summary rather than raw JSON' );

    my $u = run_cli( 'job.update',
        '--id', 'JOB-001', '--message', 'changed', '-o', 'json' );
    is( $u->{status}, 0, 'tira.job.update exits zero' ) or diag( $u->{err} );
    like( $u->{out}, qr/changed/, 'and the new message is in the record it returns' );

    my $bad = run_cli( 'job.update',
        '--id', 'JOB-001', '--schedule', 'nonsense' );
    isnt( $bad->{status}, 0, 'an update to a malformed schedule is refused through the CLI too' );
    unlike( $bad->{err} . $bad->{out}, qr/Unsupported Tira command/,
        'and refused for the schedule rather than for the verb being absent' );

    my $d = run_cli( 'job.delete', '--id', 'JOB-001' );
    is( $d->{status}, 0, 'tira.job.delete exits zero' ) or diag( $d->{err} );

    my $after = run_cli( 'job.list', '-o', 'json' );
    is( $after->{status}, 0, 'the list still answers after the delete' );
    like( $after->{out}, qr/JOB-\d+/,
        'and still names the OTHER job - the subject the denial below needs, without '
          . 'which an empty list would satisfy it for the wrong reason' );
    unlike( $after->{out}, qr/JOB-001"/, 'and the job is gone from the list' );
}

# --- the unknown verb refuses rather than deleting ---------------------------
#
# dispatch() used to end in a bare `return $tira->job_delete(...)`, safe only
# because Tira::CLI admits exactly four verbs and the other three return above
# it - the safety lived in a regex in another file. TKT-841 and TKT-842 are
# both queued to add behaviour here, and adding a verb to that regex without
# adding a branch would have DELETED the job instead of running it.
#
# Called directly rather than through the CLI, because the CLI is exactly what
# makes this unreachable today. The point is that it stops being unreachable
# the moment somebody widens that regex, and the refusal is what makes that
# safe rather than silent.

{
    require Tira::CLI::Job;
    my $tira = Tira->new;
    my $died = '';
    eval { Tira::CLI::Job::dispatch( $tira, { project => $root }, {}, 'job.invented' ); 1 }
      or $died = $@;
    like( $died, qr/cannot dispatch/,
        'a verb dispatch does not know is refused, not silently treated as delete' );
    like( $died, qr/job\.invented/, 'and the refusal names the verb it was given' );
}

# --- one command, given once ------------------------------------------------
#
# --command is shared with required-action proofs, which take it repeatably, so
# the job verbs read an array. Two of them is refused rather than quietly
# resolved to one: a job runs a single command, and silently dropping the other
# is the fault the option guard exists to prevent. Covered here because the
# refusal was written and then left untested - the coverage run named
# lib/Tira/CLI/Job.pm as the only module under 100%, and this line was the hole.

{
    my $two = run_cli( 'job.add', '--schedule', '0 * * * *',
        '--command', 'first', '--command', 'second' );
    isnt( $two->{status}, 0, 'two --command flags on one job are refused' );
    like( $two->{err} . $two->{out}, qr/one command/,
        'and the refusal says why rather than printing a usage dump' );
    unlike( $two->{err} . $two->{out}, qr/Unsupported Tira command/,
        'refused by the verb, not by the verb being absent' );
}

# --- a flag that parses is not a flag that was understood -------------------
#
# --enabled took anything recognisably true as true and EVERYTHING ELSE as
# false, so "--enabled banana" disabled a job and said nothing. Found by a
# documentation review rather than by a test, which is why one exists now: the
# docs said yes|no, the code took 1/yes/true/on, and neither said what happened
# to a fifth word. This board refuses that shape everywhere else - a checklist
# status of 'todo' is refused rather than guessed at, and a malformed cron is
# refused rather than stored as never-due.

{
    my $job = Tira->new->job_add( project => $root, schedule => '0 * * * *',
        message => 'enabled round trip' );

    my $off = run_cli( 'job.update', '--id', $job->{id}, '--enabled', 'no', '-o', 'json' );
    is( $off->{status}, 0, 'a job can be disabled' ) or diag( $off->{err} );
    like( $off->{out}, qr/"enabled"\s*:\s*(?:0|false)/, 'and the record says so' );

    my $on = run_cli( 'job.update', '--id', $job->{id}, '--enabled', 'TRUE', '-o', 'json' );
    is( $on->{status}, 0, 'and enabled again, in any casing' ) or diag( $on->{err} );

    my $nonsense = run_cli( 'job.update', '--id', $job->{id}, '--enabled', 'banana' );
    isnt( $nonsense->{status}, 0, 'a word that is neither true nor false is refused' );
    like( $nonsense->{err} . $nonsense->{out}, qr/banana/,
        'and the refusal quotes what was actually given, rather than a bare usage dump' );
    unlike( $nonsense->{err} . $nonsense->{out}, qr/Unsupported Tira command/,
        'refused by the verb, not by the verb being absent' );
}

# --- the usage line names what it refuses without ---------------------------

{
    my $r = run_cli( 'job.add' );
    isnt( $r->{status}, 0, 'add with no schedule is refused' );
    unlike( $r->{err} . $r->{out}, qr/Unsupported Tira command/,
        'by the verb itself, not by the verb being missing' );
    like( $r->{err} . $r->{out}, qr/schedule/i,
        'and says schedule is what is missing, rather than a bare usage dump' );
}

done_testing();

__END__

=head1 NAME

t/488-a-schedule-an-agent-can-type.t - the CLI verbs over repeated jobs

=head1 DESCRIPTION

TKT-837. C<tira.job.add>, C<list>, C<update> and C<delete>, following the
grammar and output contract every other Tira verb has: a human summary by
default, the full record under C<-o json>, and a usage line that names what
it refuses without.

The assertion worth keeping is that the CLI's refusal carries the B<engine's>
words. What makes a schedule valid is C<Tira::Job::_cron_parse>, and a second
copy of that rule in the CLI would eventually disagree with it - which is
what happened between the browser and the engine over attachment content
types in TKT-713. The same temptation returns in JavaScript on TKT-843.

=cut
