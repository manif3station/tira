#!/usr/bin/env perl
# Investigated live, 2026-08-24: this machine had two "d2 tira.police" daemons
# running against this exact board at once (PIDs confirmed via ps, both
# calling police_pass on their own interval), alongside five stray
# "d2 tira.policy.bridge" tails left over from earlier sessions that were
# never terminated. violation_record - the function every police_pass call
# uses to update the enforcement ledger's escalation state - used to read the
# whole ledger, mutate an in-memory copy, and write the whole thing back with
# _atomic_write, with no lock: a second daemon whose read landed before the
# first daemon's write already had its own already-recorded violation
# silently replaced out from under it, with no error and no conflict raised
# anywhere.
#
# TKT-273 protected exactly one field this way (announced_version), by
# recording a list of announcements already made rather than a single "last
# seen" value - proving the project already knew how to make this safe. This
# generalises the same protection the project already gives every other
# read-modify-write (t/53) to the enforcement ledger: violation_record now
# holds an exclusive lock across its own read and write, the same shape
# _with_project_lock already uses for the project root, scoped to the
# violation store instead.
#
# The lock closes the write-corruption hole (two writers racing inside one
# read-modify-write cycle) but is not by itself a claim that two daemons on
# one board are now safe in every sense: a full pass reports the complete
# violation set it found and settles anything absent from that set, by
# design, so a daemon whose own scan predates another daemon's still reports
# truthfully for what IT saw. Whether the fuller fix also needs to stop a
# second daemon from starting against the same board at all is asked on this
# ticket as Q-067, not decided here.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-24T09:00:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );
$tira->project_new(
    name => 'Raced', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RCS', epic_prefix => 'RCE', ticket_prefix => 'RCT',
);

my $violation_a = { rule => 'orphan-card', policy => 'POL-001', ref => 'RCT-001',
    detail => 'first watcher found this', action => 'bridge-reminder' };
my $violation_b = { rule => 'orphan-card', policy => 'POL-002', ref => 'RCT-002',
    detail => 'second watcher found this, a moment later', action => 'bridge-reminder' };

# Whether the enforcement lock is held, asked the only way that gives a
# straight answer: a second handle in this process is a second lock entry, so
# if it cannot be taken without blocking, somebody is holding it. Same probe
# t/53 uses for the project lock.
sub lock_held {
    my ($store_dir) = @_;
    open my $probe, '>>', File::Spec->catfile( $store_dir, '.lock' ) or die $!;
    my $free = flock( $probe, LOCK_EX | LOCK_NB );
    flock( $probe, LOCK_UN ) if $free;
    close $probe;
    return $free ? 0 : 1;
}

my $before_either = $tira->_violation_ledger($store);
is_deeply( $before_either, { counter => 0, open => {} },
    'a fresh store starts with an empty ledger, as every board does' );
ok( !lock_held($store), 'the enforcement lock is free when nothing is running' );

# --- the read is half the race, so wrapping only the write would fix -------
# nothing: prove the lock is held while the ledger is read, not just while it
# is written back -------------------------------------------------------------

my $held_during_read;
{
    no warnings 'redefine';
    my $original = \&Tira::_violation_ledger;
    local *Tira::_violation_ledger = sub {
        my ( $self, $s ) = @_;
        $held_during_read = lock_held($s);
        return $original->( $self, $s );
    };
    $tira->violation_record( store => $store, violations => [$violation_a] );
}
ok( $held_during_read,
    'violation_record holds the enforcement lock while it reads the ledger' );
ok( !lock_held($store), 'and releases it once the pass finishes' );

# --- two watchers, one after another - what the lock forces any two real ---
# daemons into, since a second pass cannot start reading until the first has
# both read and written. Watcher B's own pass genuinely did not detect A's
# problem (it is a different, unrelated violation elsewhere on the board), so
# B settling it here is the ledger working as designed, not the race: a full
# pass reports the complete truth as of that scan, and closes what it no
# longer finds. That is exactly why the lock is not the whole fix - it stops
# a second writer from reading and corrupting the FIRST writer's own
# read-modify-write cycle mid-flight, but it cannot make a stale scan's
# verdict correct. Filed as Q-067 on this ticket: whether a full fix also
# needs to stop a second daemon from running against the same board at all. -

$tira->violation_record( store => $store, violations => [$violation_b] );
my $after_both = $tira->_violation_ledger($store);
ok( ( grep { ( $_->{about}{ref} // '' ) eq 'RCT-002' } values %{ $after_both->{open} } ),
    "watcher B's own pass is recorded correctly once the lock lets it read and write cleanly" );

# --- a failure partway through a pass must not leave the lock held ---------

{
    no warnings 'redefine';
    local *Tira::_violation_ledger = sub { die "boom\n" };
    eval { $tira->violation_record( store => $store, violations => [$violation_a] ) };
    like( $@, qr/boom/, 'a failure during the pass is reported' );
}
ok( !lock_held($store), 'and the lock is still released after a failure' );

done_testing;

__END__

=head1 NAME

364-two-watchers-one-ledger.t - the enforcement ledger under two police daemons

=head1 DESCRIPTION

C<violation_record> reads the whole enforcement ledger, mutates an in-memory
copy, and writes the whole thing back. Investigated live after finding two
C<d2 tira.police> daemons actually running against this board at once: a
second daemon whose read predates a first daemon's write - exactly what two
concurrent daemons produce by ordinary scheduling, no fault of either - used
to silently erase the first daemon's already-reported violation rather than
merge it, which was indistinguishable from that violation never having been
announced at all.

C<violation_record> now holds an exclusive lock, scoped to the violation
store, across its own read and write - the same shape C<_with_project_lock>
already gives every other read-modify-write in this project (t/53), applied
here to the one place that was still missing it. Proves the lock is held
during the read (not just the write), that a failure partway through still
releases the lock, and that a watcher's own pass writes cleanly once the lock
lets it read and write without a second writer racing the same cycle.

Whether stopping the write-corruption race is the whole fix, or whether a
second police daemon should be prevented from starting against the same
board at all, is asked on TKT-486 as Q-067.

=cut
