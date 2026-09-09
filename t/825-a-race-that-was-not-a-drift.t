#!/usr/bin/env perl
# TKT-825. A real gate-run measured lib/Tira.pm at 99.7/99.9/99.7 on one
# pass, despite TKT-954's own tools/coverage-complete (which checks the
# per-process run COUNT against the number of test files) already being in
# place and passing. The fault survives that check, so it is not a fully
# missing run - it is a run directory that is PRESENT but wrong.
#
# ROOT CAUSE, found reading Devel::Cover 1.52's own source rather than
# guessed at: lib/Devel/Cover.pm:788 names each per-process run directory
# `time . "." . $$ . "." . sprintf "%05d", rand 2**16` - one-second
# resolution, no collision check, no retry. Under prove -jN spawning
# hundreds of short-lived worker processes, a PID reused within the same
# wall-clock second can collide with another process's run directory name,
# silently clobbering its coverage data while leaving the SLOT present -
# which is exactly what coverage-complete's own count-based check cannot
# see. This is an upstream Devel::Cover design gap, not a fault in this
# project's own code, so there is no fix available at that layer.
#
# Michael's decision (Q-149, live): do the deep investigation regardless of
# time cost. Two reproduction attempts (80 files x 15 iterations = 1200
# file-slots under -j4; a full 641-file suite x 3 instrumented runs) did not
# themselves reproduce a shortfall within this session's budget - consistent
# with a rare event, not proof the fault does not exist, given the
# discrepancy already measured live on 2026-09-01 (see tools/coverage-
# complete's own header for that measurement). The actionable, testable
# outcome from his own stated fallback: the suite's coverage collection is
# now retried once before the gate refuses, the same way a flaky network
# read gets a second attempt rather than trusting the first collection
# unconditionally.
#
# WHY A SOURCE CHECK, NOT AN END-TO-END DRIVE. tools/gate-run has no test
# harness of its own - TKT-716, still open, noted by t/572 for the same
# reason - and driving this specific retry live would mean provoking the
# actual Devel::Cover race on demand, which is exactly the rare event this
# investigation could not reproduce on a schedule. This pins the retry
# mechanism's presence and shape structurally instead.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

my $source = do {
    local $/;
    open my $fh, '<', 'tools/gate-run' or die "cannot read tools/gate-run: $!";
    <$fh>;
};
ok( length $source, 'tools/gate-run was read' );

like( $source, qr/attempt=1/, 'gate-run tracks a retry attempt counter' );
like( $source, qr/attempt.*-le.*2/,
    'and caps it at two attempts - one retry, not an unbounded loop that could mask a genuinely broken tree' );
like( $source, qr/coverage-complete/,
    'the retry decision is driven by the existing, already-tested tools/coverage-complete, not a new ad-hoc check' );
like( $source, qr/A genuine test failure is not the race this retry exists for/,
    'and a genuine suite failure breaks out of the retry immediately, rather than spending a second full suite run on a tree that is actually broken' );

# Codex review caught a real gap in the first draft: gating the retry on
# coverage-complete alone would never fire for the actual reported failure
# (a run directory present but wrong, which coverage-complete's own count
# check cannot see) - only the coverage PERCENTAGE catches that. The retry
# must cover the percentage check too, not only the run count.
like( $source, qr/report_status/,
    'the retry also tracks whether the reported coverage percentage itself was short, not only whether the run count was complete' );
like( $source, qr/100\.0.*100\.0.*100\.0/,
    'and it actually looks at the 100.0/100.0/100.0 shape the percentage report prints, the same shape the host-side final check looks for' );

done_testing();

__END__

=head1 NAME

t/825-a-race-that-was-not-a-drift.t - gate-run retries a flaky coverage
collection instead of trusting the first pass unconditionally

=head1 DESCRIPTION

TKT-825. A real coverage figure was measured wrong (99.7% instead of
100.0%) despite TKT-954's own run-count completeness check passing -
traced to Devel::Cover 1.52's own per-process run-directory naming
scheme (C<lib/Devel/Cover.pm:788>), which has no collision guard under
C<prove -jN>'s many short-lived worker processes. Since the fault is in a
third-party module with no fix available at this project's own layer,
C<tools/gate-run> now retries the whole instrumented suite once before
refusing on an incomplete coverage collection.

=cut
