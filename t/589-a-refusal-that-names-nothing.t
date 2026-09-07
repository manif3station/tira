#!/usr/bin/env perl
# TKT-961. tools/gate-run used to pipe the suite through `tail -4`: right on a
# clean run, wrong on a refusal - prove prints its Test Summary Report
# (naming every failing file and its failing subtests) ABOVE the four lines
# tail kept, so a refusal said only "Result: FAIL" with nothing to act on.
# Measured five times in one session: each cost a full re-run of a
# ten-to-sixteen-minute suite to learn what prove had already printed.
#
# WHY A TOOL RATHER THAN A LINE IN gate-run. tools/gate-run has no test
# harness of its own (TKT-716) - the same reason tools/coverage-complete
# exists rather than a check inline there for TKT-954/572. Extracted here as
# tools/gate-summarize, driven directly the way t/572 drives
# coverage-complete.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

my $TOOL = 'tools/gate-summarize';

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
ok( -x $TOOL, 'and is executable, so the gate can call it' );

# --- a clean run's output is unchanged - four lines, nothing more -----------

{
    my $log = fake_log(<<'LOG');
t/01-cli.t .. ok
t/02-failure-paths.t .. ok
All tests successful.
Files=2, Tests=20,  1 wallclock secs
Result: PASS
LOG
    my ( $status, $out ) = run_tool( 0, $log );
    is( $status, 0, 'a clean run exits clean' );
    my @lines = split /\n/, $out;
    is( scalar @lines, 4, 'and prints exactly four lines, unchanged from before this card' );
    like( $out, qr/All tests successful/, 'the success line survives' );
    like( $out, qr/Result: PASS/, 'and the result line survives' );
    unlike( $out, qr/Test Summary Report/,
        'and nothing about a Test Summary Report is printed - there is no failure to report' );
}

# --- a refusal names the failing file and its failing subtests -------------
#
# THE ASSERTION THIS CARD IS ABOUT: a real prove Test Summary Report block,
# fed through the tool with a non-zero status, has to survive into the
# output - not be summarized, not be re-derived, just not thrown away.

{
    my $log = fake_log(<<'LOG');
t/01-cli.t .. ok
t/147-a-denial-that-needed-a-subject.t .. 1/7

#   Failed test 'a denial against an empty string is refused, not passed for the wrong reason'
#   at t/147-a-denial-that-needed-a-subject.t line 42.
# Looks like you failed 1 test of 7.
t/147-a-denial-that-needed-a-subject.t ..

Test Summary Report
-------------------
t/147-a-denial-that-needed-a-subject.t (Wstat: 256 (exited 1) Tests: 7 Failed: 1)
  Failed test:  3
  Non-zero exit status: 1
Files=2, Tests=27,  1 wallclock secs
Result: FAIL
LOG
    my ( $status, $out ) = run_tool( 1, $log );
    is( $status, 0, 'the tool itself runs cleanly even when reporting a failure' );
    like( $out, qr/Test Summary Report/, 'the Test Summary Report block is printed' );
    like( $out, qr/t\/147-a-denial-that-needed-a-subject\.t/,
        'the failing FILE is named - this is the whole point of the card' );
    like( $out, qr/Failed test:\s*3/, 'and which subtest failed within it' );
    like( $out, qr/Result: FAIL/, 'the four-line tail is still printed too' );
}

# --- and it does not invent detail the log does not have --------------------
#
# A refusal from a signal (SUITE_TIMEOUT killing the run) or a crash before
# prove ever printed a summary has no such block to show - the tool must not
# fabricate one.

{
    my $log = fake_log("prove: exec of /usr/bin/perl failed\n");
    my ( $status, $out ) = run_tool( 1, $log );
    is( $status, 0, 'a log with no Test Summary Report still runs cleanly' );
    unlike( $out, qr/Test Summary Report/,
        'and prints no such block, because there genuinely is not one to show' );
}

done_testing();

__END__

=head1 NAME

588-a-refusal-that-names-nothing.t - a gate refusal names the failing file

=head1 DESCRIPTION

TKT-961. C<tools/gate-run> discarded prove's own Test Summary Report on a
suite failure, keeping only the last four lines of output - which name that
something failed, and nothing about what. C<tools/gate-summarize> prints
those four lines always, and the full Test Summary Report as well whenever
the suite's own exit status is non-zero, changing nothing about the common,
clean-run case.

=cut
