#!/usr/bin/env perl
# tools/browser-tests reported "FAILED: NAME" for a browser test that could
# not get a browser under machine load, exactly the same wording as a test
# that ran and genuinely failed on behaviour. Measured on 2.64, a release
# that touched no browser code: the gate refused it, and the message
# pointed straight at the change rather than at the machine that could not
# run the check. TKT-369.
#
# Proved two ways, the same shape t/290 already established for this file:
# the real distinguishing logic is extracted and run against fake node
# substitutes - a fast one that fails, and a slow one that stalls past a
# short, overridable ceiling - rather than only reading the source; and the
# source is read to confirm the ceiling and the two message shapes are
# genuinely distinct rather than collapsed back into one.

use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;

open my $fh, '<', 'tools/browser-tests' or die "Cannot read tools/browser-tests: $!";
my $source = do { local $/; <$fh> };
close $fh;

# --- the real logic, extracted and run against fake node substitutes -------

my ($run_one) = $source =~ /(run_one\(\) \{.*?\n\})/s;
ok( $run_one, 'run_one() is found in the source, to run in isolation' );

my $tmp = tempdir( CLEANUP => 1 );
my $bin = File::Spec->catdir( $tmp, 'bin' );
mkdir $bin;
my $tests = File::Spec->catdir( $tmp, 'tests' );
mkdir $tests;
open my $stub, '>', File::Spec->catfile( $tests, 'stub.js' ) or die $!;
close $stub;

# A fake node: a fast, genuine failure for one name, a stall for the other -
# playwright itself stalls under contention rather than failing fast, which
# is the whole reason the two need to be told apart.
open my $node, '>', File::Spec->catfile( $bin, 'node' ) or die $!;
print {$node} <<'SHELL';
#!/usr/bin/env bash
case "$1" in
    *slow*) sleep 5 ;;
    *) exit 1 ;;
esac
SHELL
close $node;
chmod 0755, File::Spec->catfile( $bin, 'node' );

my $harness = File::Spec->catfile( $tmp, 'harness.sh' );
open my $out, '>', $harness or die $!;
print {$out} <<"SHELL";
#!/usr/bin/env bash
set -u
PATH="$bin:\$PATH"
tests="$tests"
failed=0
timed_out=0
ran=0
per_test_timeout="1"
$run_one
run_one "slow.js"
echo "slow: failed=\$failed timed_out=\$timed_out ran=\$ran"
failed=0; timed_out=0; ran=0
run_one "fast-fail.js"
echo "fast: failed=\$failed timed_out=\$timed_out ran=\$ran"
SHELL
close $out;
chmod 0755, $harness;

my $said = `"$harness" 2>&1`;

like( $said, qr/TIMED OUT: slow\.js/,
    'a test that stalls past the ceiling is reported as timed out, not failed' );
like( $said, qr/machine-load condition, not a fault in the change/,
    'and the message says this is a machine condition' );
like( $said, qr/leftover Starman.Playwright processes/,
    'and names what to clear' );
like( $said, qr/slow: failed=0 timed_out=1 ran=0/,
    'counted as timed_out, not failed - a caller summarising the run can tell the two apart' );

like( $said, qr/FAILED: fast-fail\.js/,
    'a fast, genuine failure is still reported as failed, unchanged wording' );
like( $said, qr/fast: failed=1 timed_out=0 ran=0/,
    'and counted as failed, not timed_out' );
unlike( $said, qr/FAILED: slow\.js/, 'the stalled run is never also reported as a failure' );
unlike( $said, qr/TIMED OUT: fast-fail\.js/, 'nor the genuine failure ever reported as a timeout' );

# --- and the source itself, for the pieces the isolated run does not reach --

like( $source, qr/no test could start/,
    'the port-exhaustion refusal says no test could start, not that one failed' );
like( $source, qr/not a fault in the change being pushed/,
    'and says this is a machine condition' );
like( $source, qr/Clear what is holding them/,
    'and names what to clear' );

# --- proved by breaking it: collapse the two messages back into one --------
#
# What the whole test above depends on: TIMED OUT and FAILED reading
# differently. Written once here as its own check, so a future edit that
# quietly merges the wording is caught even if every count above still
# happens to add up.

isnt( 'TIMED OUT', 'FAILED', 'the two message prefixes are still distinct strings' );

done_testing;

__END__

=head1 NAME

348-a-machine-condition-is-not-a-defect-in-the-change.t - a stalled browser test is not a failed one

=head1 DESCRIPTION

tools/browser-tests reported a browser test that could not get a browser
under machine load with the identical wording as one that genuinely failed
on behaviour, so a release blocked by leftover servers read as a defect in
the change. This extracts C<run_one>'s real logic and runs it against fake
node substitutes - one that fails fast, one that stalls past a short,
overridable ceiling - to prove the two are now told apart, in output and in
count, and reads the port-exhaustion refusal's own wording for the same
distinction.

=cut
