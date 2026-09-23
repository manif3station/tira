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

ok( -e '.developer-dashboard/skills/gate/cli/run', 'tools/gate-run exists' );

open my $fh, '<', '.developer-dashboard/skills/gate/cli/run' or die "Cannot read tools/gate-run: $!";
my $text = do { local $/; <$fh> };
close $fh;
ok( $text, 'tools/gate-run was read - not empty, not truncated' );

my ($cleanup_body) = $text =~ /cleanup\(\)\s*\{(.*?)\n\}/s;
ok( defined $cleanup_body, 'cleanup() is where this test expects it' );

# --- the fix: a disposable container clears anything root-owned first ------
#
# Since TKT-1148, $tree is a local git CLONE, not a linked worktree - a
# linked worktree's .git file holds an absolute HOST path back to the
# shared object store, unreachable once gate-run's own container mounts
# the checkout at a different path than it lives at on the host (confirmed
# live: any test needing git to work from inside that checkout, t/1015's
# own "git clone" step, failed with "fatal: not a git repository"). A
# clone is genuinely self-contained - its own .git directory, no external
# reference - so "git worktree remove"/"prune" bookkeeping no longer
# applies; a plain rm is both correct and sufficient.

like( $cleanup_body, qr/if\s*!\s*rm -rf "\$tree"/,
    'cleanup() tries a plain removal first' );

like( $cleanup_body, qr/docker run --rm -v "\$tree:\/workspace" ubuntu rm -rf \/workspace/,
    'cleanup() clears the tree with a disposable container when the plain removal fails' );

# --- no worktree-specific bookkeeping remains - $tree is a clone now -------

unlike( $cleanup_body, qr/git worktree remove/,
    'cleanup() no longer calls git worktree remove - $tree is a clone, not a linked worktree (TKT-1148)' );
unlike( $cleanup_body, qr/git worktree prune/,
    'cleanup() no longer calls git worktree prune - nothing was ever registered against the main repo' );

done_testing;

__END__

=head1 NAME

t/1073-a-worktree-nobody-could-remove.t - tools/gate-run's cleanup() clears
a root-owned leftover before removing its scratch checkout

=head1 DESCRIPTION

TKT-1073. C<tools/gate-run>'s C<cleanup()> called
C<git worktree remove --force "$tree" E<gt>/dev/null 2E<gt>&1 || true>, which
can silently fail to delete a root-owned or restrictively-permissioned
subdirectory left by an instrumented coverage run - the identical bug
C<tools/dev-run>'s own cleanup hit and was fixed for (TKT-579). Reproduced
live: a real linked worktree with a C<chmod 000> root-owned subdirectory
inside it failed to be removed by the pre-fix command, and the tree
survived. C<cleanup()> now tries a plain removal first, and only when that
fails does it clear the tree with a disposable container (the same pattern
C<tools/dev-run> already uses - never C<sudo> on the host) before a final
plain removal.

Since 5.189 (TKT-1148), C<$tree> is a local git clone, not a linked
worktree - a linked worktree's C<.git> file holds an absolute host path
back to the shared object store, which gate-run's own container cannot
resolve once the checkout is mounted at a different path than it lives at
on the host. A clone is genuinely self-contained, so the git-worktree-
specific removal/prune calls this test originally proved are no longer
present or needed.

=cut
