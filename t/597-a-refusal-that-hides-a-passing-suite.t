#!/usr/bin/env perl
# TKT-997. tools/gate-run's OUTER failure handler (the one that fires when the
# whole docker invocation exits non-zero) pipes the ENTIRE combined output
# through `tail -3` - right when the suite itself failed early, wrong when the
# suite passed cleanly and a LATER step (coverage-complete or coverage-guard)
# is what actually refused. Reproduced live, 2026-09-07: a gate-run failed
# four times in one session with only
#
#   gate-run: the suite did not run:
#   grep: /tmp/.gate-run-cover-out: No such file or directory
#   gate-run: refusing - coverage-guard did not trust this run
#
# with no way to tell, from that message alone, whether the ten-plus-minute
# suite had passed, failed, or never started.
#
# WHY A TOOL RATHER THAN A LINE IN gate-run, same reasoning as TKT-961's own
# tools/gate-summarize: tools/gate-run has no test harness of its own
# (TKT-716).
#
# WRITTEN RED.

use strict;
use warnings;

use File::Temp qw(tempfile);
use Test::More;

my $TOOL = 'tools/gate-outer-refusal';

sub run_tool {
    my (@args) = @_;
    my $out = qx{$^X $TOOL @args 2>&1};
    return ( $? >> 8, $out // '' );
}

sub fake_log {
    my ($content) = @_;
    my ( $fh, $path ) = tempfile( SUFFIX => '.log', UNLINK => 1 );
    print {$fh} $content;
    close $fh;
    return $path;
}

# --- the tool exists and is runnable ---------------------------------------

ok( -f $TOOL, "$TOOL exists" )
  or BAIL_OUT("$TOOL is the deliverable of this card - the rest cannot be judged without it");
ok( -x $TOOL, 'and is executable, so gate-run can call it' );

# --- the suite passed, and something after it did not - the shape this card is about

{
    my $log = fake_log(<<'LOG');
t/01-cli.t .. ok
t/594-a-job-list-that-answered-every-job.t .. ok
All tests successful.
Files=594, Tests=11290, 620 wallclock secs
Result: PASS
grep: /tmp/.gate-run-cover-out: No such file or directory
gate-run: refusing - coverage-guard did not trust this run
LOG
    my ( $status, $out ) = run_tool($log);
    is( $status, 0, 'the tool itself runs cleanly' );
    like( $out, qr/the suite passed/i,
        'it says plainly that the suite itself passed - the fact tail -3 alone could never show' );
    like( $out, qr/coverage-guard did not trust this run/,
        'and still shows the real refusal that followed' );
}

# --- the suite itself failed - the tail-3 shape from before is kept --------

{
    my $log = fake_log(<<'LOG');
t/01-cli.t .. ok
t/02-broken.t .. not ok
Failed 1/2 test programs. 3/40 subtests failed.
Result: FAIL
gate-run: the suite did not run
LOG
    my ( $status, $out ) = run_tool($log);
    is( $status, 0, 'a suite failure still runs the tool cleanly' );
    unlike( $out, qr/the suite passed/i,
        'and it does not claim the suite passed when it did not' );
    like( $out, qr/Result: FAIL/, 'the last lines of the real failure are still shown' );
}

# --- no Result line at all - docker itself never started, say so honestly --

{
    my $log = fake_log("docker: Cannot connect to the Docker daemon\n");
    my ( $status, $out ) = run_tool($log);
    is( $status, 0, 'a log with no Result line at all still runs cleanly' );
    unlike( $out, qr/the suite passed/i, 'and never claims a pass it cannot show evidence for' );
    like( $out, qr/Cannot connect to the Docker daemon/, 'and the real content is still shown' );
}

done_testing();

__END__

=head1 NAME

597-a-refusal-that-hides-a-passing-suite.t - gate-run's outer refusal names
whether the suite passed

=head1 DESCRIPTION

TKT-997. C<tools/gate-run>'s outer failure handler used to pipe the whole
captured output through C<tail -3> whenever the docker invocation exited
non-zero - hiding whether a ten-plus-minute suite had actually passed when a
LATER step (coverage-complete, coverage-guard) is what refused.
C<tools/gate-outer-refusal> checks the log for prove's own C<Result: PASS>
line first: if present, it says the suite passed and shows what came after;
otherwise it falls back to the same tail it always used, unchanged.

=cut
