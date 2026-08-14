#!/usr/bin/env perl
# A gate that says the release passed means the release happened.
#
# git push exited 141 - killed by SIGPIPE - after the pre-push hook finished.
# The hook printed "suite passed, coverage is 100% on all three modules,
# documentation agrees, board backed up" and nothing was transferred. Three
# times in a row, each with the gate passing and the remote unchanged.
#
# It hid behind a pipe. Every push was written as "git push ... | tail", and a
# pipeline's status is the last command's - so tail exited zero and reported
# success for a push that had been killed, with the gate's own final line
# reading as confirmation of it.
#
# The first explanation was wrong and is recorded here because it nearly
# shipped: a pre-push hook is handed the refs on standard input and this one
# never reads them, which looked like the answer. Built in a scratch repository,
# a hook that ignores its input pushes perfectly well - verbose, slow, or both.
# The mechanism had been reasoned about rather than run.
#
# GIT_TRACE gave the real one in a single line, arriving while the hook was
# still checking the board:
#
#     Connection to github.com closed by remote host.
#
# git opens the connection before it runs the hook. The gate takes twenty
# minutes. GitHub closes a session that sits idle that long, and git then dies
# writing to a connection that had gone - which is why the failure lands after
# every check has passed and looks like a gate that approved a release.
#
# So the fix is keepalives for as long as the gate takes, set by the installer
# that puts the gate in place, because it belongs to this repository's gate and
# to nothing else on the machine.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira::CLI;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $tmp = tempdir( CLEANUP => 1 );

sub run_quietly {
    my (@command) = @_;
    my $out = File::Spec->catfile( $tmp, 'command.out' );
    my $status = system join ' ', ( map { "'$_'" } @command ), '>', "'$out'", '2>&1';
    return $status;
}

# A bare remote and a working copy, so a push is a real push.
my $remote = File::Spec->catdir( $tmp, 'remote.git' );
my $work   = File::Spec->catdir( $tmp, 'work' );
is( run_quietly( 'git', 'init', '--bare', '-q', $remote ), 0, 'a remote to push to' );
is( run_quietly( 'git', 'init', '-q', $work ), 0, 'and a working copy' );

for my $setting ( [ 'user.email', 'nobody@example.invalid' ], [ 'user.name', 'Nobody' ] ) {
    run_quietly( 'git', '-C', $work, 'config', @{$setting} );
}
run_quietly( 'git', '-C', $work, 'remote', 'add', 'origin', $remote );

open my $fh, '>', File::Spec->catfile( $work, 'a-file' ) or die $!;
print {$fh} "something to push\n";
close $fh;
run_quietly( 'git', '-C', $work, 'add', '-A' );
run_quietly( 'git', '-C', $work, 'commit', '-q', '-m', 'the first commit' );

my $hook = File::Spec->catfile( $work, '.git', 'hooks', 'pre-push' );

sub install_hook {
    my ($body) = @_;
    open my $out, '>', $hook or die $!;
    print {$out} $body;
    close $out;
    chmod 0755, $hook or die $!;
    return;
}

sub push_status {
    my $status = system "git -C '$work' push origin HEAD:refs/heads/probe-$_[0] >/dev/null 2>&1";
    return $status == -1 ? -1 : ( $status & 127 ? 128 + ( $status & 127 ) : $status >> 8 );
}

# --- a hook that ignores its input is not the problem -----------------------------
#
# Kept because it is the answer that looked right. A hook can print twenty
# thousand lines, take its time, and never read a byte of what git sends it, and
# the push still lands. Anybody reaching for this explanation again can see it
# tried and failing here.

install_hook( <<'SH' );
#!/usr/bin/env bash
set -euo pipefail
for i in $(seq 1 2000); do echo "line $i of gate output"; done
sleep 1
exit 0
SH

is( push_status('ignored'), 0,
    'a hook that never reads what git sends it, and talks a great deal, still lets the push land' );

# --- a hook that refuses still refuses -----------------------------------------------
#
# Reading the input must not turn the gate into a formality.

install_hook( <<'SH' );
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
echo "not today" >&2
exit 1
SH

isnt( push_status('refused'), 0, 'and a hook that refuses still stops the push' );

# --- what actually keeps the connection alive ------------------------------------
#
# The gate runs for twenty minutes on a connection git opened before it started.
# Nothing in the suite can hold a real session open for that long, so what is
# checked is that the thing which installs the gate also installs the keepalive
# - the two arrive together or the gate goes back to approving releases that do
# not leave the machine.

{
    open my $installer, '<', File::Spec->catfile(qw(tools install-hooks)) or die $!;
    my $source = do { local $/; <$installer> };
    close $installer;
    like( $source, qr/core\.sshCommand/,
        'installing the gate also configures how git reaches the remote' );
    like( $source, qr/ServerAliveInterval/,
        'with keepalives, so a gate that takes twenty minutes does not outlive the connection' );
    like( $source, qr/closed by remote host/,
        'and says what was measured, so the next person does not reason about it instead' );
}

done_testing;

__END__

=head1 NAME

154-a-gate-that-passed-and-shipped-nothing.t - a gate that passes means the release happened

=head1 DESCRIPTION

C<git push> exited 141 - SIGPIPE - after the pre-push hook finished, so the gate
printed that everything passed and nothing was transferred. It hid behind a
pipe: the pushes were written as C<git push | tail>, and a pipeline's status is
the last command's.

The first explanation - that a pre-push hook must read the refs git sends it -
was wrong, and a scratch repository shows a hook ignoring them pushing fine.
C<GIT_TRACE> gave the real one: "Connection to github.com closed by remote host",
arriving while the hook was still running. git opens the connection before the
hook, the gate takes twenty minutes, and the session does not survive it.

The installer that puts the gate in place now configures keepalives to match, so
the two cannot arrive separately.

=cut
