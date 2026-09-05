#!/usr/bin/env perl
# TKT-944. Michael asked, as a standing instruction: "find out and fix why the
# scheduled repeated jobs why not working." TKT-935 fixed one half - job_is_due
# compared only the current minute, so an irregular caller missed nearly every
# window. This is the other half, and it was never connected at all.
#
# PROVEN IN A CONTAINER BEFORE THIS FILE EXISTED. A command-mode job due every
# minute whose command was `/bin/touch <witness>`, one police pass past the
# window:
#
#   job-due announced: 1
#   announcement text: runs: /bin/touch /tmp/bA32xKfpww/IT-RAN
#   witness file exists (i.e. the command actually ran): NO
#
# The bridge says what is about to happen and nothing makes it happen.
#
# THE MISSING WIRE. Tira::CLI::Police::run_due_job is real, tested by t/512,
# and built by TKT-841 for exactly this. Its only caller anywhere in lib/ or
# cli/ is Tira::CLI::Job::run_now, reached only by `d2 tira.job.run` - the
# manual Run now button. The pass path has no execution step in it.
#
# WHERE THE FIX HAS TO LIVE. Not in the engine: t/489 asserts the job-due rule
# body runs nothing and t/492 asserts the whole engine does, and that is the
# division TKT-841 designed. The engine hands back which jobs came due; the
# CLI layer runs them - the same shape advance_monitor_output already uses for
# a monitor's leavings.
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
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $now  = '2026-09-05T09:00:00Z';
    my $tira = Tira->new( clock => sub {$now} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'Jobs That Run', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'JRS', epic_prefix => 'JRE', ticket_prefix => 'JRT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now, $tmp );
}

sub run_pass {
    my ( $tira, $root, $store ) = @_;
    return $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
}

# --- the pass hands the CLI layer the jobs it must run ---------------------
#
# The engine's half. It names them and runs nothing, which is the division
# t/489 and t/492 hold it to.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/true' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        message => 'a message-mode job, which runs nothing' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    my $due = $result->{due_commands};
    is( ref $due, 'ARRAY', 'the pass hands back the command-mode jobs that came due' );
    is( scalar @{ $due || [] }, 1,
        'exactly one - the message-mode job is not in it, because there is nothing to run' );
    is( $due->[0]{id}, 'JOB-001', 'and it is the command-mode job' );
}

# --- and the CLI layer actually runs them ----------------------------------
#
# The whole card, and the assertion is a file the job's own command creates.
# Reading the code was how this bug survived; a witness is how it is closed.

{
    my ( $tira, $root, $store, $clock, $tmp ) = board();
    my $witness = File::Spec->catfile( $tmp, 'IT-RAN' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => "/bin/touch $witness" );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    ok( !-e $witness, 'the witness does not exist before the CLI layer acts - the engine ran nothing' );

    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    ok( -e $witness,
        "the due command actually ran - the file its own command creates now exists. "
          . 'This is what was false on the real board: JOB-004 announced itself every '
          . 'thirty minutes and never once executed.' );
}

# --- a message-mode job is still only announced ----------------------------

{
    my ( $tira, $root, $store, $clock, $tmp ) = board();
    my $witness = File::Spec->catfile( $tmp, 'MUST-NOT-RUN' );

    # Message-mode carries no command at all, so the only way this file could
    # appear is the executor reaching a job it has no business running.
    $tira->job_add( project => $root, schedule => '* * * * *',
        message => "/bin/touch $witness" );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    ok( !-e $witness,
        'a message-mode job is announced and nothing is executed, exactly as before' );
}

# --- what it printed is kept, so the run is not silent ---------------------

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/echo the-job-said-this' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my ($job) = grep { $_->{id} eq 'JOB-001' } @{ $tira->job_list( project => $root ) };
    my $recent = join "\n", @{ $job->{recent} || [] };
    like( $recent, qr/the-job-said-this/,
        "the command's own output is kept on the job, so a run that happened can be seen "
          . 'rather than merely believed' );
    ok( defined $job->{last_output_at},
        'and the moment it spoke is stamped, the same registration a monitor gets' );
}

# --- a command that FAILS is reported, not swallowed -----------------------
#
# TKT-841's acceptance criterion said "including on failure", and a run that
# fails silently is the same silence this epic exists to end - worse, because
# the card would show a fired job and no sign anything went wrong.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/sh -c "echo it-went-wrong >&2; exit 3"' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    my $ran = Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    is( $ran->[0]{status}, 3, "the command's own exit status is carried back, not flattened to a boolean" );

    my ($job) = grep { $_->{id} eq 'JOB-001' } @{ $tira->job_list( project => $root ) };
    my $recent = join "\n", @{ $job->{recent} || [] };
    like( $recent, qr/exit status 3/,
        'and the failure is written where the card can show it - a job that ran and failed must say so' );
}

# --- an executor that dies does not take the pass down ---------------------
#
# One job's collapse must not stop the others, the stance every other job read
# in this file already takes. Forced by localising the executor, the same way
# t/237 and t/252 prove their own refusals by overriding the thing under them.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', command => '/bin/true' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    my $ran = do {
        no warnings 'redefine';
        local *Tira::CLI::Police::run_due_job = sub { die "the executor fell over\n" };
        Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );
    };

    is( scalar @{$ran}, 1, 'the loop still returns a result for the job it could not run' );
    is( $ran->[0]{ran}, 0, 'and says plainly that it did not run' );
    like( $ran->[0]{output}, qr/the executor fell over/,
        "carrying the executor's own words rather than a generic failure - the reader needs the reason, not the fact" );
}

# --- the engine still runs nothing -----------------------------------------
#
# t/489 and t/492 assert this across the whole engine; asserted here too,
# because this card is the one that would have been tempted to break it.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the denial below needs a real subject.
    like( $engine, qr/\S/, 'the engine source is there to be read' );
    unlike( $engine, qr/run_due_commands\s*\(/,
        'the engine does not call the executor - it names the due jobs and the CLI layer runs them' );
}

done_testing();

__END__

=head1 NAME

564-a-job-announced-and-never-run.t - a due command-mode job is actually executed by a pass

=head1 DESCRIPTION

TKT-944. C<run_due_job> was built by TKT-841 and reachable only from
C<d2 tira.job.run>, so a command-mode job announced as C<runs: ...> on the
bridge was never executed by a police pass - proven with a witness file that
the job's own command creates and that never appeared. The pass now hands back
C<due_commands>, and C<Tira::CLI::Police::run_due_commands> runs them in the
CLI layer, feeding what they printed onto the job the same way a monitor's
leavings are kept. The engine still executes nothing, which C<t/489> and
C<t/492> hold it to and which this file asserts again.

=cut
