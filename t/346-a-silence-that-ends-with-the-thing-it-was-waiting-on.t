#!/usr/bin/env perl
# The 600s clock-only ceiling is shorter than either gate this repo runs -
# coverage at 846s, pre-push at 15m and counting - so the commonest
# legitimate reason for a suspension (waiting on a gate) always outlived the
# longest suspension that could be given. Twice in one session a rule was
# suspended, expired mid-gate, re-fired, and was suspended again with the
# same reason.
#
# rule_suspend can now be tied to a running process (--pid) instead of only
# a clock: it lifts the moment that process is gone, with a higher, measured
# ceiling as a backstop so a process that never exits still cannot make the
# silence permanent. TKT-361.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Waiting', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Bare' );
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

sub sweep { return $tira->police_pass( project => $root, store => $store, world => {} ); }

ok( scalar @{ sweep()->{violations} }, 'card-full-details has something to say before any of this' );

# --- the clock form is unchanged: same ceiling, same mandatory reason ------

ok( !eval { $tira->rule_suspend( project => $root, store => $store,
        rule => 'card-full-details', seconds => 601, reason => 'still 600s without a pid' ); 1 },
    'the clock-only ceiling is still 600 seconds' );
like( $@, qr/600/, 'and says so' );

# --- tied to a real, running process: still down while it runs -------------

my $self_pid = $$;    # this test process itself - guaranteed alive throughout
$tira->rule_suspend( project => $root, store => $store,
    rule => 'card-full-details', seconds => 900, pid => $self_pid,
    reason => 'waiting on the gate' );

my $during = sweep();
is_deeply( $during->{violations}, [], 'nothing is reported while the named process is still running' );

# --- and lifts the moment that process is gone, before the clock would ----

# A pid nothing on this machine holds - reused pids are vanishingly unlikely
# inside a single test run, and this one is chosen high on purpose.
my $gone_pid = 2**30 - 1;
$tira->rule_suspend( project => $root, store => $store,
    rule => 'card-full-details', seconds => 900, pid => $gone_pid,
    reason => 'waiting on a gate that already finished' );

my $after = sweep();
ok( scalar @{ $after->{violations} }, 'reported again the moment the named process is gone, '
      . 'well before the 900s clock would have said so' );

# --- the hard cap is still there, and higher for a pid-scoped suspension ---

ok( !eval { $tira->rule_suspend( project => $root, store => $store,
        rule => 'card-full-details', seconds => 1801, pid => $self_pid,
        reason => 'too long even with a pid' ); 1 },
    'a pid-scoped suspension still has a ceiling, so a process that never exits cannot make it permanent' );
like( $@, qr/1800/, 'and the ceiling is the higher, measured one - covering the longest gate this repo runs' );

# --- and a suspension tied to a process that is still running, but past its own clock ceiling, ends --

$tira->rule_suspend( project => $root, store => $store,
    rule => 'card-full-details', seconds => 60, pid => $self_pid,
    reason => 'a short leash on a process that outlives it' );
$now = '2026-08-23T09:02:00Z';    # 120s later - past the 60s given, even though $self_pid is still alive
ok( scalar @{ sweep()->{violations} }, 'the clock backstop still ends it even while the process runs on' );

# --- pid is rejected if not a positive whole number -------------------------

ok( !eval { $tira->rule_suspend( project => $root, store => $store,
        rule => 'card-full-details', seconds => 60, pid => 'not-a-number',
        reason => 'a bad pid' ); 1 },
    'a non-numeric pid is refused' );
like( $@, qr/pid/i, 'and says so' );

done_testing;

__END__

=head1 NAME

346-a-silence-that-ends-with-the-thing-it-was-waiting-on.t - a suspension tied to a process, not only a clock

=head1 DESCRIPTION

C<rule_suspend>'s 600s clock-only ceiling was shorter than the gates it
exists to cover, so the commonest legitimate reason for a suspension always
expired mid-gate and had to be re-supplied. This proves the new C<--pid>
form: a suspension that lifts the moment the named process is gone, backed
by a higher, measured ceiling so a process that never exits still cannot
make the silence permanent - while the clock-only form keeps its original
600s ceiling unchanged.

=cut
