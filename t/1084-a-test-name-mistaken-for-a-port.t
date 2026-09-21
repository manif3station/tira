#!/usr/bin/env perl
# TKT-634. tools/browser-tests takes a single positional argument and reads
# it as a port unconditionally - so 'tools/browser-tests column-editor.js',
# the natural guess for "run just this one", takes the test's own name AS
# THE PORT, and the failure that follows blames the board: "the board never
# came up on port column-editor.js". Neither mistake is named. There was
# also no way to actually run one test: a full invocation starts a board
# and drives all ten files every time.
#
# Proved the same way t/348 already established for this file: the real
# parsing logic is extracted from the source and run in isolation against
# fake argv, rather than only read - a change that looked right by eye
# already broke this file's own retry-loop count once (t/290).
#
# WRITTEN RED.

use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;

open my $fh, '<', '.developer-dashboard/skills/browser/cli/tests' or die "Cannot read tools/browser-tests: $!";
my $source = do { local $/; <$fh> };
close $fh;

# --- parse_args(), extracted and run in isolation --------------------------

my ($parse_args) = $source =~ /(parse_args\(\) \{.*?\n\})/s;
ok( $parse_args, 'parse_args() is found in the source, to run in isolation' );

sub run_parser {
    my (@argv) = @_;
    my $tmp = tempdir( CLEANUP => 1 );
    my $script = File::Spec->catfile( $tmp, 'try.sh' );
    open my $out, '>', $script or die $!;
    print {$out} "#!/usr/bin/env bash\nset -uo pipefail\nonly=()\nport=\"\"\n$parse_args\n"
      . "parse_args \"\$\@\" || exit 1\n"
      . 'printf \'PORT=%s\n\' "$port"' . "\n"
      . 'printf \'ONLY=%s\n\' "${only[*]:-}"' . "\n";
    close $out;
    chmod 0755, $script;
    my $output = `bash '$script' @{[ map { qq{'$_'} } @argv ]} 2>&1`;
    return ( $output, $? >> 8 );
}

{
    my ( $out, $status ) = run_parser();
    is( $status, 0, 'no arguments at all is accepted' );
    like( $out, qr/PORT=\n/, 'and no port was set - the caller gets the auto-picked one' );
    like( $out, qr/ONLY=\n/, 'and nothing was named, so every test runs' );
}

{
    my ( $out, $status ) = run_parser('7841');
    is( $status, 0, 'an all-digit argument is accepted as a port' );
    like( $out, qr/PORT=7841/, 'and it is the port that was given' );
}

{
    my ( $out, $status ) = run_parser('column-editor.js');
    isnt( $status, 0, 'a test name given bare, with no --only, is refused rather than read as a port' );
    like( $out, qr/is not a port/, 'and the refusal says so' );
    like( $out, qr/--only column-editor\.js/, 'and it suggests the way to actually name a test' );
}

{
    my ( $out, $status ) = run_parser( '--only', 'column-editor.js' );
    is( $status, 0, '--only NAME is accepted' );
    like( $out, qr/ONLY=column-editor\.js/, 'and the name is recorded to run just that one' );
}

{
    my ( $out, $status ) = run_parser( '--only', 'column-editor.js', '7841' );
    is( $status, 0, '--only NAME and a port together are both accepted' );
    like( $out, qr/PORT=7841/, 'the port is set' );
    like( $out, qr/ONLY=column-editor\.js/, 'and so is the test name' );
}

{
    my ( $out, $status ) = run_parser('--only');
    isnt( $status, 0, '--only with nothing after it is refused rather than silently doing nothing' );
    like( $out, qr/--only needs/, 'and says what --only needed' );
}

{
    # Codex review: two numeric positionals used to be silently accepted,
    # with the second overwriting the first - so
    # `tools/browser-tests 7841 7842` quietly ran on 7842. Refuse instead.
    my ( $out, $status ) = run_parser( '7841', '7842' );
    isnt( $status, 0, 'a second port argument is refused rather than silently replacing the first' );
    like( $out, qr/only one port/, 'and the refusal says so' );
}

# --- select_tests(), extracted and run against a fake tests/ directory -----

my ($select_tests) = $source =~ /(select_tests\(\) \{.*?\n\})/s;
ok( $select_tests, 'select_tests() is found in the source, to run in isolation' );

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $tests = File::Spec->catdir( $tmp, 'tests' );
    mkdir $tests;
    open my $a, '>', File::Spec->catfile( $tests, 'alpha.js' ) or die $!;
    close $a;
    open my $b, '>', File::Spec->catfile( $tests, 'beta.js' ) or die $!;
    close $b;

    my $script = File::Spec->catfile( $tmp, 'try.sh' );
    open my $out, '>', $script or die $!;
    print {$out} "#!/usr/bin/env bash\nset -uo pipefail\ntests='$tests'\n$select_tests\n";
    close $out;
    chmod 0755, $script;

    my $all = `bash -c "source '$script'; only=(); select_tests" 2>&1`;
    my @all_lines = sort split /\n/, $all;
    is_deeply( \@all_lines, [ "$tests/alpha.js", "$tests/beta.js" ],
        'naming nothing selects every test file' );

    my $one = `bash -c "source '$script'; only=('beta.js'); select_tests" 2>&1`;
    is( $one, "$tests/beta.js\n", 'naming one test selects only that one' );

    my ( $missing, $status ) = do {
        my $o = `bash -c "source '$script'; only=('nope.js'); select_tests" 2>&1`;
        ( $o, $? >> 8 );
    };
    isnt( $status, 0, 'naming a test that does not exist is refused rather than silently skipped' );
    like( $missing, qr/no such test/i, 'and says so' );
    like( $missing, qr/alpha\.js/, 'naming a known test as part of the list offered' );
}

