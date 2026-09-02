#!/usr/bin/env perl
# A command-mode job that runs, and says so when it fails.
#
# His msg 6487: "For the repeated job, either set to run a command and output
# to the police bridge or direct message to the bridge." TKT-836 stored the
# two modes, TKT-837 gave the CLI verbs, TKT-838 made a due MESSAGE job reach
# the bridge - and skipped command-mode jobs entirely, with `next if mode ne
# 'message'`. This is the card where they run. TKT-841.
#
# WRITTEN RED, before the executor exists.
#
# THE FAILURE CASE IS THE POINT. A command that exits non-zero must reach the
# bridge saying so. Silence from a job that ran and failed is indistinguishable
# from a job that never ran, which is the exact ambiguity EPC-014 was filed to
# remove - so a failing command reporting nothing would rebuild the original
# problem inside the fix for it.
#
# WHERE EXECUTION LIVES, and why this file tests two layers. t/106 forbids qx,
# system(, exec( and piped open anywhere in the engine, and its pattern catches
# list-form system( too, so "no shell" buys no exception: the engine cannot
# execute. t/lib/Suite.pm already excludes lib/Tira/CLI from that guard because
# Serve.pm legitimately shells out. So the engine ANNOUNCES a due command-mode
# job and the CLI layer RUNS it. t/489's assertion that the rule body executes
# nothing therefore stays true and stays meaningful; it is not deleted to make
# room for this.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $tmp   = File::Temp::tempdir( CLEANUP => 1 );
my $root  = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catdir( $tmp, 'store' );

my $tira = Tira->new( clock => sub {'2026-09-02T11:00:00Z'} );
$tira->project_new(
    name => 'Runnable', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'RNS', epic_prefix => 'RNE', ticket_prefix => 'RNT',
);
$tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );

# --- the engine announces a due command-mode job ----------------------------
#
# Today job-due does `next if ( $job->{mode} // '' ) ne 'message'`, so a
# command-mode job is skipped and nothing downstream ever hears about it. It
# has to be announced before anything can run it.

