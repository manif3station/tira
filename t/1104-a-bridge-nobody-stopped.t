#!/usr/bin/env perl
# TKT-1100. Repeated "d2 tira.dashboard" starts each spawned their own
# police AND policy.bridge child beside the served board. Police already
# had a singleton claim (t/373, TKT-492/897) that killed a previous
# daemon before its own watch started; bridge_follow had nothing - no
# claim, no kill-previous, no signal handler - so every past bridge from
# an earlier dashboard just kept running, unbounded, beside the newest one.
#
# Same mechanism as police, a different file: police_singleton_path's own
# 'policy-bridge' kind, so a bridge and a police daemon spawned by the same
# dashboard are never mistaken for each other's rival.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Police;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-15T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Bridged', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'BGS', epic_prefix => 'BGE', ticket_prefix => 'BGT',
);
my $store = File::Spec->catdir( $tmp, 'police' );

sub follow {
    my (%args) = @_;
    Tira::CLI::Police::bridge_follow(
        $tira, $store,
        rounds  => $args{rounds} // 1,
        sleeper => sub { },
        singleton => $args{singleton} // {},
        %{ $args{extra} // {} },
    );
    return;
}

# --- claiming with nothing already running, its own file, not police's ------

{
    my @killed;
    follow( singleton => {
        pid => 111,
        alive => sub { return 0 },
        kill  => sub { push @killed, $_[0] },
    } );
    ok( -f File::Spec->catfile( $store, '.policy-bridge.pid' ),
        'the claim leaves its OWN pid file behind' );
    ok( !-f File::Spec->catfile( $store, '.police.pid' ),
        'and never touches police\'s own file' );
    open my $fh, '<', File::Spec->catfile( $store, '.policy-bridge.pid' ) or die $!;
    is( do { local $/; <$fh> }, '111', 'carrying this run\'s own pid' );
    close $fh;
    is( scalar @killed, 0, 'nothing was killed - there was nothing to kill' );
}

# --- a second bridge claiming kills the first, the loser ---------------------

{
    my @killed;
    my @alive_checked;
    follow( singleton => {
        pid => 222,
        alive => sub { push @alive_checked, $_[0]; return 1 },
        kill  => sub { push @killed, $_[0] },
    } );
    is_deeply( \@alive_checked, [111], 'the previous bridge pid is checked for life' );
    is_deeply( \@killed, [111], 'and killed - it is the loser, the new run is the winner' );
    open my $fh, '<', File::Spec->catfile( $store, '.policy-bridge.pid' ) or die $!;
    is( do { local $/; <$fh> }, '222', 'the new pid overwrites the old claim' );
    close $fh;
}

# --- a dashboard-held bridge is not killed by an ordinary one ----------------
#
# Exercised through bridge_follow itself, not just police_claim_singleton, for
# the reason t/519 gives for police's own identical case: a claim that a
# branch exists is not a claim that it runs.

{
    Tira::CLI::Police::police_claim_singleton( $store,
        kind => 'policy-bridge', pid => 333, holder => 'dashboard', alive => sub { 0 }, kill => sub { } );

    my @killed;
    my $status;
    my $said = '';
    {
        local *STDERR;
        open *STDERR, '>', \$said or die "cannot capture stderr: $!";
        $status = Tira::CLI::Police::bridge_follow( $tira, $store,
            rounds => 1, sleeper => sub { },
            singleton => { pid => 444, alive => sub { 1 }, kill => sub { push @killed, $_[0] } } );
    }
    is( $status, 0, 'an ordinary bridge yields to the dashboard-held one - standing aside, not a failure' );
    is( scalar @killed, 0, 'and does not kill it' );
    like( $said, qr/standing down/, 'and says so, naming the pid it is yielding to' );
    open my $fh, '<', File::Spec->catfile( $store, '.policy-bridge.pid' ) or die $!;
    is( do { local $/; <$fh> }, '333 dashboard', "the dashboard's own claim is untouched by the yield" );
    close $fh;
}

# --- a clean exit releases the claim, and only its own file -----------------

{
    my $left = 0;
    follow(
        singleton => { pid => 555, alive => sub { 0 }, kill => sub { } },
        extra => { leave => sub { $left = 1 } },
    );
    ok( -f File::Spec->catfile( $store, '.policy-bridge.pid' ),
        'the claim exists while the bridge is still running its rounds' );
    kill 'TERM', $$;    # exercised through the real SIG{TERM} handler bridge_follow installs
    ok( $left, 'the injected leave handler ran on the signal' );
    ok( !-f File::Spec->catfile( $store, '.policy-bridge.pid' ),
        'and a clean exit released the claim, so the next bridge sees nothing stale' );
}

# --- a successor's claim survives a stale signal handler (Codex, TKT-1100) --
#
# A new bridge kills the old pid and writes its own claim; if the OLD
# process's signal handler then runs and releases unconditionally, it would
# delete the successor's live claim rather than its own already-superseded
# one. police_release_singleton is ownership-aware since this finding: it
# only removes the file if it still names the releasing pid.

{
    follow( singleton => { pid => 666, alive => sub { 0 }, kill => sub { } } );
    ok( -f File::Spec->catfile( $store, '.policy-bridge.pid' ), 'pid 666 holds the claim' );

    # A successor claims now, as if it started while 666's own process was
    # still between being killed and running its signal handler.
    Tira::CLI::Police::police_claim_singleton( $store,
        kind => 'policy-bridge', pid => 777, alive => sub { 0 }, kill => sub { } );
    open my $fh, '<', File::Spec->catfile( $store, '.policy-bridge.pid' ) or die $!;
    is( do { local $/; <$fh> }, '777', 'the successor now holds the claim' );
    close $fh;

    # 666's own release now runs, late, against a file it no longer owns.
    Tira::CLI::Police::police_release_singleton( $store, kind => 'policy-bridge', pid => 666 );
    open my $read, '<', File::Spec->catfile( $store, '.policy-bridge.pid' ) or die $!;
    is( do { local $/; <$read> }, '777',
        'a stale release naming the wrong pid leaves the successor\'s live claim untouched' );
    close $read;
}

# --- the real default leave handler really ends the process -----------------
#
# Same reason t/84 proves this for police_follow: a default of `exit 0` cannot
# be proved in this process without ending it, so it is proved in a child.

SKIP: {
    skip 'fork is not available here', 2
      if !eval { my $pid = fork; defined $pid or die; $pid == 0 and exit 0; waitpid $pid, 0; 1 };

    my $child = fork;
    die 'cannot fork' if !defined $child;
    if ( !$child ) {
        close STDERR;
        Tira::CLI::Police::bridge_follow( $tira,
            File::Spec->catdir( $tmp, 'really-leaving' ), rounds => 1, interval => 0 );
        $SIG{INT}->('INT');
        exit 99;    # only reached if the handler did not leave
    }
    waitpid $child, 0;
    my $status = $? >> 8;
    is( $status, 0, 'the default handler really does end the process' );
    isnt( $status, 99, 'rather than saying it is going and carrying on' );
}

done_testing;

__END__

=head1 NAME

1104-a-bridge-nobody-stopped.t - only the newest policy.bridge daemon watches

=head1 DESCRIPTION

TKT-1100: repeated C<d2 tira.dashboard> starts left every past
C<policy.bridge> child running beside the newest one - police already had
a singleton claim protecting it from this, the bridge had none.
C<bridge_follow> now claims a pid file (its own, C<.policy-bridge.pid>,
never police's C<.police.pid>) before its first round, kills a still-alive
previous claimant, yields to a dashboard-held claim the same way police
does, and releases the claim on a clean signal-driven exit.

=cut
