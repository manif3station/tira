#!/usr/bin/env perl
# The guards that read the tests are undocumented as a set, so a test author
# meets them one full suite run at a time.
#
# TKT-865. Nineteen files in t/ do not test a feature - they test the SUITE
# itself: an assertion shape, a doc-vs-code count, a module's own POD, a
# structural limit, a decision that must not drift into two places, a
# fixture that must not drift from what it mocks. A test author writing
# test number twenty learns each one only when it fails on a change that
# broke nothing, which is what every one of these files' own opening
# comment describes happening to it before it existed.
#
# Read from t/ directly (CHK-001), not from memory, and found in THREE
# passes - Codex review caught five the first pass missed by grepping only
# header-comment phrasing rather than the words this suite's own guards use
# to describe each other (t/566's own header names t/147, t/121, t/344 AND
# t/220 as "meta-tests"; t/653 names t/121 and t/147; t/531 names itself
# "the meta-guard" in its own WHAT IS ASSERTED), and a second Codex pass
# caught a sixth (t/717) plus a weak count check. t/582, t/179, t/597,
# t/552, t/155 and t/172 were considered and excluded - they measure or
# test the release tooling's own behaviour as a FEATURE, not a convention
# for how a test itself is written.
#
# WHAT THIS FILE MUST NOT DO is re-implement any guard's own check - that is
# what would go stale exactly like the documentation this card exists to fix.
# It asserts only that each one still exists, still carries the phrase that
# names it, and that SKILLS.md's own table names EXACTLY this set - the
# sorted list of names extracted from the table compared with is_deeply
# against the sorted canonical list, not merely counted or checked one
# filename at a time, either of which a wrong-but-same-count substitution
# would still pass.
#
# WRITTEN RED.

use strict;
use warnings;

use Test::More;

# The canonical list. Adding a twentieth guard means adding it here AND to
# SKILLS.md - this file cannot discover one by itself, the same honest limit
# t/433's own doc-vs-code count check has: a check can compare two named
# things, it cannot notice a third thing nobody named yet.
my @GUARDS = (
    { file => 't/03-metadata.t',
      what => 'version consistency, POD across lib/, every documented command resolves',
      marker => 'podchecker' },
    { file => 't/121-no-dead-controls.t',
      what => 'every rendered control has a working binding, not just a widget',
      marker => 'The page offers only what it can do' },
    { file => 't/147-a-denial-that-a-broken-page-passes.t',
      what => 'unlike() on an empty/broken string must not pass as a kept promise',
      marker => 'A denial means the thing was there and did not say it' },
    { file => 't/149-a-refusal-that-never-said-why.t',
      what => 'a refusal test proves ITS OWN refusal, not merely that something died',
      marker => 'A refusal test proves the refusal it was written for' },
    { file => 't/220-one-way-to-say-which-board.t',
      what => 'no command reintroduces a second way to say which board (--project etc.)',
      marker => 'One way to say which board, not three' },
    { file => 't/345-tests-cannot-phone-home.t',
      what => 'a test exercising agent-still/police_pass cannot send a real message to a real phone',
      marker => 'declares agent-still and calls police_pass' },
    { file => 't/356-a-command-that-derives-itself.t',
      what => 'every command dispatcher derives its own command name the same way, none hardcode it',
      marker => 'command dispatchers sit outside the coverage gate' },
    { file => 't/531-two-closures-one-name.t',
      what => 'every $report closure in the engine declares the identical parameter list',
      marker => 'A monitor\'s words, passed to a function that could not receive them' },
    { file => 't/566-one-decision-in-two-places.t',
      what => "a registry of known decisions that must not drift into a second, disagreeing implementation",
      marker => 'THE REGISTRY IS THE DELIVERABLE, NOT ANY ONE RULE' },
    { file => 't/176-an-assertion-that-cannot-fail.t',
      what => 'qr/\S/ marks a real precondition, or names itself as one',
      marker => 'non-empty is the whole claim' },
    { file => 't/344-methods-pod-matches-what-cli-calls.t',
      what => "lib/Tira.pm's own POD METHODS section matches the engine it documents",
      marker => 'documented exactly 5 engine methods' },
    { file => 't/429-a-gate-that-checks-what-it-knows.t',
      what => "tools/gate-run's module list matches lib/'s real files, not a typed copy",
      marker => 'The coverage gate has to check what is in lib/' },
    { file => 't/430-an-index-that-is-the-whole-book.t',
      what => 'lib/Tira/CLI.pm stays under its own line-count index limit',
      marker => 'Tira::CLI has to be an index, not the whole book' },
    { file => 't/431-a-module-that-can-stand-on-its-own.t',
      what => 'every module under lib/ can require() standalone, not only under Tira::CLI',
      marker => 'Every module under lib/ has to be able to answer for itself' },
    { file => 't/433-a-count-stated-three-times-and-checked-once.t',
      what => 'a count stated in prose in several places is checked against the real one',
      marker => 'The number of police rules is stated in three places and checked in one' },
    { file => 't/486-a-test-that-says-where-code-lives.t',
      what => 'a test opening a source file by name is pinning where code lives, marked or not',
      marker => 't/486 marker: about this file, not its code' },
    { file => 't/524-a-rule-with-nothing-watching-it.t',
      what => 'a standing instruction that lived only in a Telegram message now has a test',
      marker => 'A standing rule that only exists in a Telegram message' },
    { file => 't/653-a-class-with-nothing-behind-it.t',
      what => 'every BEM class the view JS assigns matches a stylesheet rule, or is on the exemption ledger',
      marker => 'A meta-test in the family of t/121' },
    { file => 't/717-a-fixture-that-stopped-listening.t',
      what => 'a Playwright fixture mocking a real payload shape keeps listening to what that shape actually carries',
      marker => 'Three fixtures drifted from the thing they mock in one session' },
);