sub announced {
    my ($on) = @_;
    my $pass = ( $on // $tira )->police_pass( project => $root, store => $store );
    return [ grep { ( $_->{rule} // '' ) eq 'job-due' && !$_->{quiet} }
          @{ $pass->{violations} // $pass->{findings} // [] } ];
}

{
    $tira->job_add( project => $root, schedule => '0 * * * *',
        command => 'echo hunted' );

    my $found = announced();
    is( scalar @{$found}, 1,
        'a due COMMAND-mode job is announced - today job-due skips it entirely' );
}

# --- and the CLI layer runs it, sending the output to the bridge ------------

{
    my $job = $tira->job_list( project => $root )->[0];

    require Tira::CLI::Police;
    my $ran = eval {
        Tira::CLI::Police::run_due_job( tira => $tira, project => $root, job => $job );
    };
    ok( $ran, 'the police layer has something that runs a due job' ) or diag($@);

    like( $ran->{output} // '', qr/hunted/,
        'and the command actually ran - its output is what came back' );
    is( $ran->{status}, 0, 'with the exit status recorded, not discarded' );
}

# --- a command that fails says so -------------------------------------------
#
# The assertion this file exists for.

{
    my $bad = $tira->job_add( project => $root, schedule => '0 * * * *',
        command => 'false' );

    require Tira::CLI::Police;
    my $ran = eval {
        Tira::CLI::Police::run_due_job( tira => $tira, project => $root, job => $bad );
    };
    ok( $ran, 'a failing job still returns a result rather than dying' ) or diag($@);

    # ESTABLISH THE RESULT BEFORE READING IT. isnt( $ran->{status}, 0 ) passed
    # against the pre-fix code for the worst possible reason: $ran was undef,
    # so $ran->{status} was undef, so "not zero" was true and a missing
    # executor looked like a reported failure. The denial is only meaningful
    # once there is a result to deny something about.
    ok( ref $ran eq 'HASH', 'the failing run returned a result to inspect' );
    isnt( $ran->{status}, 0, 'its non-zero exit is reported' ) if ref $ran eq 'HASH';
    ok( defined $ran->{output},
        'and output is present even on failure - an empty string is a result, undef is silence' )
      if ref $ran eq 'HASH';
}

# --- a program that is not installed is a result, not a crash ---------------
#
# The branch that says so was written and then not exercised: the coverage run
# named lib/Tira/CLI/Police.pm as the only module under 100% and pointed at
# exactly these three lines. Arguing in a commit message that a missing program
# should report rather than die, and then never running that path, is how a
# considered decision becomes an untested one.

{
    my $absent = $tira->job_add( project => $root, schedule => '0 * * * *',
        command => 'tira-no-such-program-exists-here --please' );

    require Tira::CLI::Police;
    my $ran = Tira::CLI::Police::run_due_job(
        tira => $tira, project => $root, job => $absent );

    ok( ref $ran eq 'HASH', 'a missing program returns a result rather than dying' );
    is( $ran->{ran}, 1, 'and the attempt is recorded as having been made' );
    isnt( $ran->{status}, 0, 'with a non-zero status, because nothing ran successfully' );
    like( $ran->{output} // '', qr/tira-no-such-program-exists-here/,
        'and the output NAMES what could not be run - "it failed" without saying what '
          . 'is the same silence this card exists to remove, one level down' );
}

# --- a message-mode job runs nothing ----------------------------------------
#
# The other half of the boundary. Establishing the subject first: this pass
# must announce SOMETHING, or the denial below passes against an empty result.

{
    my $later = Tira->new( clock => sub {'2026-09-02T12:00:00Z'} );
    $later->job_add( project => $root, schedule => '0 * * * *',
        message => 'just say this' );

    my $rows = announced($later);
    cmp_ok( scalar @{$rows}, '>=', 1,
        'the pass announced something, so the denial below has a subject' );

    my $message_job = ( grep { ( $_->{mode} // '' ) eq 'message' }
          @{ $later->job_list( project => $root ) } )[0];
    ok( $message_job, 'and there is a message-mode job to check' );

    # eval, so a missing executor fails THIS assertion rather than killing the
    # file and hiding the two below it. A red test that dies half way reports
    # less than it knows.
    require Tira::CLI::Police;
    my $ran = eval {
        Tira::CLI::Police::run_due_job(
            tira => $later, project => $root, job => $message_job );
    };
    ok( $ran && !$ran->{ran},
        'a message-mode job is not executed - it is announced and nothing more' ) or diag($@);
}

# --- and the engine still executes nothing ----------------------------------
#
# t/489 asserts this of the job-due rule body. Asserted here of the WHOLE
# engine, because this card is the one that introduces execution and the
# temptation is to put it where the schedule is already in hand.

{
    require Suite;
    my $engine = Suite::engine_source();
    like( $engine, qr/package Tira/, 'the engine source was read - precondition for the denial below' );
    unlike( $engine,
        qr/(?: qx[\{\(\/] | (?<![.\w]) system \s* \( | (?<![.\w]) exec \s* \( | open \s* \( [^)]* \| )/x,
        'the engine still invokes nothing - execution lives in the CLI layer, where Serve.pm already does' );
}

done_testing();

__END__

=head1 NAME

t/492-a-job-that-actually-runs.t - command-mode repeated jobs execute and report

=head1 DESCRIPTION

TKT-841. A due command-mode job runs and its output reaches the police bridge,
including when the command fails.

=head1 THE FAILURE CASE IS THE POINT

A command that exits non-zero must say so. Silence from a job that ran and
failed cannot be told apart from a job that never ran, and that ambiguity is
what EPC-014 exists to remove - so a failing command reporting nothing would
rebuild the original problem inside the fix for it.

=head1 TWO LAYERS, ON PURPOSE

F<t/106> forbids C<qx>, C<system(>, C<exec(> and piped C<open> anywhere in the
engine, and its pattern catches list-form C<system(> as well, so "without a
shell" buys no exception. C<Suite::engine_source()> already excludes
F<lib/Tira/CLI> because F<Serve.pm> legitimately shells out. So the engine
announces a due command-mode job and the CLI layer runs it, which keeps
F<t/489>'s no-execution assertion about the rule body both true and meaningful
rather than deleted to make room.

=cut
