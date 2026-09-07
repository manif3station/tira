#!/usr/bin/env perl
# TKT-995. Michael's report (photo + voice, 2026-09-07): a job on his own
# board, scheduled every ~3 hours, produced the SAME bridge message three
# times within 33 seconds - not three hours apart.
#
# ROOT CAUSE, read directly in lib/Tira.pm's job-due rule: the due-check read
# (my $checked = $self->_violation_ledger($args{store})->{job_checked}) runs
# OUTSIDE any lock. The ledger WRITE that records a job as checked/fired is
# wrapped in _with_enforcement_lock - but only the write, not the read that
# decides whether to announce. Two police daemons racing this gap both read
# the same stale $checked, both decide the job is due, and both announce it -
# exactly the shape t/364 already fixed for violation_record's own
# read-modify-write, applied here to the ONE ledger read this project's own
# fix for that card did not reach.
#
# Same proof technique as t/364 ("two watchers, one ledger"): a real flock
# probe on a second handle answers whether the enforcement lock is held,
# without needing to fork a second OS process to race against.
#
# WRITTEN RED.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-09-07T09:00:00Z';
my $tira  = Tira->new( clock => sub { $now } );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );
$tira->project_new(
    name => 'Heard Twice', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'HTS', epic_prefix => 'HTE', ticket_prefix => 'HTT',
);
mkdir File::Spec->catdir( $root, '.git' );
$tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
$tira->job_add( project => $root, schedule => '0 */3 * * *', message => 'due message' );

# Same probe t/53 and t/364 both use: a second lock handle that cannot be
# taken without blocking means somebody already holds the real one.
sub lock_held {
    my ($store_dir) = @_;
    mkdir $store_dir if !-d $store_dir;
    open my $probe, '>>', File::Spec->catfile( $store_dir, '.lock' ) or die $!;
    my $free = flock( $probe, LOCK_EX | LOCK_NB );
    flock( $probe, LOCK_UN ) if $free;
    close $probe;
    return $free ? 0 : 1;
}

# --- the due-check read must happen under the same lock as the write --------
#
# Not every _violation_ledger call in a pass matters here - only the one that
# actually decides whether this due job gets announced. This board declares
# nothing but job-due and carries one job, so the read that feeds job_is_due
# is the first (and, pre-fix, the only) call the pass makes for this store.

my @held_at_each_read;
{
    no warnings 'redefine';
    my $original = \&Tira::_violation_ledger;
    local *Tira::_violation_ledger = sub {
        my ( $self, $s ) = @_;
        push @held_at_each_read, lock_held($s);
        return $original->( $self, $s );
    };
    $tira->police_pass( project => $root, store => $store, world => {} );
}

ok( scalar(@held_at_each_read) >= 1, 'the due-check reads the ledger at least once' )
  or diag('no _violation_ledger call was observed at all');
ok( $held_at_each_read[0],
    'the FIRST read - the one that decides due-ness - happens while the enforcement lock is already held, '
      . 'so a second daemon racing the same window cannot read the same stale state' );

# --- and the fix does not silence a genuinely due job once the window moves -
#
# Advancing past the due minute (0 */3 * * *: due at :00, not :01) into an
# ordinary non-due minute - a plain, unambiguous regression check, unrelated
# to job_is_due's own documented same-minute-two-passes collapse.

$now = '2026-09-07T09:01:00Z';
my $pass = $tira->police_pass( project => $root, store => $store, world => {} );
my @job_due = grep { ( $_->{rule} // '' ) eq 'job-due' } @{ $pass->{violations} };
ok( !@job_due, 'a minute later, off its schedule, the job is quiet - unchanged from before' );

done_testing();

__END__

=head1 NAME

595-a-due-job-heard-twice.t - job-due's due-check read is locked with its write

=head1 DESCRIPTION

TKT-995. C<job-due>'s due-check read used to run outside the
C<_with_enforcement_lock> that protects its own ledger write, so two police
daemons racing that gap - a normal, supported way to run this project, not a
misconfiguration - could both read the same stale C<job_checked> value and
both announce the same due window. Fixed the same way C<violation_record>
was fixed for the identical shape (t/364): the read that decides due-ness now
happens under the same lock as the write that records it.

=cut
