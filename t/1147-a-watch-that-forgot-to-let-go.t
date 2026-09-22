#!/usr/bin/env perl
# TKT-1104, found by the 2-hourly improvement hunt (TKT-521) while reading
# bridge_follow/police_follow's own singleton mechanism during TKT-1100.
#
# police_follow/bridge_follow's SIGNAL handlers release their singleton
# claim before leaving (police_release_singleton) - but a call bounded by
# a finite --rounds that reaches the end of its loop normally returns
# straight out with no release at all. The claim - a pid file at
# police_singleton_path($store, $kind) - is left on disk naming a process
# that has already returned, so the next ordinary d2 tira.police/
# tira.policy.bridge call reads a stale claim and has to fall back to its
# own alive-check/kill-previous path instead of finding a clean slate.
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

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-21T00:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new( name => 'Releases', dir => $root, members => ['claude'] );
my $store = File::Spec->catdir( $tmp, 'police' );

# --- police_follow -----------------------------------------------------

{
    my $pid_path = Tira::CLI::Police::police_singleton_path($store);
    Tira::CLI::Police::police_follow(
        $tira, { project => $root }, $store,
        { rounds => 2, sleeper => sub { }, singleton => { pid => $$ } },
    );
    ok( !-e $pid_path,
        'police_follow releases its singleton claim on a normal finite-rounds exit, '
          . 'not only on a signal - the pid file the claim wrote is gone' );
}

# --- bridge_follow -------------------------------------------------------

{
    my $pid_path = Tira::CLI::Police::police_singleton_path( $store, 'policy-bridge' );
    Tira::CLI::Police::bridge_follow(
        $tira, $store,
        rounds => 2, sleeper => sub { }, singleton => { pid => $$ },
    );
    ok( !-e $pid_path,
        'bridge_follow releases its singleton claim on a normal finite-rounds exit too' );
}

# --- the claim is genuinely gone, not merely never written ---------------
#
# Proves the assertions above are not vacuously true because nothing ever
# claimed in the first place - the claim exists mid-loop, and is gone only
# after the loop actually finishes.

{
    my $pid_path = Tira::CLI::Police::police_singleton_path($store);
    my $seen_mid_loop;
    Tira::CLI::Police::police_follow(
        $tira, { project => $root }, $store,
        {   rounds => 1, singleton => { pid => $$ },
            sleeper => sub { $seen_mid_loop = -e $pid_path ? 1 : 0 },
        },
    );
    ok( $seen_mid_loop, 'the claim really was written and present during the round' );
    ok( !-e $pid_path, 'and is released once the round completed' );
}

done_testing;

__END__

=head1 NAME

1147-a-watch-that-forgot-to-let-go.t - police_follow/bridge_follow release
their singleton claim on a normal finite-rounds exit

=head1 DESCRIPTION

TKT-1104. Both watch loops released their singleton claim (a pid file at
C<police_singleton_path>) from their C<SIGINT>/C<SIGTERM>/C<SIGHUP>
handlers only - a call bounded by a finite C<--rounds> that completed its
loop normally returned with the claim still on disk, naming a process
that had already exited. Both now call C<police_release_singleton> on
that exit path too, sharing the same ownership-aware release the signal
handlers already used.

=cut
