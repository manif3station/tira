#!/usr/bin/env perl
# A monitor that is up, and has not said a word since it declared it would.
#
# TKT-873, seventh member of TKT-893, EPC-014.
#
# WHAT THE TWO EXISTING RULES CANNOT SAY. monitor-dead finds a monitor whose
# PROCESS is gone. monitor-output carries a running monitor's words to the
# bridge. Between them sits the case neither covers: the process is there, the
# words have stopped, and both rules are content. docs/POLICIES.md admits it in
# its own words - "a monitor that is alive but WEDGED - process up, polling
# stopped - reads as alive" - and says catching it "needs the monitor to report
# progress, which needs it to cooperate".
#
# THEY COOPERATE NOW. TKT-851's feeder stamps last_output_at every time a
# monitor speaks. And TKT-863 added the second fact this needs: expect_every,
# how often a monitor says it ought to speak, which the owner chose over a
# board-wide constant in Q-115 because a monitor's schedule is the literal
# string 'monitor' and there is nothing to derive a cadence from.
#
# SO THIS RULE READS THAT FIELD RATHER THAN INVENTING A NOTION OF LATE. The
# dashboard heartbeat already reads it (TKT-863); a police rule with its own
# private threshold would be a second opinion about the same monitor, and the
# page and the bridge disagreeing about whether something is late is worse than
# neither of them saying anything.
#
# UNDECLARED MEANS SILENT, and that is his answer rather than a convenience. A
# monitor that declares no expectation cannot be late, because nobody said when
# it was due - JOB-005 is quiet for over an hour because it speaks only when he
# goes away, and a rule that cried about it would be one nobody reads.
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

# --- the rule exists and says what it needs -----------------------------------

{
    my $rules = Tira::policy_rules();

    # non-empty is the whole claim: the assertion below searches this list, and
    # an empty one would fail it for the wrong reason.
    cmp_ok( scalar @{$rules}, '>', 0, 'there are rules to look through' );

    ok( ( grep { $_ eq 'monitor-silent' } @{$rules} ),
        'there is a rule for a monitor that is up and has stopped speaking - '
          . 'the case monitor-dead and monitor-output both leave uncovered' );
}

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'Silent', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'SIS', epic_prefix => 'SIE', ticket_prefix => 'SIT',
    );
    $tira->policy_add(
        project => $root, rule => 'monitor-silent', action => 'log-only' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ) );
}

# A monitor that is UP: the pid is this process, so any liveness check finds it.
sub speaking_monitor {
    my ( $tira, $root, %args ) = @_;
    my $job = $tira->job_add(
        project => $root, schedule => 'monitor', command => 'd2 tira.policy.bridge',
        ( $args{expect_every} ? ( expect_every => $args{expect_every} ) : () ) );
    $tira->job_started( project => $root, id => $job->{id}, pid => $$ );
    return $job->{id};
}

