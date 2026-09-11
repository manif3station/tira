#!/usr/bin/env perl
# TKT-579. tools/gate-run exists and is right for what it does: it tests
# HEAD on a clean tree and records a pass the push hook can trust. But the
# commonest action in this project - running the suite against the WORKING
# tree, with uncommitted changes, to watch a red test turn green - has no
# runner. Every time it was a hand-typed Docker incantation, and the parts
# that are easy to drop (most of all --installdeps) fail silently rather
# than loudly: a missing dependency aborts test files at compile time, which
# reads exactly like a broken test or a catastrophic regression, not like a
# harness problem.
#
# This checks tools/dev-run's structure and documented behavior rather than
# actually running it (which would mean Docker-in-Docker inside the very
# perl-test container this suite already runs in) - the same shape t/288
# already uses for tools/gate-run. The tool's real proof is a live run from
# the host, recorded on the card, the same way tools/gate-run itself has no
# test that runs a nested suite either.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

ok( -e 'tools/dev-run', 'tools/dev-run exists' );
ok( -x 'tools/dev-run', 'and is executable' );

open my $fh, '<', 'tools/dev-run' or die "Cannot read tools/dev-run: $!";
my $text = do { local $/; <$fh> };
close $fh;
ok( $text, 'tools/dev-run was read - not empty, not truncated' );

# --- it installs dependencies and reports a failure as itself --------------

like( $text, qr/installdeps/, 'installs dependencies' );
like( $text, qr/dependency installation failed/i,
    'and names a dependency-install failure as itself, not as a test result' );

# --- it copies the tree rather than mounting the live working directory ----

like( $text, qr/cp -a/, 'copies the tree into a scratch directory' );
unlike( $text, qr/-v\s+"\$root/, 'and does not mount the live working directory read-write' );

# --- the two bugs found live while proving this tool stay fixed ------------
#
# Found running tools/dev-run for real, not by inspection: removing the
# scratch tree before the container mounted on it had stopped raced the
# container, and cover_db (written by root inside the container) could not
# be removed by a plain host-side rm -rf afterwards. Both are ordering/
# permission bugs a passing suite run cannot exercise by accident, so they
# are pinned here directly against the script's own text.

my ($cleanup_body) = $text =~ /cleanup\(\)\s*\{(.*?)\n\}/s;
ok( defined $cleanup_body, 'cleanup() is where this test expects it' );

my $stop_index   = index( $cleanup_body, 'docker rm -f "$container_name"' );
my $remove_index = index( $cleanup_body, 'rm -rf "$tree"' );
cmp_ok( $stop_index, '>=', 0, 'cleanup() stops the container' );
cmp_ok( $remove_index, '>=', 0, 'cleanup() removes the scratch tree' );
cmp_ok( $stop_index, '<', $remove_index,
    'and stops the container BEFORE removing the tree it was mounted on - the ordering bug found live' );

like( $cleanup_body, qr/docker run --rm .*rm -rf \/workspace/,
    'and clears root-owned cover_db with a disposable container, not a plain host rm - the permission bug found live' );

# --- it accepts an optional file list -------------------------------------

like( $text, qr/TEST_FILE/, 'documents an optional test-file argument' );
like( $text, qr/\bfiles\+=/, 'and collects the file list into an array' );

# --- it offers the coverage form, selecting the modules to measure ---------

like( $text, qr/--coverage/, 'documents a --coverage flag' );
like( $text, qr/coverage_modules/, 'and threads it through to module selection' );
like( $text, qr/-select/, 'passed to cover -select, the same flag tools/gate-run uses' );

# --- tools/gate-run and the push hook are untouched -------------------------

ok( -e 'tools/gate-run', 'tools/gate-run still exists' );
like( $text, qr/gate-run/, 'dev-run\'s own header names gate-run as the tool it sits beside, not replaces' );

# --- README.md points at it -------------------------------------------------

open my $readme, '<', 'README.md' or die "Cannot read README.md: $!";
my $readme_text = do { local $/; <$readme> };
close $readme;
like( $readme_text, qr/tools\/dev-run/,
    'README.md names the working-tree runner alongside the raw command it documents' );

done_testing;

__END__

=head1 NAME

t/1073-an-incantation-retyped-by-hand.t - tools/dev-run exists, installs
dependencies, copies the tree, and offers file/coverage selection

=head1 DESCRIPTION

TKT-579. C<tools/gate-run> tests HEAD on a clean tree for the push hook.
The working-tree case - watching a red test turn green, with uncommitted
changes - had no runner, so the Docker incantation was hand-typed every
time, and the parts that are easy to drop (most of all C<--installdeps>)
failed silently. C<tools/dev-run> installs dependencies (naming a failure
there as itself), copies the tree into a scratch directory rather than
mounting the live one, and accepts an optional file list and C<--coverage>
selection.

=cut
