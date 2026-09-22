#!/usr/bin/env perl
# TKT-1138. Found by Codex review of TKT-1104's own fix. police_release_
# singleton opens the pid file, reads it, closes the handle, checks the
# stored pid against its own, and only THEN calls unlink - three separate
# operations with no lock held across them. A successor's police_claim_
# singleton (a single read-decide-write) can land in the gap between the
# ownership check and the unlink, and the releasing process then deletes
# the successor's live claim instead of its own already-stale one.
#
# Reproduced the same way t/1119/t/1144 already reproduce a race in this
# same family: an injected hook (here, $opts{unlink}) runs exactly where
# the real unlink would, and by the time it runs, a successor has already
# claimed - proving the deletion happens after the successor's write, not
# only asserting the two calls happened in some order.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
require Tira::CLI::Police;

my $tmp   = tempdir( CLEANUP => 1 );
my $store = File::Spec->catdir( $tmp, 'police' );
my $tira  = Tira->new( clock => sub { '2026-09-22T00:00:00Z' } );

# The outgoing process (pid 100) holds the claim.
Tira::CLI::Police::police_claim_singleton( $store, pid => 100, alive => sub { 0 }, kill => sub { } );

my $path = Tira::CLI::Police::police_singleton_path($store);
my $unlinked;

# The successor's claim has to be a REAL second process, not an in-process
# call: once the fix serializes claim/release under a real (flock-based)
# lock, an in-process "successor" calling police_claim_singleton from
# inside the release's own unlink hook would deadlock against itself -
# there is nothing else to drop the lock it is already holding. A forked
# child gives the successor its own process, so its claim call genuinely
# blocks on the same lock until the release below finishes and drops it -
# which is exactly the serialization the fix is supposed to provide.
my $go = File::Spec->catfile( $tmp, 'go' );
my $child = fork();
die "fork failed: $!" unless defined $child;

if ( $child == 0 ) {
    until ( -e $go ) { select( undef, undef, undef, 0.01 ); }
    Tira::CLI::Police::police_claim_singleton(
        $store, pid => 200, alive => sub { 0 }, kill => sub { } );
    exit 0;
}

# The release runs, but signals the successor (the forked child) to make
# its claim attempt right where the real unlink would happen - the exact
# window this ticket is about. The child's claim call blocks on the same
# lock this release call holds until this call returns, so this waits for
# PROOF the child is genuinely blocked on that flock() (its /proc wchan
# names the wait) rather than assuming a fixed sleep was long enough -
# Codex review: a timing guess here could pass even with the race
# unfixed, if the child were simply slow to start.
Tira::CLI::Police::police_release_singleton(
    $store, pid => 100,
    unlink => sub {
        open my $fh, '>', $go or die $!;
        close $fh;
        my $wchan_path = "/proc/$child/wchan";
        for ( 1 .. 500 ) {
            last if !open my $wfh, '<', $wchan_path;
            my $wchan = do { local $/; <$wfh> } // '';
            last if $wchan =~ /lock/i;
            select( undef, undef, undef, 0.01 );
        }
        $unlinked = unlink( $_[0] );
    },
);

waitpid( $child, 0 );

ok( -f $path, 'the successor\'s claim survives - the release must not delete a file it no longer owns' );
open my $fh, '<', $path or die $!;
is( do { local $/; <$fh> }, '200', 'and it still names the successor, pid 200, not nothing' );
close $fh;

# --- releasing against a store that was never created (or already removed)
# stays a safe no-op, as it always was - the new lock's own file must not
# turn "nothing to release" into a die (Codex review).

{
    my $missing_store = File::Spec->catdir( $tmp, 'never-created' );
    my $released = eval {
        Tira::CLI::Police::police_release_singleton( $missing_store, pid => 999 );
        1;
    };
    ok( $released, 'releasing against a store directory that does not exist does not die' );
}

done_testing;

__END__

=head1 NAME

1149-a-release-that-deleted-a-live-claim.t - police_release_singleton does
not delete a successor's claim that arrived mid-release

=head1 DESCRIPTION

TKT-1138. C<police_release_singleton>'s ownership check (read the file,
compare the stored pid) and its C<unlink> are two separate operations
with nothing serializing them against a concurrent C<police_claim_
singleton> on the same path. Reproduced via the injectable C<unlink> hook,
made to claim on behalf of a successor process at exactly the point the
real unlink would run - proving the deletion still went ahead against a
file the successor had, by then, already made its own.

=cut
