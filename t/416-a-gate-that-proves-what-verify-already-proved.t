#!/usr/bin/env perl

# The push hook runs the full suite that verify already ran.
#
# tools/hooks/pre-push is 266 lines and 138 of them are one block: a
# detached worktree, a container, prove under Devel::Cover, a coverage
# assertion over three modules, and a gate-cache lookup whose only purpose is
# to skip that work when it has already been done. It costs about twenty
# minutes on every release.
#
# Verify has already run that identical suite. Measured on the two cards
# released this morning: the suite ran at 08:41 in verify and again at 11:47
# in the hook, over a tree the first run had cleared. The push of 4.60 and
# 4.61 took 21 minutes 19 seconds, of which the suite was almost all of it -
# and the first attempt was killed by a foreground timeout and left an
# orphaned perl-test container still running, which is a cost of the length
# rather than an accident beside it.
#
# The gate-cache (TKT-351) was built to stop exactly this double-run and
# cannot. It keys on git rev-parse HEAD^{tree}; the verify suite runs against
# the working tree BEFORE the documentation and version commits exist, so the
# tree it records is never the tree being pushed. It held 93 records this
# morning and not one for HEAD's tree 806456eb. A cache that never hits in the
# real workflow is a mechanism whose only remaining cost is its comments.
#
# The owner's rule, given directly and then narrowed when asked: "push should
# not run full test as discussed. anything landed on push column is ready to
# pushed", and on the question of what replaces it, "only trim away the full
# test run. keep other checks".
#
# So this is a subtraction, and the risk of a subtraction is that it takes
# more than it was meant to. Most of what follows guards the things that must
# SURVIVE. Seven checks stay, four before the removed block and three after
# it, and the three after it are last on purpose - their own comment says
# "Documentation edited after a gate has shipped a broken build here twice,
# so anything that runs before the edits proves nothing about what goes out."
# Removing the suite must not disturb that ordering.
#
# Two things go with the block and are easy to miss. The hook's closing line
# announces "suite passed, coverage is 100% on all three modules" - a claim
# that stops being true the moment the suite goes, and a gate that ends by
# announcing something it no longer does is worse than one that says nothing.
# And tools/prove-the-gate carries a "# covers:" line per refusal the hook can
# make; t/233 fails on a claim about a refusal the hook no longer makes, so
# the lines for the removed refusals go too.

use strict;
use warnings;

use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my $hook     = slurp('tools/hooks/pre-push');
my $prover   = slurp('tools/prove-the-gate');
my $gate_run = slurp('tools/gate-run');

