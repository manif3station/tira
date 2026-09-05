#!/usr/bin/env perl
# TKT-857. tools/gate-run runs the instrumented suite with no host-wide
# exclusion. Two suite runs against the shared skill directory (the manual
# verify-step invocation documented in this workspace's own CLAUDE.md, or a
# second gate-run started before the first finished) share the coverage
# database's on-disk state, and concurrent Devel::Cover writers clobber it
# rather than either run failing loudly - measured on 2026-08-29, when this
# produced a false 70.3% for a module that was actually at 100%.
#
# developer-dashboard's own script/coverage-gate and .claude/tools/run-suite
# already agree on a convention for exactly this host-wide exclusion: a flock
# at a path named by $DD_SUITE_LOCK, defaulting to /tmp/dd-gate-host.lock. This
# card's own key_detail names that path directly and asks to check what else
# takes it before changing behaviour - joining it, not inventing a second one,
# is what makes gate-run and a DD-run suite refuse to trample each other too.
#
# WHERE THIS DIFFERS FROM DD ON PURPOSE: DD's own tools take the lock
# non-blocking and REFUSE immediately, reasoning that a waiter would start the
# instant the lock freed with no fresh look at the host. That reasoning is
# about an interactive session where a person notices the refusal and decides
# whether to retry. This project's suite runs are driven by an unattended
# agent with no one to notice a refusal and retry it, and the card's own title
# says "queue instead of voiding" - so gate-run blocks instead, which is the
# opposite polarity for a documented, deliberate reason rather than an
# oversight of the DD precedent.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

my $gate_run = do {
    local $/;
    open my $fh, '<', 'tools/gate-run' or die "tools/gate-run: $!";
    <$fh>;
};

# non-empty is the whole claim: an unreadable file would pass every denial
# below on emptiness alone, which is the exact fault t/147 exists to catch.
like( $gate_run, qr/\S/, 'tools/gate-run is there to be read' );

# --- joins the SAME lock DD's own tools already use, rather than a second one ---

like( $gate_run, qr/DD_SUITE_LOCK/,
    'gate-run reads the same DD_SUITE_LOCK override DD\'s own coverage-gate '
      . 'and run-suite already honour, so an injected test lock path works '
      . 'here too' );
like( $gate_run, qr{/tmp/dd-gate-host\.lock},
    'and defaults to the exact path those tools already default to - the '
      . 'point of joining a convention rather than starting a new one' );

# --- takes it around the suite run, not the whole gate chain -------------------
#
# DD's own run-suite comment is explicit about this: held across a whole
# chain, one session waited forty minutes for another's twelve-minute suite.
# The lock belongs around the docker invocation that actually writes
# cover_db, not around the git-worktree setup or the coverage-threshold loop
# that reads $output afterwards.

like( $gate_run, qr/flock[^\n]*\n(?:[^\n]*\n){0,6}?[^\n]*docker compose/,
    'the flock is taken close to the docker invocation, scoped to the suite '
      . 'run rather than the whole script' );

# --- BLOCKS rather than refuses - the opposite of DD's own tools, and why ------
#
# flock(1)'s non-blocking form is -n / --nonblock. Its absence on the
# acquisition line is the whole claim, so the line is isolated first: grepping
# the whole file for "-n" would also match unrelated flags like "docker
# compose run --rm -v", which is not evidence of anything.

my ($lock_line) = $gate_run =~ /^([^\n]*\bflock\b[^\n]*)$/m;
ok( defined $lock_line && length $lock_line, 'a line taking the flock was found' )
  or BAIL_OUT('no flock line in tools/gate-run - update the pattern above');

unlike( $lock_line, qr/-n\b|--nonblock\b/,
    'that line does not pass -n/--nonblock - this project wants concurrent '
      . 'suites to QUEUE, not refuse, since nothing here is watching for a '
      . 'refusal to retry it' );

done_testing();

__END__

=head1 NAME

552-two-suites-writing-one-database.t - gate-run takes the shared host lock, blocking

=head1 DESCRIPTION

TKT-857. Two suite runs writing the same Devel::Cover database on this host
produced a silently wrong coverage number rather than a failed run - a gate
that exists to be trusted reporting a number that is wrong instead. DD's own
C<script/coverage-gate> and C<.claude/tools/run-suite> already share an
exclusion convention for this: a flock at C<$DD_SUITE_LOCK>, default
F</tmp/dd-gate-host.lock>. C<tools/gate-run> now joins that same lock rather
than inventing a second one, held only around the docker invocation that
actually runs the instrumented suite.

It deliberately blocks instead of refusing, the opposite of DD's own tools -
those refuse on the reasoning that an interactive user should re-measure
readiness rather than have a stale waiter start the instant the lock frees.
This project's suite runs are driven by an unattended agent with nothing
watching for a refusal to retry, and the card's own title asked for
concurrent runs to queue.

=cut
