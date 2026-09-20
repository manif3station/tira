#!/usr/bin/env perl
# TKT-1073. tools/gate-run's cleanup() removed a scratch worktree with
# 'git worktree remove --force "$tree" >/dev/null 2>&1 || true' - the same
# permission bug tools/dev-run's own cleanup() hit and was fixed for
# (TKT-579): a coverage run writes cover_db as root inside the container,
# and a root-owned or restrictively-permissioned subdirectory under it
# cannot be deleted by the plain user gate-run runs as. Because the whole
# call is wrapped in "|| true", the failure was completely silent - the
# worktree survived, gate-run reported success regardless, and the leftover
# accumulated on every affected run.
#
# Reproduced live before writing this test: created a real linked worktree,
# chmod 000 a root-owned subdirectory inside it via a container, then ran
# the exact pre-fix command - it failed exactly as described, leaving the
# directory behind. The fix (a disposable-container wipe before the retry,
# the same pattern tools/dev-run already uses) was then proven to remove it
# completely, and the unaffected/no-root-owned-file case was proven to
# still take git's own clean removal path unchanged.
#
# This checks tools/gate-run's structure the same way t/288/t/1073 (dev-run)
# already check their own tool's text rather than nesting Docker-in-Docker
# inside the perl-test container this suite already runs in - the live
# reproduction above is the tool's real proof, recorded on the card.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

ok( -e 'tools/gate-run', 'tools/gate-run exists' );

open my $fh, '<', 'tools/gate-run' or die "Cannot read tools/gate-run: $!";
my $text = do { local $/; <$fh> };
close $fh;
ok( $text, 'tools/gate-run was read - not empty, not truncated' );

my ($cleanup_body) = $text =~ /cleanup\(\)\s*\{(.*?)\n\}/s;
ok( defined $cleanup_body, 'cleanup() is where this test expects it' );

# --- the fix: a disposable container clears anything root-owned first ------

like( $cleanup_body, qr/docker run --rm -v "\$tree:\/workspace" ubuntu rm -rf \/workspace/,
    'cleanup() clears the tree with a disposable container before relying on a plain removal' );

# --- and it still tries git's own removal, rather than replacing it --------

like( $cleanup_body, qr/git worktree remove --force "\$tree"/,
    "cleanup() still uses git's own worktree removal" );

# --- the disposable-container wipe happens only as a fallback, not always --
#
# Always wiping first would mean the common, unaffected case (no root-owned
# file at all) pays for a container launch on every single run instead of
# never. The wipe belongs behind the same guard that already caught the
# failure - an "if ! git worktree remove" branch - not run unconditionally
# ahead of it.

like( $cleanup_body, qr/if\s*!\s*git worktree remove --force "\$tree"/,
    "the disposable-container wipe only runs when git's own removal already failed" );

# --- and a stale worktree registration left behind is pruned afterward -----

like( $cleanup_body, qr/git worktree prune/,
    'cleanup() prunes the worktree registration git\'s own removal never got to make' );

done_testing;

__END__

=head1 NAME

t/1073-a-worktree-nobody-could-remove.t - tools/gate-run's cleanup() clears
a root-owned leftover before removing its scratch worktree

=head1 DESCRIPTION

TKT-1073. C<tools/gate-run>'s C<cleanup()> called
C<git worktree remove --force "$tree" E<gt>/dev/null 2E<gt>&1 || true>, which
can silently fail to delete a root-owned or restrictively-permissioned
subdirectory left by an instrumented coverage run - the identical bug
C<tools/dev-run>'s own cleanup hit and was fixed for (TKT-579). Reproduced
live: a real linked worktree with a C<chmod 000> root-owned subdirectory
inside it failed to be removed by the pre-fix command, and the tree
survived. C<cleanup()> now tries git's own removal first, and only when
that fails does it clear the tree with a disposable container (the same
pattern C<tools/dev-run> already uses - never C<sudo> on the host) before a
final plain removal and a C<git worktree prune> to clean the stale
registration git's own removal never got to make.

=cut
