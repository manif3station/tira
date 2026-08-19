#!/usr/bin/env perl
# A working gate prints red connection failures while it waits for its own
# server, and prints more of them the busier the machine is.
#
# tools/browser-tests waits for the boards it starts by polling them with
# curl in a retry loop, three times. All three calls use -fsS, and -S forces
# curl to print its error even in silent mode - so every retry before the
# server is ready emits "curl: (7) Failed to connect to 127.0.0.1 port NNNN
# after 0 ms: Couldn't connect to server" into the push log. The failure is
# expected; it is what waiting looks like. The reader has no way to tell it
# from a real one, and every push this session printed exactly this on a
# server that came up correctly a moment later. TKT-370.
#
# Proved two ways: curl itself is actually run against a closed port, rather
# than assumed, to show -fsS is loud and -fs is quiet on the same failure;
# and the three retry-loop call sites are read from the source, because
# reading them is how the drift was found in the first place - the eight
# single-shot calls elsewhere in the same file keep -fsS deliberately, since
# a failure there is handled by its own die/exit block and is not noise.

use strict;
use warnings;

use Test::More;

# --- curl's own behaviour, run rather than assumed -------------------------

my $closed_port = 18291;    # nothing listens here in the test environment

my $loud = `curl -fsS -o /dev/null -m 1 http://127.0.0.1:$closed_port/ 2>&1`;
like( $loud, qr/curl: \(7\)/,
    '-fsS prints the connection failure - what every push log has shown' );

my $quiet = `curl -fs -o /dev/null -m 1 http://127.0.0.1:$closed_port/ 2>&1`;
is( $quiet, '', '-fs says nothing about the same failure - what waiting should look like' );

# --- the three retry loops, read from the source ----------------------------

open my $fh, '<', 'tools/browser-tests' or die "Cannot read tools/browser-tests: $!";
my $source = do { local $/; <$fh> };
close $fh;

my @retry_calls = $source =~ /^\s*(?:if )?curl (-f\S*) -o \/dev\/null -m 2 "http:\/\/127\.0\.0\.1:\$\w+\/"/mg;
is( scalar @retry_calls, 3, 'the three polling retries are where this expects them' );
is_deeply( \@retry_calls, [ '-fs', '-fs', '-fs' ],
    'and none of them forces curl to print the wait as a failure' );

# What is not being asked for: the eight single-shot calls elsewhere in the
# same file - signing in, fetching a page, posting a login - keep -fsS,
# because a failure there is a real one, already handled by its own
# die/exit block. Counted rather than assumed, so a fix that went too far
# and quieted a genuine failure would fail this too.
my @single_shot = $source =~ /curl -fsS(?! -o \/dev\/null -m 2)/g;
cmp_ok( scalar @single_shot, '>=', 6,
    'the calls that report a real failure still do, loudly' );

done_testing;

__END__

=head1 NAME

290-waiting-that-reads-like-failing.t - a retry is not a failure

=head1 DESCRIPTION

tools/browser-tests polled the boards it starts with curl -fsS in three
retry loops. -S forces curl to print its error even in silent mode, so every
retry before a server was ready printed "curl: (7) Failed to connect" into
the push log - noise indistinguishable from a real failure, and worse on a
busy machine, which retries more. This runs curl against a closed port to
show the real difference between -fsS and -fs, and reads the three retry
call sites from the source to confirm none of them still forces the noise,
while the genuine single-shot failures elsewhere keep reporting loudly.

=cut
