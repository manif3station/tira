#!/usr/bin/env perl
# TKT-487, found while implementing TKT-486: violation_record was not the
# only function racing the enforcement ledger file unlocked. _announce_moves
# (the move-notification stamp) and _agent_still_mark_notified (the
# agent-still throttle stamp) each did their own unlocked read-modify-write
# of the exact same file (_violation_ledger_path($store)), so a stale read in
# either one - or in violation_record itself - could silently overwrite
# whatever another writer had just recorded, the same lost-update TKT-486
# fixed for violation_record alone.
#
# Both now share the same _with_enforcement_lock helper violation_record
# uses, so all three serialise against each other rather than only against
# themselves.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Path qw(make_path);
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
    name => 'Shared', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SHS', epic_prefix => 'SHE', ticket_prefix => 'SHT',
);

# Same probe t/53 and t/364 use: a second handle in this process is a second
# lock entry, so if it cannot be taken without blocking, somebody holds it.
sub lock_held {
    my ($store_dir) = @_;
    open my $probe, '>>', File::Spec->catfile( $store_dir, '.lock' ) or die $!;
    my $free = flock( $probe, LOCK_EX | LOCK_NB );
    flock( $probe, LOCK_UN ) if $free;
    close $probe;
    return $free ? 0 : 1;
}

make_path($store);
ok( !lock_held($store), 'the enforcement lock is free when nothing is running' );

# --- _agent_still_mark_notified holds the lock across its own read+write ---

my $held_during_read;
{
    no warnings 'redefine';
    my $original = \&Tira::_violation_ledger;
    local *Tira::_violation_ledger = sub {
        my ( $self, $s ) = @_;
        $held_during_read = lock_held($s);
        return $original->( $self, $s );
    };
    $tira->_agent_still_mark_notified( $store, '2026-08-24T09:00:00Z' );
}
ok( $held_during_read,
    '_agent_still_mark_notified holds the enforcement lock while it reads the ledger' );
ok( !lock_held($store), 'and releases it once it is done' );

my $ledger = $tira->_violation_ledger($store);
is( $ledger->{agent_still_notified}{since}, '2026-08-24T09:00:00Z',
    'the stamp it wrote survives - the same lock a concurrent violation_record call now shares' );

# --- _announce_moves holds the lock across its own read+write too ----------

$tira->notify_moves( project => $root, enabled => 1 );
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that will move', priority => 3 );
$now = '2026-08-24T09:05:00Z';
$tira->record_move( author => 'claude', project => $root, ref => $card->{ref}, column => 'implement' );

{
    no warnings 'redefine';
    local *Tira::_send_notification = sub { return 1 };
    my $original = \&Tira::_violation_ledger;
    local *Tira::_violation_ledger = sub {
        my ( $self, $s ) = @_;
        $held_during_read = lock_held($s);
        return $original->( $self, $s );
    };
    $tira->_announce_moves( $root, $store );
}
ok( $held_during_read,
    '_announce_moves holds the enforcement lock while it reads the ledger' );
ok( !lock_held($store), 'and releases it once it is done' );

my $after = $tira->_violation_ledger($store);
is( $after->{notified_moves}{ $card->{ref} }, '2026-08-24T09:05:00Z',
    "the move stamp it wrote survives, and the earlier agent-still stamp is still there too" );
is( $after->{agent_still_notified}{since}, '2026-08-24T09:00:00Z',
    "one writer's own read-modify-write did not clobber the other writer's already-recorded state" );

# --- a failure partway through either one must not leave the lock held -----

{
    no warnings 'redefine';
    local *Tira::_violation_ledger = sub { die "boom\n" };
    eval { $tira->_agent_still_mark_notified( $store, '2026-08-24T09:10:00Z' ) };
    like( $@, qr/boom/, 'a failure inside _agent_still_mark_notified is reported' );
}
ok( !lock_held($store), 'and the lock is still released after that failure' );

done_testing;

__END__

=head1 NAME

365-a-third-writer-to-the-same-file.t - two more racers on the enforcement ledger

=head1 DESCRIPTION

TKT-486 locked C<violation_record>'s own read-modify-write of the
enforcement ledger. Grepping for other writers to the same file turned up
two more: C<_announce_moves> (the move-notification stamp) and
C<_agent_still_mark_notified> (the agent-still throttle stamp), both
following the identical unsafe shape - read the whole ledger, mutate a
sub-key, write the whole thing back - with no lock of their own. A stale
read in either could silently overwrite what any of the three writers had
just recorded.

Both now share C<_with_enforcement_lock>, the same helper C<violation_record>
uses. Proves each holds the lock across its own read and write, that a
failure partway through still releases it, and that one writer's own pass
does not clobber what another writer already recorded on the same file.

=cut
