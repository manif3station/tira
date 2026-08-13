#!/usr/bin/env perl
# The bridge redirected to a file writes while it is still running.
#
# zen-framework ran it the way anything meant to be left running gets run -
# "d2 tira.policy.bridge >> log 2>&1" - and measured ZERO BYTES IN SIXTY-EIGHT
# MINUTES while violations were being raised and escalating to critical. Under a
# pty the same command replayed the whole outstanding backlog at once. The
# output was never missing; it was sitting in a block buffer, because Perl
# buffers standard output whenever it is not a terminal and nothing here set
# autoflush.
#
# The bridge is the agent's only channel for violations, and the policy
# documentation says a policy set without the bridge running is worse than no
# policy at all, because it looks like cover. That sentence came true through a
# buffer: twenty-one policies declared, the owner told the board was covered,
# and the channel writing into four kilobytes nobody would ever read.
#
# A channel silent because it is broken is indistinguishable from one silent
# because the board is clean, and the flattering reading is the one that gets
# believed. This project has named that shape a dozen times in its own checks.
# Here it was in the channel those checks report through.
#
# It survived every existing test for one reason: the tests read the log file
# police writes, and a process flushes what it has buffered when it exits. Only
# a bridge that is still running can show it, so this one watches the file with
# the child alive.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T23:30:00Z'} );
my $store = File::Spec->catdir( $tmp, 'police' );

# Something for it to say, well under the four kilobytes a block buffer holds -
# which is the whole point. A backlog big enough to fill the buffer would flush
# by accident and prove nothing.
$tira->bridge_write(
    store      => $store,
    violations => [
        {   id   => 'VIO-0001', rule => 'card-stalled', ref => 'TKT-005',
            detail => 'every checklist item is done but the card is still in implement',
            action => 'bridge-reminder', tone => 'note', seen => 1,
        }
    ],
);

my $out = File::Spec->catfile( $tmp, 'bridge.log' );
my $entrypoint = File::Spec->catfile(qw(skills policy cli bridge));

# A real child with its output redirected to a file, exactly as somebody would
# run it detached. Long enough to still be alive when the file is read, and it
# is killed rather than waited for, because a clean exit would flush the buffer
# and hide the fault this is here to catch.
my $pid = fork;
die "cannot fork: $!" if !defined $pid;
if ( !$pid ) {
    open STDOUT, '>', $out or die $!;
    open STDERR, '>', File::Spec->devnull or die $!;
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    exec $^X, '-Ilib', $entrypoint, '--store', $store,
      '--rounds', 60, '--interval', 1;
    die "cannot exec: $!";
}

# Give it up to fifteen seconds to say something. Buffered, it says nothing for
# any of them; line-buffered, the first line is there within one.
my $said = '';
for ( 1 .. 15 ) {
    sleep 1;
    if ( open my $fh, '<', $out ) { local $/; $said = <$fh> // ''; close $fh }
    last if $said ne '';
}

my $still_running = kill 0, $pid;
kill 'KILL', $pid;
waitpid $pid, 0;

ok( $still_running, 'the bridge was still running when its output was read' );
isnt( $said, '', 'a bridge redirected to a file has written to it while running' );
like( $said, qr/VIO-0001/, 'and what it wrote is the violation, not a fragment' );

done_testing;

__END__

=head1 NAME

142-the-bridge-reaches-a-file.t - the bridge redirected to a file writes while running

=head1 DESCRIPTION

C<tira.policy.bridge> printed to a standard output nobody had set autoflush on,
so Perl block-buffered it whenever it was not a terminal. Redirected to a file -
the natural way to run something meant to be left going - it wrote nothing for
sixty-eight measured minutes while violations escalated to critical.

The bridge is the agent's only channel for violations, so a bridge silent
because it is buffered looks exactly like a board that is clean. Every existing
test missed it because they read police's own log file, and because a process
flushes on exit; this one reads the file with the child still alive, and kills
the child rather than letting it exit for the same reason.

=cut