# Established first, and not as a formality: every denial below is about text
# that is absent from these three files, and a denial about a file that failed
# to load would pass while measuring nothing. That is the whole subject of
# t/147 and it applies to itself here.
like( $hook, qr{\A#!/usr/bin/env bash}, 'the push hook is a bash script and was read' );
like( $prover, qr{\A#!/usr/bin/env bash}, 'the gate prover was read' );
like( $gate_run, qr{\A#!/usr/bin/env bash}, 'the manual gate runner was read' );

# --- the suite is gone from the hook ----------------------------------------
#
# Named one at a time rather than as one pattern, because they are separate
# pieces of the block and a partial removal is the likely failure: the suite
# taken out and the coverage loop left behind, reading a file nothing writes.

unlike( $hook, qr/\bprove\s+-lr\b/,
    'the hook does not run the test suite' );
unlike( $hook, qr/Devel::Cover/,
    'and does not run it under the coverage harness' );
unlike( $hook, qr/\bdocker\s+compose\b/,
    'and starts no container' );
unlike( $hook, qr/SUITE_TIMEOUT/,
    'and carries no suite timeout, because there is no suite to time' );
unlike( $hook, qr/git\s+worktree\s+add/,
    'and checks out no detached tree to run one against' );
unlike( $hook, qr/\bcover\s+-ignore_covered_err/,
    'and asks for no coverage report' );
unlike( $hook, qr/coverage is below 100%/,
    'and cannot refuse for coverage it never measured' );
unlike( $hook, qr/Result:\s*PASS/,
    'and does not look for a suite result' );

# --- and the cache that existed only to skip it -----------------------------
#
# gate-cache-read answers one question: has this exact tree already been
# proved, so the suite can be skipped. With no suite to skip it has nothing to
# answer, and a live-looking call to it would be dead code behind a real name -
# which is the fault t/121 exists to catch on the dashboard's controls.

unlike( $hook, qr{tools/gate-cache-read},
    'the hook does not consult the gate cache' );
unlike( $hook, qr{tools/gate-cache-write},
    'and does not write to it' );

# --- what must survive ------------------------------------------------------
#
# The subtraction's real risk. Seven checks stay; each is named here so that
# taking one out with the block fails rather than passing quietly.

like( $hook, qr/checking the version against what is being shipped/,
    'the version check survives' );
like( $hook, qr{tools/board-backup},
    'the board backup survives' );
like( $hook, qr/refusing to push without a backup/,
    'including its refusal when the backup tool is missing' );
like( $hook, qr{tools/card-holes},
    'the card check survives' );
like( $hook, qr/every live card is complete|checking the board for incomplete/,
    'and the live-card completeness check with it' );
like( $hook, qr{tools/docs-match-code},
    'the documentation check survives' );
like( $hook, qr{tools/docs-examples-run},
    'every documented example is still run' );
unlike( $hook, qr{tools/browser-tests\s*(?:\|\||&&|;|\z)},
    'the browser suite no longer runs here - TKT-796 moved it to a per-card, '
      . 'conditional verify-column check instead of a once-per-push gate' );

# The ordering, not just the presence. These run last deliberately -
# documentation edited after a gate has shipped a broken build here twice - and
# a removal that hoisted them above the surviving checks would leave them
# proving nothing about what goes out.
my $version_at  = index( $hook, 'checking the version against what is being shipped' );
my $backup_at   = index( $hook, 'tools/board-backup' );
my $holes_at    = index( $hook, 'tools/card-holes' );
my $docs_at     = index( $hook, 'tools/docs-match-code' );
my $examples_at = index( $hook, 'tools/docs-examples-run' );

cmp_ok( $version_at, '<', $backup_at,
    'the version check still runs before the board backup' );
cmp_ok( $backup_at, '<', $holes_at,
    'the board backup still runs before the card check' );
cmp_ok( $holes_at, '<', $docs_at,
    'and the card check before the documentation checks' );
cmp_ok( $docs_at, '<', $examples_at,
    'the documentation check still runs before the examples' );

# "Last of all" was claimed by the documentation and NOT asserted here until a
# review pointed out that an ordering between names says nothing about what
# comes after the last one. TKT-796 removed the browser step that used to hold
# this position; the examples step is now last, and nothing may run after it
# except the closing message.
# Anchored on the INVOCATION, not on the first mention: every tool here is
# named twice, once in an `[ -x ... ]` guard and once when it runs, and the
# first mention is the guard. Anchoring on it left the invocation line inside
# the tail and both counts below were wrong - caught by them failing.
my $invoked_at = index( $hook, 'tools/docs-examples-run || fail' );
cmp_ok( $invoked_at, '>', $examples_at,
    'the examples tool is guarded before it is invoked' );

my $after_examples = substr( $hook, $invoked_at );
$after_examples =~ s/\A[^\n]*\n//;    # the invocation line itself

# Counted rather than denied. A denial here would pass against an empty tail
# just as happily as against a correct one, and the tail is exactly what a new
# step would be appended to.
my $steps_after = () = $after_examples =~ /^step\s/mg;
is( $steps_after, 1,
    'exactly one step follows the examples, and it is the closing message' );

my $refusals_after = () = $after_examples =~ /\bfail\s+["']/g;
is( $refusals_after, 0,
    'nothing after the examples can refuse a push - it is the last gate' );

my $tools_after = () = $after_examples =~ m{\btools/[a-z-]+}g;
is( $tools_after, 0,
    'and no further tool is invoked after it' );

# --- the hook stops claiming what it no longer does -------------------------
#
# Two of the four claims in the closing line die with the suite. A gate whose
# final word is a summary of work it did not do is a gate that reads as having
# passed something.

unlike( $hook, qr/suite passed, coverage is 100%/,
    'the closing message no longer announces a suite run and a coverage figure' );
like( $hook, qr/^step '.*documentation agrees.*'/m,
    'and still says what it did prove' );

# --- the gate is still a gate -----------------------------------------------
#
# A subtraction that took the refusals with it would leave a hook that runs and
# permits everything. Counted from the file rather than listed here, the way
# t/233 counts them, so this measures the hook and not a copy of it.

my @refusals = ( $hook =~ /\bfail\s+["']([^"']+)/g );
cmp_ok( scalar @refusals, '>=', 8,
    'the hook can still refuse a push, in several distinct ways' );

# --- the tools survive losing their caller ----------------------------------
#
# "The cache leaves with the suite" reads as "delete it" if nothing says
# otherwise. tools/gate-run is how a tree is proved by hand and it still writes
# the records; only the hook stops reading them.

like( $gate_run, qr/\bprove\s+-lr\b/,
    'tools/gate-run still runs the suite by hand' );
like( $gate_run, qr{tools/gate-cache-write|gate-cache-write},
    'and still records the pass for the tree it proved' );

# --- and prove-the-gate claims nothing about refusals that are gone ---------
#
# t/233 fails on a "# covers:" line naming a refusal the hook no longer makes.
# Asserted here too, next to the removal that causes it, so the reason a
# distant test went red is written where the change is.

for my $stale (
    'the suite did not run',
    'the suite did not finish',
    'the suite failed',
    'no coverage was measured for',
    'coverage is below 100% for',
    'could not check out the commits being pushed',
    )
{
    unlike( $prover, qr/#\s*covers:\s*\Q$stale\E/,
        "prove-the-gate no longer claims to cover '$stale'" );
}

done_testing();

__END__

=head1 NAME

t/416-a-gate-that-proves-what-verify-already-proved.t - the push hook must not
re-run the suite verify already ran

=head1 DESCRIPTION

C<tools/hooks/pre-push> ran the full suite with coverage before every push -
138 of its 266 lines and some twenty minutes - over a tree the verify
column had already cleared. Measured on the release of 4.60 and 4.61: the suite
ran at 08:41 in verify and again at 11:47 in the hook, and the push took 21
minutes 19 seconds.

The gate-cache built to prevent that double-run could not, because it keys on
the tree C<HEAD> carries and the verify run happens before the documentation
and version commits exist. It held 93 records and matched none of them.

The owner's instruction was to remove the suite and nothing else: I<"only trim
away the full test run. keep other checks">. So most of this file guards what
must survive - seven checks, four before the removed block and three after it,
in that order, because the three after it are last on purpose.

Two consequences are easy to miss and are asserted here: the hook's closing
line announced a suite result and a coverage figure it no longer has, and
C<tools/prove-the-gate> declared coverage for six refusals the hook can no
longer make, which C<t/233> refuses.

=cut
