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
    Tira::CLI::_police_follow(
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
    follow( singleton => {
        pid => 111,
        alive => sub { return 0 },
        kill  => sub { push @killed, $_[0] },
    } );
    ok( -f File::Spec->catfile( $store, '.police.pid' ), 'the claim leaves a pid file behind' );
    open my $fh, '<', File::Spec->catfile( $store, '.police.pid' ) or die $!;
    my $written = do { local $/; <$fh> };
    close $fh;
    is( $written, '111', 'carrying this run\'s own pid' );
    is( scalar @killed, 0, 'nothing was killed - there was nothing to kill' );
}

# --- a second daemon claiming kills the first, the loser ---------------------

{
    my @killed;
    my @alive_checked;
    follow( singleton => {
        pid => 222,
        alive => sub { push @alive_checked, $_[0]; return 1 },
        kill  => sub { push @killed, $_[0] },
    } );
    is_deeply( \@alive_checked, [111], 'the previous pid is checked for life' );
    is_deeply( \@killed, [111], 'and killed - it is the loser, the new run is the winner' );
    open my $fh, '<', File::Spec->catfile( $store, '.police.pid' ) or die $!;
    is( do { local $/; <$fh> }, '222', 'the new pid overwrites the old claim' );
    close $fh;
}

# --- a dead previous pid is not killed - nothing to kill, just overwritten --

{
    my @killed;
    follow( singleton => {
        pid => 333,
        alive => sub { return 0 },
        kill  => sub { push @killed, $_[0] },
    } );
    is( scalar @killed, 0, 'a pid that is no longer alive is not sent a signal' );
}

# --- a clean exit releases the claim ------------------------------------------

{
    my $left = 0;
    follow(
        singleton => { pid => 444, alive => sub { 0 }, kill => sub { } },
        extra => { leave => sub { $left = 1 } },
    );
    ok( -f File::Spec->catfile( $store, '.police.pid' ),
        'the claim exists while the daemon is still running its rounds' );
    kill 'TERM', $$;    # exercised through the real SIG{TERM} handler _police_follow installs
    ok( $left, 'the injected leave handler ran on the signal' );
    ok( !-f File::Spec->catfile( $store, '.police.pid' ),
        'and a clean exit released the claim, so the next daemon sees nothing stale' );
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

    my $default_store = File::Spec->catdir( $tmp, 'default-store' );
    my $child = fork;
    die 'cannot fork' if !defined $child;
    if ( !$child ) {
        $SIG{TERM} = sub { exit 0 };
        sleep 30;
        exit 1;    # only reached if TERM never arrived
    }

    # The real default 'alive' answers true for a process that is genuinely
    # still there, and the real default 'kill' really signals it - claiming
    # with no overrides at all, the shape a real second daemon would use.
    Tira::CLI::_police_claim_singleton( $default_store, pid => $child );
    Tira::CLI::_police_claim_singleton( $default_store, pid => $$ );
    waitpid $child, 0;
    my $status = $? >> 8;
    is( $status, 0, "the real default kill actually signalled the child, which left cleanly on TERM" );

    # And the real default 'alive' answers false for a pid nothing is using -
    # high enough that no live process plausibly holds it - so claiming does
    # not try to signal something that no longer exists.
    open my $fh, '>', File::Spec->catfile( $default_store, '.police.pid' ) or die $!;
    print {$fh} 2**30;
    close $fh;
    my $claim = Tira::CLI::_police_claim_singleton( $default_store, pid => $$ );
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