for my $guard (@GUARDS) {
    ok( -f $guard->{file}, "$guard->{file} exists - $guard->{what}" );

    open my $fh, '<', $guard->{file} or die "$guard->{file}: $!";
    local $/;
    my $body = <$fh>;
    close $fh;

    like( $body, qr/\Q$guard->{marker}\E/,
        "$guard->{file} still carries its own marker phrase - a guard silently "
          . 'gutted or renamed would still pass an existence check alone' );
}

# --- the documentation names every one of them, and no others --------------

open my $skills, '<', 'SKILLS.md' or die "SKILLS.md: $!";
local $/;
my $doc = <$skills>;
close $skills;

for my $guard (@GUARDS) {
    like( $doc, qr/\Q$guard->{file}\E/,
        "SKILLS.md names $guard->{file} - a test author can find it before writing test "
          . 'number nineteen, not only after it fails on one' );
}

# Compared as a SET, not only counted - Codex review's second pass: a count
# alone would still pass if a wrong row replaced a canonical one while the
# missing canonical name happened to appear elsewhere in SKILLS.md (the
# earlier like() checks above scan the whole document, not only the table).
# And ONLY table rows are read - the section's own closing paragraph names
# t/582, t/179 etc as EXCLUDED, which a section-wide scan would wrongly
# count as included; a Markdown table row starts with "| `t/".
my ($section) = $doc =~ /^## The meta-guards\b(.*?)(?=^## |\z)/ms;
ok( defined $section, 'the "## The meta-guards" section exists in SKILLS.md' );

my @table_files = sort keys %{ { map { $_ => 1 }
    ( $section // '' ) =~ /^\|\s*`(t\/\d+[a-z0-9-]*\.t)`/mg } };
my @canonical_files = sort map { $_->{file} } @GUARDS;

is_deeply( \@table_files, \@canonical_files,
    'THE TABLE NAMES EXACTLY THIS SET - not a substitution with the same count, '
      . 'not fewer (an undocumented guard), not more (a documented one this '
      . 'file never checks) - so the table and the list cannot drift apart the '
      . 'way t/433\'s own subject already did once before it existed' );

done_testing();

__END__

=head1 NAME

865-guards-that-name-themselves.t - the meta-guards, documented as a set

=head1 WHY

TKT-865: nineteen files in t/ police the suite itself rather than a feature,
and nothing named them together - a test author met each one individually,
one failed run at a time.

=head1 WHAT IS ASSERTED

Each of the nineteen guards still exists and still carries its own marker
phrase - proof it has not been silently gutted or renamed. SKILLS.md's own
section names exactly this set, compared as a sorted list rather than only
counted, so a substituted row with the same count still fails.

=head1 WHAT IS NOT ASSERTED

That these are the ONLY nineteen that will ever exist, or that a twentieth
guard added later is automatically caught - that would require this file to
know what a "meta-guard" is well enough to recognise one on sight, which is
exactly the judgement call CHK-001 made by reading t/ by hand, across three
passes. Adding one means adding it here and to SKILLS.md, the same way
t/433's own doc-vs-code count needs a human to add a fourth place a number
could be stated.

=cut