sub findings {
    my ( $tira, $root, $store ) = @_;
    my $pass = $tira->police_pass(
        project => $root, store => $store, world => { processes => [] } );
    return [ grep { ( $_->{rule} // '' ) eq 'monitor-silent' }
          @{ $pass->{violations} || [] } ];
}

# --- a monitor silent past its own declared expectation ----------------------

{
    my ( $tira, $root, $store ) = board();
    my $id = speaking_monitor( $tira, $root, expect_every => 5 );

    # It spoke, an hour ago, and said it would speak every five minutes.
    $tira->{clock} = sub { '2026-09-03T19:00:00+0000' };
    $tira->job_feed( project => $root, id => $id, lines => ['still here'] );
    $tira->{clock} = sub { '2026-09-03T20:00:00+0000' };

    my $found = findings( $tira, $root, $store );
    cmp_ok( scalar @{$found}, '>', 0,
        'a monitor that has said nothing for twelve times its own declared '
          . 'expectation reaches the bridge' );

    like( ( $found->[0] || {} )->{detail} // '', qr/\Q$id\E/,
        'and the finding names which monitor has gone quiet' );
}

# --- one that spoke within its expectation is not reported -------------------

{
    my ( $tira, $root, $store ) = board();
    my $id = speaking_monitor( $tira, $root, expect_every => 60 );

    $tira->{clock} = sub { '2026-09-03T19:00:00+0000' };
    $tira->job_feed( project => $root, id => $id, lines => ['still here'] );
    $tira->{clock} = sub { '2026-09-03T19:10:00+0000' };

    is( scalar @{ findings( $tira, $root, $store ) }, 0,
        'a monitor well inside its own expectation is left alone' );
}

# --- and one that declared nothing cannot be late ----------------------------
#
# HIS ANSWER, and the reason the question was asked. JOB-005 is legitimately
# quiet for over an hour because it speaks only when he has gone away. A rule
# that judged it by a number nobody chose would be one nobody reads, which is
# the failure monitor-dead was written carefully to avoid.

{
    my ( $tira, $root, $store ) = board();
    my $id = speaking_monitor( $tira, $root );

    $tira->{clock} = sub { '2026-09-01T19:00:00+0000' };
    $tira->job_feed( project => $root, id => $id, lines => ['spoke once, days ago'] );
    $tira->{clock} = sub { '2026-09-03T20:00:00+0000' };

    is( scalar @{ findings( $tira, $root, $store ) }, 0,
        'a monitor that declared no expectation is never late, because nobody '
          . 'ever said when it was due' );
}

# --- and one that has never spoken at all is not this rule's business --------
#
# It has no last_output_at, so there is no silence to measure - it has not
# started saying anything yet. An enabled monitor with no pid is monitor-dead's
# case, and one that is up and has never fed a line is TKT-863's dim light.
# Reporting it here would be a third opinion about a monitor two rules already
# have views on.

{
    my ( $tira, $root, $store ) = board();
    my $id = speaking_monitor( $tira, $root, expect_every => 5 );
    $tira->{clock} = sub { '2026-09-03T20:00:00+0000' };

    is( scalar @{ findings( $tira, $root, $store ) }, 0,
        'a monitor that has never spoken is not reported as having stopped' );
}

# --- what must not change ----------------------------------------------------

{
    my ( $tira, $root, $store ) = board();

    my $cron = $tira->job_add(
        project => $root, schedule => '0 * * * *', command => 'd2 tira.stale' );
    $tira->{clock} = sub { '2026-09-03T20:00:00+0000' };

    is( scalar @{ findings( $tira, $root, $store ) }, 0,
        'a cron job is not reported - it is not supposed to be speaking '
          . 'between runs, which is the silence monitor-dead already keeps' );
}

{
    my ( $tira, $root, $store ) = board();
    my $id = speaking_monitor( $tira, $root, expect_every => 5 );

    $tira->{clock} = sub { '2026-09-03T19:00:00+0000' };
    $tira->job_feed( project => $root, id => $id, lines => ['still here'] );
    $tira->job_stop( project => $root, id => $id );
    $tira->job_update( project => $root, id => $id, enabled => 0 );
    $tira->{clock} = sub { '2026-09-03T20:00:00+0000' };

    is( scalar @{ findings( $tira, $root, $store ) }, 0,
        'and a disabled monitor is not reported either - it is absent on '
          . 'purpose, which is the other silence monitor-dead keeps' );
}

# --- and it refuses an age, rather than ignoring one --------------------------
#
# The lateness is already measured against what the monitor itself declared, so
# a grace period on top would be a threshold nobody chose sitting over one
# somebody did. Refused rather than silently dropped, which is the same
# judgement monitor-dead and monitor-output make - and the same
# silently-discarded-argument shape this project keeps finding elsewhere
# (TKT-748, TKT-888).

{
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'board' );
    my $tira = Tira->new;
    $tira->project_new(
        name => 'NoAge', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'NAS', epic_prefix => 'NAE', ticket_prefix => 'NAT',
    );

    # any failure is what this means. One call, and the only way it fails is the
    # refusal being asserted; anything else would equally be a policy_add that
    # did not accept a rule it should have refused an option on.
    my $ok = eval {
        $tira->policy_add(
            project => $root, rule => 'monitor-silent',
            age => '30m', action => 'log-only' );
        1;
    };
    my $why = $@;

    ok( !$ok, 'an age is refused, not quietly ignored' );
    like( $why, qr/age/i, 'and the refusal names the option it will not take' );
}

done_testing();

__END__

=head1 NAME

515-a-monitor-that-stopped-saying-anything.t - up, and no longer speaking

=head1 WHY

TKT-873, inside TKT-893. C<monitor-dead> reports a monitor whose process is
gone and C<monitor-output> carries a running one's words; neither covers a
monitor that is up and has stopped producing any. C<docs/POLICIES.md> admitted
that gap and said closing it needed the monitor to cooperate - which TKT-851's
feeder and TKT-863's C<expect_every> together now provide.

=head1 WHAT IS ASSERTED

That the rule exists; that a monitor silent past its own declared expectation
reaches the bridge and is named; that one inside its expectation is left alone;
that one which declared nothing is never late, which is the owner's own answer
to Q-115; that one which has never spoken is not this rule's business; and that
cron jobs and disabled monitors stay silent, matching the two silences
C<monitor-dead> already keeps.

=cut
