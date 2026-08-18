#!/usr/bin/env perl
# The pre-push browser gate leaked a dashboard server on every run - not
# rarely, not only when interrupted, but structurally, every time - because
# the PID it captured to kill was never the server's.
#
# tools/browser-tests starts each dashboard server through a shell FUNCTION:
#
#     tira() { perl -I"$root/lib" "$script" "$@" }
#     tira dashboard -o "browser=127.0.0.1:$port" & serving=$!
#
# $! after backgrounding a function call is the PID of the subshell running
# the FUNCTION BODY, not the perl process the function forks inside it - perl
# is a CHILD of that subshell, not the thing $! names. cleanup() then ran
# `kill "$serving"; wait "$serving"`, which kills the subshell correctly and
# never sends the perl/Starman process a signal at all: it is simply
# orphaned, reparented to init, and keeps listening on the port.
#
# Measured on the real leak: 34 starman masters accumulated, all with cwd
# this project, holding every port from 7841 to 7941 - three servers started
# per run (serving, browsing, prioritising) against a 101-port range is
# almost exactly 34 runs, which fits "every run leaks all three" far better
# than "some runs, when interrupted, leak one".

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

sub is_running {
    my ($pid) = @_;
    return kill( 0, $pid ) ? 1 : 0;
}

my $tmp = tempdir( CLEANUP => 1 );

my $child_script = File::Spec->catfile( $tmp, 'child.pl' );
open my $fh, '>', $child_script or die $!;
print {$fh} <<'PERL';
open my $out, '>', $ARGV[0] or die $!;
print {$out} $$;
close $out;
sleep 30;
PERL
close $fh;

# --- the pattern the gate used to use: a function call backgrounded --------
#
# Reproduced exactly, not paraphrased: a shell function wrapping the launch,
# backgrounded, killed and waited on by the PID $! gave for the function
# call - the same three lines browser-tests ran before this fix.

{
    my $pidfile = File::Spec->catfile( $tmp, 'old.pid' );
    unlink $pidfile;

    my $script = <<"SH";
launch() { perl '$child_script' '$pidfile'; }
launch &
launched=\$!
sleep 1
kill "\$launched" 2>/dev/null
wait "\$launched" 2>/dev/null
SH
    system( 'bash', '-c', $script );

    my $child_pid;
    for ( 1 .. 20 ) {
        last if -s $pidfile;
        select( undef, undef, undef, 0.1 );
    }
    $child_pid = slurp($pidfile) if -s $pidfile;

    ok( defined $child_pid && $child_pid =~ /^\d+\z/,
        'the old pattern still starts a real child process to measure' );
    ok( is_running($child_pid),
        'and killing the PID $! gave for the FUNCTION does not reach it - it survives, orphaned. This is the leak.' );
    kill( 'KILL', $child_pid ) if is_running($child_pid);
}

# --- the fix: bypass the function wrapper for anything backgrounded --------
#
# The same launch, invoking perl directly rather than through the tira()
# function, so $! names the actual process being started.

{
    my $pidfile = File::Spec->catfile( $tmp, 'new.pid' );
    unlink $pidfile;

    my $script = <<"SH";
perl '$child_script' '$pidfile' &
launched=\$!
sleep 1
kill "\$launched" 2>/dev/null
wait "\$launched" 2>/dev/null
SH
    system( 'bash', '-c', $script );

    my $child_pid;
    for ( 1 .. 20 ) {
        last if -s $pidfile;
        select( undef, undef, undef, 0.1 );
    }
    $child_pid = slurp($pidfile) if -s $pidfile;

    ok( defined $child_pid && $child_pid =~ /^\d+\z/, 'the fixed pattern also starts a real process to measure' );
    ok( !is_running($child_pid),
        'and killing the PID $! gave THIS time reaches it directly - no survivor, no leak' );
}

# --- and the real script ships the fixed pattern, not the old one ----------
#
# Not line by line: the real invocations continue onto a second line with a
# trailing backslash, so "dashboard" and the "&" that backgrounds it are
# never on the same line. Splitting on newlines and grepping for a line
# ending in "&" containing "dashboard" is exactly the check that finds
# nothing here and passes vacuously - written that way once already, caught
# by noticing it passed a moment before the fix existed to make it pass.

my $source = slurp('tools/browser-tests');
like( $source, qr/\A#!\/usr\/bin\/env bash/,
    'the real script was read - establishing $source before the denial below is about it' );

# Every backgrounded launch in the real file, found by the marker every one
# of them carries rather than assumed to be exactly three.
my $count = () = $source =~ /^\w+=\$!\s*$/mg;
cmp_ok( $count, '>=', 3, 'the file backgrounds at least the three servers this fix is about' );

# The exact shape that leaks: this function call, given the -o "browser=..."
# argument that makes it a long-running server rather than a one-shot render,
# is what must not be launched through the tira() wrapper. Other calls to
# "tira dashboard" without that argument are one-shot table renders, never
# backgrounded, and are not this bug - so they are deliberately not matched.
unlike( $source, qr/\btira\s+dashboard\s+-o\s+"browser=/,
    'no server launch goes through the tira() function wrapper' )
  or diag('This is the exact pattern that leaks: $! would name the wrapper subshell, not the server.');

done_testing;

__END__

=head1 NAME

282-a-subshell-dies-and-its-child-does-not.t - TKT-397

=head1 DESCRIPTION

C<tools/browser-tests> started each dashboard server through a shell function,
backgrounded, and captured C<$!> as "the server's PID" to kill during cleanup.
C<$!> after backgrounding a function call names the subshell running the
function body, not the C<perl> process it forks inside itself - killing that
PID never reaches the actual server, which survives as an orphan holding its
port. Measured on the real board: 34 leaked Starman masters, roughly matching
three servers leaked per run across the whole port range. The fix launches
C<perl> directly for anything backgrounded, so C<$!> names the real process.

=cut
