#!/usr/bin/env perl
# TKT-492, follow-up to TKT-486. Found live: two "d2 tira.police" daemons
# running against the same board at once, racing the enforcement ledger.
# TKT-486/TKT-487 locked the write itself; this is the root cause TKT-486
# asked about and Michael answered directly: "d2 tira.police is a singleton
# process. Whoever the last run it is the winner and the loser process will
# be killed."
#
# Scoped to the persistent daemon (_police_follow), not --once: a single
# pass is not "a process" in the sense that answer means, and killing a
# real watcher because something asked a quick status question would be
# more surprising than helpful.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
# Tira::CLI::Police holds the police pass, the bridge and the world scan since
# 4.74 (TKT-607). Tira::CLI loads it with require at the point a police verb
# runs, so a test calling into it directly has to ask for it itself.
require Tira::CLI::Police;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-24T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Singleton', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SGS', epic_prefix => 'SGE', ticket_prefix => 'SGT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

sub follow {
    my (%args) = @_;
    Tira::CLI::Police::police_follow(
        $tira, { project => $root }, $store,
        {   rounds => $args{rounds} // 1,
            sleeper => sub { },
            singleton => $args{singleton} // {},
            %{ $args{extra} // {} },
        }
    );
    return;
}

# --- claiming with nothing already running ----------------------------------

{
    my @killed;
    my $pid_path = File::Spec->catfile( $store, '.police.pid' );
    # TKT-1104: police_follow now releases its own claim on a normal
    # finite-rounds exit (the same as its signal handler already did), so
    # the file is checked WHILE the round is still running (via the
    # injected sleeper, which runs inside the loop) rather than after
    # follow() has already returned and released it.
    my $written;
    follow( singleton => {
        pid => 111,
        alive => sub { return 0 },
        kill  => sub { push @killed, $_[0] },
    }, extra => { sleeper => sub {
        open my $fh, '<', $pid_path or die $!;
        $written = do { local $/; <$fh> };
        close $fh;
    } } );
    is( $written, '111', 'the claim leaves a pid file behind, carrying this run\'s own pid, while the round runs' );
    ok( !-f $pid_path, 'and releases it once the round (and the whole finite-rounds call) has finished' );
    is( scalar @killed, 0, 'nothing was killed - there was nothing to kill' );
}

# --- a second daemon claiming kills the first, the loser ---------------------

{
    # TKT-1104: the previous block's own claim (pid 111) is no longer left
    # behind for this block to find - a normal finite-rounds follow() now
    # releases its own claim on exit, same as that block already proved.
    # Set up this block's own precondition directly instead of relying on
    # leftover state from the previous one.
    Tira::CLI::Police::police_claim_singleton( $store, pid => 111, alive => sub { 0 }, kill => sub { } );

    my @killed;
    my @alive_checked;
    my $written;
    follow( singleton => {
        pid => 222,
        alive => sub { push @alive_checked, $_[0]; return 1 },
        kill  => sub { push @killed, $_[0] },
    }, extra => { sleeper => sub {
        open my $fh, '<', File::Spec->catfile( $store, '.police.pid' ) or die $!;
        $written = do { local $/; <$fh> };
        close $fh;
    } } );
    is_deeply( \@alive_checked, [111], 'the previous pid is checked for life' );
    is_deeply( \@killed, [111], 'and killed - it is the loser, the new run is the winner' );
    is( $written, '222', 'the new pid overwrites the old claim, while the round runs' );
}

# --- a dead previous pid is not killed - nothing to kill, just overwritten --

{
    # TKT-1104: the previous block's own claim is gone (released on its
    # own normal exit), so this block needs its own precondition to
    # actually exercise alive() at all, rather than vacuously passing
    # because there is nothing left to check aliveness of. A DIFFERENT
    # pid than the one claiming below - police_claim_singleton skips the
    # alive() check entirely when the previous pid equals the new one
    # (a process reclaiming its own slot, not a rival).
    Tira::CLI::Police::police_claim_singleton( $store, pid => 300, alive => sub { 0 }, kill => sub { } );

    my @killed;
    my @alive_checked;
    follow( singleton => {
        pid => 333,
        alive => sub { push @alive_checked, $_[0]; return 0 },
        kill  => sub { push @killed, $_[0] },
    } );
    is_deeply( \@alive_checked, [300], 'aliveness really was checked for the previous pid' );
    is( scalar @killed, 0, 'a pid that is no longer alive is not sent a signal' );
}

# --- a clean exit releases the claim ------------------------------------------

{
    my $left = 0;
    my $existed_mid_round;
    # TKT-1104: follow() runs rounds=>1 synchronously and returns before
    # this block continues, and a normal finite-rounds exit now releases
    # the claim itself (this ticket's own fix) - so the file is checked
    # mid-round, via the injected sleeper, to prove it really was held
    # while the daemon was running.
    follow(
        singleton => { pid => 444, alive => sub { 0 }, kill => sub { } },
        extra => { leave => sub { $left = 1 }, sleeper => sub {
            $existed_mid_round = -f File::Spec->catfile( $store, '.police.pid' ) ? 1 : 0;
        } },
    );
    ok( $existed_mid_round, 'the claim existed while the daemon was still running its rounds' );
    ok( !-f File::Spec->catfile( $store, '.police.pid' ),
        'and a normal, finite-rounds exit already released it, so the next daemon sees nothing stale' );

    # The signal handler _police_follow installed is still live in %SIG
    # after a normal return (a global, not scoped to the call) - firing
    # it late, against a claim its own normal exit already released, must
    # still run the leave handler and must not die trying to release an
    # already-gone file.
    kill 'TERM', $$;
    ok( $left, 'and the still-installed signal handler still runs cleanly afterward' );
}

# --- the real pid/alive/kill defaults, not just the injected fakes above ---
#
# Proved against a real forked process rather than a mock, the same way
# t/84 proves a real signal really ends a real police process - an
# injected 'alive'/'kill' proves the claim logic, not that the actual
# kill(0,...)/kill('TERM',...) defaults this ships with work at all.

SKIP: {
    skip 'fork is not available here', 3
      if !eval { my $pid = fork; defined $pid or die; $pid == 0 and exit 0; waitpid $pid, 0; 1 };

    # A pipe rather than a bare fork+sleep: without it, sending TERM races
    # the child's own $SIG{TERM} assignment - under heavy parallel load
    # (prove -j, several Devel::Cover processes contending for CPU) that
    # window widens enough for the signal to arrive before the handler is
    # installed and be lost outright, the child then runs its full sleep
    # to completion and exits 1, which is exactly what an intermittent
    # failure of the very next assertion looked like. Reproduced directly:
    # 8-way parallel `prove` on this one file failed with the child's
    # fallback exit code after a genuine 30-second wait. The child closes
    # the write end once its handler is live; the parent blocks reading
    # the pipe before sending anything, so TERM is never sent early.
    my $default_store = File::Spec->catdir( $tmp, 'default-store' );
    pipe my $ready_read, my $ready_write or die "Cannot open pipe: $!\n";
    my $child = fork;
    die 'cannot fork' if !defined $child;
    if ( !$child ) {
        close $ready_read;
        $SIG{TERM} = sub { exit 0 };
        close $ready_write;    # signals readiness by closing its end
        sleep 30;
        exit 1;    # only reached if TERM never arrived
    }
    close $ready_write;
    my $discard = <$ready_read>;    # blocks until the child closes its end
    close $ready_read;

    # The real default 'alive' answers true for a process that is genuinely
    # still there, and the real default 'kill' really signals it - claiming
    # with no overrides at all, the shape a real second daemon would use.
    Tira::CLI::Police::police_claim_singleton( $default_store, pid => $child );
    Tira::CLI::Police::police_claim_singleton( $default_store, pid => $$ );
    waitpid $child, 0;
    my $status = $? >> 8;
    is( $status, 0, "the real default kill actually signalled the child, which left cleanly on TERM" );

    # And the real default 'alive' answers false for a pid nothing is using -
    # high enough that no live process plausibly holds it - so claiming does
    # not try to signal something that no longer exists.
    open my $fh, '>', File::Spec->catfile( $default_store, '.police.pid' ) or die $!;
    print {$fh} 2**30;
    close $fh;
    my $claim = Tira::CLI::Police::police_claim_singleton( $default_store, pid => $$ );
    ok( !defined $claim->{killed}, 'and a pid nothing is using is not treated as a rival to kill' );
    open my $read, '<', File::Spec->catfile( $default_store, '.police.pid' ) or die $!;
    is( do { local $/; <$read> }, $$, 'the claim still passes to this process' );
}

done_testing;

__END__

=head1 NAME

373-a-singleton-that-kills-its-rival.t - only the newest police daemon watches

=head1 DESCRIPTION

Two live C<d2 tira.police> daemons on one board raced the enforcement
ledger (TKT-486). Michael's answer: police is a singleton, and the newest
run kills whichever one was already running. C<_police_follow> now claims
a pid file in the violation store before its first round, killing a still-
alive previous claimant, and releases the claim on a clean signal-driven
exit. pid/alive/kill are all injectable, so this is provable without
spawning or signalling a real OS process.

=cut
