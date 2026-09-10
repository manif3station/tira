#!/usr/bin/env perl
# A job card's log panel seeded from the server's own tail (job.recent)
# exactly once, then never looked at it again - so a monitor's panel
# froze on whatever it first showed, while the card's own header kept
# saying "Last ran N minutes ago".
#
# TKT-1030. His report, with a screenshot: JOB-004's panel repeated an
# old failure while the header said the job had run 5 minutes ago. The
# original guard - "ONLY WHEN NOTHING IS REMEMBERED" (TKT-922) - was
# right to stop a blind reseed on every poll (duplicate lines, freshness
# reset), but it went the whole other way: a card rebuilt every poll
# never re-consulted job.recent past its very first paint, however far
# the server's own tail had moved on since.
#
# Source-read, the way t/500/t/508/t/510/t/517/t/528/t/530/t/1018/t/1020
# all read this view file: this suite drives no browser and browser
# tests are his.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();

my $editor = Suite::view_source('jobs-editor.js');
ok( length $editor, 'the jobs editor was read' );

# --- the bug: seeded once, never re-synced ----------------------------------

unlike( $editor, qr/if\s*\(\s*!runLogs\.has\(\s*job\.id\s*\)\s*&&/,
    'the old once-only guard is gone - it silenced every update after the first paint' )
  or diag('the bug this card is about: job.recent is consulted once and never again');

# --- the fix: a per-job record of what has already been folded in ----------

like( $editor, qr/seenRecent/,
    'a per-job record of the server tail already folded into runLogs exists' );

like( $editor, qr/seenRecent\.set\(\s*job\.id/,
    'and it is updated on every poll, not only the first one' );

# --- only the NEW tail is appended, not the whole array again --------------
#
# The original guard's own worry, still true and still worth holding: a
# blind reseed of the whole array every poll would push the same lines
# back in for ever and reset their freshness.
#
# OVERLAP, NOT A SINGLE LAST-LINE SENTINEL - Codex review caught a first
# version that matched only the previous tail's own last line, which a
# repeated line anywhere in the new tail could satisfy early and silently
# drop everything genuinely new after it.

unlike( $editor, qr/\.lastIndexOf\(/,
    'no single-line-sentinel matching - a repeated line elsewhere in the tail would satisfy it early and drop real new lines after it' );

like( $editor, qr/for\s*\(\s*let\s+k\s*=\s*maxK/,
    'the fix finds the largest shared overlap between the old and new tails, not a single matched line' );

# --- and the existing clear button (TKT-1020) is untouched ------------------

like( $editor, qr/jobs-card__log-clear/, 'the per-card clear button (TKT-1020) is still there' );
like( $editor, qr/runLogs\.delete\(\s*job\.id\s*\)/, 'and still clears only that job\'s own entry' );

done_testing();

__END__

=head1 NAME

1030-a-panel-that-stopped-looking.t - a job card's log panel keeps
looking at the server's own tail, not just once

=head1 WHY

TKT-1030. A monitor job's log panel was seeded from job.recent exactly
once (TKT-922's own fix for a panel that showed nothing at all), then
never looked at it again - a card rebuilt on every poll kept repainting
whatever it first saw, however far the server's own tail moved on since.

=head1 WHAT IS ASSERTED

That the old once-only seeding guard is gone, replaced by a per-job
record (seenRecent) of what has already been folded in, updated on
every poll; that only the new part of a moved-on tail is appended,
found via the largest shared overlap between the old and new tails
rather than a single-line sentinel (a first lastIndexOf-based draft
was Codex-caught as broken for a repeated line anywhere in the tail);
and that the existing clear button (TKT-1020) is unaffected.

=cut
