#!/usr/bin/env perl
# TKT-950. His report: "A job command using bare 'd2' cannot exec -
# tira.job.help's own documented example fails." He answered Q-130 naming the
# executor: a job falling due, which is the police daemon's path.
#
# WHAT IS ACTUALLY WRONG, found by reading run_due_commands rather than by
# reproducing his instance. There are two ways a command job can fail, and the
# board treats them completely differently:
#
#   RAN AND FAILED    - a non-zero exit. The output and "exit status N" are
#                       fed onto the job, and the card shows them. t/564
#                       asserts this, and the code carries a comment saying
#                       dropping it "would rebuild the silence this whole epic
#                       exists to end".
#
#   NEVER STARTED     - run_due_job dies, which is what a command that cannot
#                       be execed does. The reason is pushed into the function's
#                       RETURN VALUE and the loop calls next, skipping job_feed
#                       entirely (lib/Tira/CLI/Police.pm, the `if ( !$outcome )`
#                       branch). Nothing reaches the job. The card shows a job
#                       that fired and no sign anything went wrong.
#
# So the branch immediately above the comment about not rebuilding silence does
# exactly that, for the one case where the reader has least to go on: a command
# that exits 3 at least ran, and one that never started leaves no trace at all.
#
# WHY THIS IS THE RIGHT TEST FOR HIS CARD even though his own instance may
# already be fixed. Until 5.81 no due command was executed at all (TKT-944), so
# what he watched all evening could have been that. This assertion is true
# regardless: whichever executor failed and whenever, a command that could not
# start must say so where he reads it. t/564 covers this branch already - but
# only its return value, which nothing displays.
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
        name => 'A Command That Could Not Start', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'CCS', epic_prefix => 'CCE', ticket_prefix => 'CCT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub run_pass {
    my ( $tira, $root, $store ) = @_;
    return $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
}

sub recent_of {
    my ( $tira, $root ) = @_;
    my ($job) = grep { $_->{id} eq 'JOB-001' } @{ $tira->job_list( project => $root ) };
    return join "\n", @{ $job->{recent} || [] };
}

# --- a command that never started says so on the job -----------------------
#
# The whole card. Forced by localising the executor to die, the same way t/564
# proves the loop survives one - except that test stops at the return value,
# which is exactly the gap.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', command => 'd2 tira.police.outstanding' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    my $ran = do {
        no warnings 'redefine';
        local *Tira::CLI::Police::run_due_job =
          sub { die "No such file or directory: d2\n" };
        Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );
    };

    is( $ran->[0]{ran}, 0, 'the loop reports that the job did not run' );

    my $recent = recent_of( $tira, $root );
    like( $recent, qr/No such file or directory/,
        'and the reason it could not start is on the JOB, where the card shows it - '
          . 'not only in a return value nothing displays' );
    like( $recent, qr/\Qd2\E/,
        'naming the command that could not be started, which is what tells him it was a PATH problem' );
}

# --- a command that ran and failed is unchanged ----------------------------
#
# The regression that would matter most. This half already works and t/564
# holds it; asserted here too because the fix touches the branch beside it.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/sh -c "echo it-went-wrong >&2; exit 3"' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $recent = recent_of( $tira, $root );
    like( $recent, qr/exit status 3/,
        'a command that ran and failed still carries its exit status, as it did before' );
}

# --- a command that ran cleanly says nothing new ---------------------------
#
# The other direction, and the one a careless fix breaks: a job that worked
# must not acquire a failure line because the failure path was widened.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/sh -c "echo all-was-well"' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );
    Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );

    my $recent = recent_of( $tira, $root );
    # non-empty is the whole claim: the denial below would pass on an empty
    # output for the wrong reason.
    like( $recent, qr/all-was-well/, "a clean run's own output is still kept" );
    unlike( $recent, qr/could not start|No such file/i,
        'and a job that started perfectly well is not told that it could not' );
}

# --- one job that cannot start does not silence the others -----------------

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *', command => 'd2 tira.police.outstanding' );
    $tira->job_add( project => $root, schedule => '* * * * *',
        command => '/bin/sh -c "echo the-second-job-spoke"' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $result = run_pass( $tira, $root, $store );

    my $first = 1;
    {
        no warnings 'redefine';
        local *Tira::CLI::Police::run_due_job = sub {
            my (%args) = @_;
            die "No such file or directory: d2\n" if $args{job}{id} eq 'JOB-001';
            return { ran => 1, status => 0, output => "the-second-job-spoke\n" };
        };
        Tira::CLI::Police::run_due_commands( $tira, { project => $root }, $result );
    }

    my ($second) = grep { $_->{id} eq 'JOB-002' } @{ $tira->job_list( project => $root ) };
    my $recent = join "\n", @{ $second->{recent} || [] };
    like( $recent, qr/the-second-job-spoke/,
        'the job after the one that could not start still had its output recorded' );
}

done_testing();

__END__

=head1 NAME

570-a-command-that-could-not-start.t - a job command that never started says so on the job

=head1 DESCRIPTION

TKT-950, from his report that a bare C<d2> job command cannot exec. A command
job can fail two ways and the board treated them very differently: one that
B<ran and failed> has its output and C<exit status N> fed onto the job, while
one that B<never started> had its reason pushed into C<run_due_commands>'
return value and the loop then called C<next>, skipping C<job_feed> entirely -
so the card showed a job that fired with no sign anything had gone wrong.

That is the silence the code's own comment, one branch below, says must not be
rebuilt. C<t/564> already covers the failure branch, but only its return value,
which nothing displays.

=cut
