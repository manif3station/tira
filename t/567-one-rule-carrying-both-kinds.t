#!/usr/bin/env perl
# TKT-945. His decision, Q-127 on TKT-944, answered 2026-09-05T19:22:58:
# "Widen monitor-output to carry cron command output too (one mechanism, but
# the rule's name stops matching what it does)." He was shown three options -
# widen this rule, add a second rule, or leave the output on the job - and
# picked this one with its cost written into the option he chose.
#
# WHAT WAS TRUE BEFORE. TKT-944 wired the execution step, so a due
# command-mode job runs and its output is fed through job_feed onto the job
# record - the same pipe a monitor's output travels. But this rule skipped
# every job whose schedule_kind was not 'monitor', so that output was drained
# by nothing and announced to nobody. The producing half existed and the
# carrying half refused to look.
#
# HOW IT IS WIDENED, and it is a deletion rather than an addition. The
# monitor-only skip goes; the guards already standing do the rest. A
# message-mode job carries no command at all, so the existing
# `next if !defined $job->{command}` keeps it out without a new condition
# being invented for it - which matters, because a second condition meaning
# nearly what an existing one means is the fault t/566 was just written to
# catch.
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
        name => 'One Mechanism', dir => $root, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'OMS', epic_prefix => 'OME', ticket_prefix => 'OMT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    $tira->policy_add( project => $root, rule => 'monitor-output', action => 'bridge-reminder' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ), \$now );
}

sub carried {
    my ( $tira, $root, $store ) = @_;
    my $pass = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    return [ grep { ( $_->{rule} // '' ) eq 'monitor-output' } @{ $pass->{violations} || [] } ];
}

# --- a cron command job's output reaches the bridge ------------------------
#
# The whole of his decision.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '*/30 * * * *',
        command => 'd2 tira.police.outstanding' );

    # What TKT-944's run_due_commands puts there after the command has run.
    $tira->job_feed( project => $root, id => 'JOB-001',
        lines => ['the cron run said this'] );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $found = carried( $tira, $root, $store );

    is( scalar @{$found}, 1,
        "a cron command job's output is carried to the bridge - the half that refused to look" );
    like( $found->[0]{detail}, qr/the cron run said this/,
        'and it is the output itself that is carried, not a notice that there was some' );
}

# --- a monitor's output is carried exactly as before -----------------------
#
# The regression that would matter most: this rule's original job.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => 'monitor',
        command => 'perl -e "print 1"' );
    $tira->job_feed( project => $root, id => 'JOB-001',
        lines => ['the monitor called in'] );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $found = carried( $tira, $root, $store );

    is( scalar @{$found}, 1, "a monitor's output is still carried" );
    like( $found->[0]{detail}, qr/the monitor called in/, 'and is still its own words' );
}

# --- a message-mode job puts nothing here ---------------------------------
#
# Kept out by a guard that already existed rather than by a new one. A
# message job has no command, so the rule's own defined-command check
# excludes it - inventing a second condition meaning nearly that would be the
# fault t/566 exists to catch.

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '* * * * *',
        message => 'a message-mode job announces and produces no output' );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $found = carried( $tira, $root, $store );
    is( scalar @{$found}, 0,
        'a message-mode job contributes nothing to this rule, and is kept out by the '
          . 'defined-command guard that was already there' );
}

# --- a disabled job stays silent ------------------------------------------

{
    my ( $tira, $root, $store, $clock ) = board();
    $tira->job_add( project => $root, schedule => '*/30 * * * *', command => '/bin/true' );
    $tira->job_feed( project => $root, id => 'JOB-001', lines => ['said before being switched off'] );
    $tira->job_update( project => $root, id => 'JOB-001', enabled => 0 );

    ${$clock} = '2026-09-05T09:30:00Z';
    my $found = carried( $tira, $root, $store );
    is( scalar @{$found}, 0, 'a disabled job is silent whatever it once queued' );
}

# --- the name is admitted to be narrower than the behaviour ---------------
#
# He chose this option with that cost stated in it. A name that quietly stops
# matching what it does is exactly the drift t/566 was written for, so it has
# to be loud where a reader meets the rule rather than left to be discovered.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the checks below would pass on an
    # unreadable file's emptiness alone otherwise.
    like( $engine, qr/\S/, 'the engine source is there to be read' );
    like( $engine, qr/name is narrower than/i,
        'the rule body says its name is narrower than what it carries, rather than leaving it to be found' );

    open my $fh, '<:raw', 'docs/POLICIES.md' or die $!;
    my $policies = do { local $/; <$fh> };
    close $fh;
    like( $policies, qr/\S/, 'POLICIES.md is there to be read' );
    like( $policies, qr/TKT-945/,
        "and the rule's own row records the widening where somebody declaring it will read it" );
}

done_testing();

__END__

=head1 NAME

567-one-rule-carrying-both-kinds.t - monitor-output carries a cron command job's output too

=head1 DESCRIPTION

TKT-945, from his answer to Q-127. C<monitor-output> skipped every job whose
schedule was not C<monitor>, so the output TKT-944 began feeding onto a cron
command job was drained by nothing. The monitor-only skip is removed and the
guards already present do the rest - a message-mode job has no command, so the
existing defined-command check keeps it out without a second condition being
invented. He accepted the cost when he chose this over a second rule: the rule
is still called C<monitor-output> while carrying more than monitors' output,
which is said in the rule body and in C<docs/POLICIES.md> rather than left to
be discovered.

=cut