# --- the real selection-capture, run against a stubbed select_tests --------
#
# Codex review's other finding: `mapfile -t selected_tests < <(select_tests)`
# loses select_tests' own exit status through the process-substitution pipe,
# so `--only nonexistent.js` was reported as "0 browser tests ran" with exit
# 0 instead of a refusal. Extract the real capture logic (not select_tests
# itself, which is already covered above) and run it against a stand-in
# select_tests that fails, to prove the capture itself now propagates that.

my ($capture) = $source =~ /(selected_tests_raw=.*?mapfile -t selected_tests <<< "\$selected_tests_raw"\n)/s;
ok( $capture, 'the selected_tests capture block is found in the source, to run in isolation' );

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $script = File::Spec->catfile( $tmp, 'try.sh' );
    open my $out, '>', $script or die $!;
    print {$out} "#!/usr/bin/env bash\nset -uo pipefail\n"
      . "select_tests() { echo 'browser-tests: no such test(s): nope.js' >&2; return 1; }\n"
      . "$capture"
      . 'printf \'RAN=%s\n\' "${#selected_tests[@]}"' . "\n";
    close $out;
    chmod 0755, $script;
    my $output = `bash '$script' 2>&1`;
    my $status = $? >> 8;
    isnt( $status, 0, 'a failing select_tests now fails the run instead of being masked by mapfile' );
    unlike( $output, qr/RAN=/, 'and the loop below the capture never runs, so no "0 browser tests ran" tail is printed' );
}

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $script = File::Spec->catfile( $tmp, 'try.sh' );
    open my $out, '>', $script or die $!;
    print {$out} "#!/usr/bin/env bash\nset -uo pipefail\n"
      . "select_tests() { printf '%s\\n' /fake/a.js /fake/b.js; }\n"
      . "$capture"
      . 'printf \'RAN=%s\n\' "${#selected_tests[@]}"' . "\n";
    close $out;
    chmod 0755, $script;
    my $output = `bash '$script' 2>&1`;
    my $status = $? >> 8;
    is( $status, 0, 'a succeeding select_tests still lets the run proceed' );
    like( $output, qr/RAN=2/, 'and both selected test paths are captured' );
}

# --- the fail-closed dispatch itself, run against a fake unmapped file -----

my ($dispatch) = $source =~ /(for test in "\$\{selected_tests\[\@\]\}".*?\ndone\n)/s;
ok( $dispatch, 'the dispatch for-loop is found in the source, to run in isolation' );

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $script = File::Spec->catfile( $tmp, 'try.sh' );
    open my $out, '>', $script or die $!;
    print {$out} "#!/usr/bin/env bash\nset -uo pipefail\n"
      . "run_one() { echo \"ran: \$1\"; }\n"
      . "failed=0\n"
      . "known_mappings='fake-mappings-list'\n"
      . "selected_tests=('/fake/never-mapped.js')\n"
      . "$dispatch"
      . 'printf \'FAILED=%s\n\' "$failed"' . "\n";
    close $out;
    chmod 0755, $script;
    my $output = `bash '$script' 2>&1`;
    is( $? >> 8, 0, 'the dispatch loop itself does not abort the script' );
    unlike( $output, qr/^ran:/m, 'an unmapped test file is never handed to run_one' );
    like( $output, qr/no fixture mapping for 'never-mapped\.js'/, 'and it is named as unmapped' );
    like( $output, qr/FAILED=1/, 'and it counts toward the failure total' );
}

# --- every real test file has a real case mapping, kept in sync -----------
#
# Codex review caught this the hard way: the first draft's fail-closed
# catch-all (CHK-005) would have broken review-toggle.js, a genuinely
# existing test that had simply never had its own case label, because it
# happened to want the same fixture the old catch-all handed everything.
# known_mappings is a hand-written list precisely because the case
# statement itself is not easily introspected from outside the script - so
# this is the guard that keeps the two from drifting apart again: every
# real file in t/playwright must appear as its own case label somewhere in
# the dispatch, or this fails naming which one does not.

{
    my @real_tests = sort map { s{.*/}{}r } glob('t/playwright/*.js');
    cmp_ok( scalar @real_tests, '>=', 20, 'the real browser test directory has tests to check against' );

    # Scoped to $dispatch (the actual dispatch loop, extracted above), not
    # the whole $source - a later Codex review pass caught that scanning
    # the whole file could let a dead or duplicate .js) label anywhere else
    # in the script satisfy this check without ever being part of the real
    # case statement that decides how each test runs.
    my @case_labels = $dispatch =~ /^\s{8}((?:[a-z][a-z0-9.-]*\.js\|?)+)\)/mg;
    my %mapped = map { $_ => 1 } map { split /\|/ } @case_labels;

    my @unmapped = grep { !$mapped{$_} } @real_tests;
    is_deeply( \@unmapped, [],
        'every real t/playwright/*.js file has its own case label in the dispatch, so none of them can silently fall to the fail-closed catch-all' );
}

done_testing;

__END__

=head1 NAME

1084-a-test-name-mistaken-for-a-port.t - a bare test name is refused, not read as a port

=head1 DESCRIPTION

TKT-634. C<tools/browser-tests> took one positional argument and always
read it as a port, so naming a test the natural way -
C<tools/browser-tests column-editor.js> - silently misrouted it, and the
failure that followed blamed the board rather than the argument. There was
also no way to run one test at all.

C<parse_args()> and C<select_tests()> are extracted from the source and
run in isolation against fake argv and a fake tests directory, the same
technique C<t/348> already established for this file, because reading the
source alone already missed a real change to this file's behaviour once
(C<t/290>).

=cut
