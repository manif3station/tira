#!/usr/bin/env perl

use strict;
use warnings;

use File::Temp qw(tempfile);
use Test::More;

# TKT-1208. d2 gate.run's plain suite failed and the whole output was
#
#   gate-run: testing a checkout of HEAD (...)
#   Result: FAIL
#   gate-run: the plain suite did not pass - refusing before any coverage run starts
#
# with no failing file named, so the developer re-ran the suite another way to
# find out. The report was never lost: the container printed it (tools/
# gate-summarize puts prove's Test Summary Report in front of the refusal), and
# the same tree run through d2 dev.run named three files. What dropped it is the
# OUTER failure handler, gate/skills/outer/cli/refusal, which gate/cli/run calls
# when the docker invocation exits non-zero: its branch for a log with no
# "Result: PASS" was `tail -3` of everything, so of the report only the last
# three lines survived. TKT-997 made the passed-then-refused case readable and
# left this one as it was. Reproduced with a deliberate failing test on a
# scratch branch, 2026-10-02.
#
# What is held here: a suite failure's refusal carries the Test Summary Report -
# every failing file and its failed test numbers - and the closing refusal
# line, without dumping the passing files above it; a failing log with no
# report keeps the tail it always had; and the passed-then-refused shape from
# TKT-997 is unchanged.

my $TOOL = '.developer-dashboard/skills/gate/skills/outer/cli/refusal';

sub run_tool {
    my ($log) = @_;
    my $out = qx{$^X $TOOL $log 2>&1};
    return ( $? >> 8, $out // '' );
}

sub fake_log {
    my ($content) = @_;
    my ( $fh, $path ) = tempfile( SUFFIX => '.log', UNLINK => 1 );
    print {$fh} $content;
    close $fh;
    return $path;
}

ok( -x $TOOL, "$TOOL exists and is executable" ) or BAIL_OUT('nothing below can be judged without the tool');

# --- a plain-suite failure: the report is in the log, and must reach the reader --

{
    my $log = fake_log(<<'LOG');
t/01-cli.t ........................................ ok
t/02-failure-paths.t .............................. ok
t/594-a-job-list-that-answered-every-job.t ........ ok

Test Summary Report
-------------------
t/1098-a-count-nothing-connects-to-its-file.t   (Wstat: 768 (exited 3) Tests: 13 Failed: 3)
  Failed tests:  10-11, 13
  Non-zero exit status: 3
t/876-a-count-that-outgrew-its-own-claim.t      (Wstat: 512 (exited 2) Tests: 6 Failed: 2)
  Failed tests:  5-6
  Non-zero exit status: 2
Files=801, Tests=14692, 300 wallclock secs ( 2.09 usr  0.82 sys + 181.83 cusr 32.91 csys = 217.65 CPU)
Result: FAIL
gate-run: the plain suite did not pass - refusing before any coverage run starts
LOG
    my ( $status, $out ) = run_tool($log);
    is( $status, 0, 'the tool itself runs cleanly' );
    like( $out, qr/t\/1098-a-count-nothing-connects-to-its-file\.t/, 'a failing file is named' );
    like( $out, qr/t\/876-a-count-that-outgrew-its-own-claim\.t/, 'and so is the other one' );
    like( $out, qr/Failed tests:\s+10-11, 13/, 'with its failed test numbers' );
    like( $out, qr/Result: FAIL/, 'and the result' );
    like( $out, qr/the plain suite did not pass - refusing before any coverage run starts/, 'and the closing refusal line' );
    unlike( $out, qr/t\/01-cli\.t/, 'without dumping the files that passed' );
    unlike( $out, qr/the suite passed/i, 'and without claiming the suite passed' );
}

# --- a failing log with no report keeps the tail it always had (t/597) ---------

{
    my $log = fake_log(<<'LOG');
t/01-cli.t .. ok
t/02-broken.t .. not ok
Result: FAIL
gate-run: the suite did not run
LOG
    my ( $status, $out ) = run_tool($log);
    is( $status, 0, 'a log with no report still runs cleanly' );
    like( $out, qr/Result: FAIL/, 'and still shows the last lines' );
    like( $out, qr/t\/02-broken\.t/, 'including the broken file it can see' );
}

# --- the TKT-997 shape is unchanged: the suite passed, a later step refused -----

{
    my $log = fake_log(<<'LOG');
t/01-cli.t .. ok
All tests successful.
Files=594, Tests=11290, 620 wallclock secs
Result: PASS
grep: /tmp/.gate-run-cover-out: No such file or directory
gate-run: refusing - coverage-guard did not trust this run
LOG
    my ( $status, $out ) = run_tool($log);
    is( $status, 0, 'the passed-then-refused shape still runs cleanly' );
    like( $out, qr/the suite passed/i, 'and still says the suite passed' );
    like( $out, qr/coverage-guard did not trust this run/, 'and still shows what refused' );
}

done_testing;

__END__

=head1 NAME

1208-a-refusal-that-names-the-failing-files.t - the outer gate refusal carries a suite failure's report

=head1 DESCRIPTION

TKT-1208. C<d2 gate.run>'s plain suite failed and the refusal named no file,
because the outer failure handler printed C<tail -3> of the whole captured
output and the Test Summary Report is longer than that. This file holds that a
suite failure's refusal shows the report - each failing file and its failed
test numbers - and the closing refusal line without the passing files, that a
log with no report keeps its tail, and that the passed-then-refused case from
TKT-997 is unchanged.

=cut
