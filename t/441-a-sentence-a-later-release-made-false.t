#!/usr/bin/env perl
# TKT-761. SKILLS.md's task-changed passage says:
#
#     a freshly-added item is not reported and settles the instant it has
#     been seen once.
#
# That was true when TKT-548 shipped the rule. TKT-606 (4.79) made it false:
# an item arriving on a board police has already seen is now reported once,
# and one disappearing is reported once too - lib/Tira.pm emits 'new task
# "..."' and 'task removed: "..."'. The document now teaches the belief
# TKT-606 exists to correct: he asked twice why a new task was announced by
# nothing, and an agent reading this passage would answer "by design" and
# close the question wrongly.
#
# docs/POLICIES.md:381 already describes the shipped behaviour accurately -
# arrivals, removals, and the first-pass-stays-quiet decision that keeps an
# existing tasklist from being dumped at once. This file holds SKILLS.md to
# the same standard, without asking it to stop saying the first-pass half,
# which is still true and still the point of the design.

use strict;
use warnings;

use Test::More;

my $skills = do {
    local $/;
    open my $fh, '<:encoding(UTF-8)', 'SKILLS.md' or die "Cannot read SKILLS.md: $!";
    <$fh>;
};

# The task-changed passage is one paragraph starting at its TKT-548 sentence.
# Found by that anchor and read to the next blank line, so the assertions
# below are about this passage specifically and not the whole document.
my ($passage) = $skills =~ /(TKT-548:.*?)\n\n/s;

ok( defined $passage && length $passage, 'SKILLS.md has a task-changed passage to check' )
  or BAIL_OUT('no TKT-548 passage found in SKILLS.md');

# --- THE CARD -------------------------------------------------------------

unlike( $passage, qr/freshly-added item is not reported/,
    'the passage does not claim a freshly-added item goes unreported - that '
      . 'was true before TKT-606 and is false since 4.79' );

like( $passage, qr/\barriv(e|es|ing|al)\b/i,
    'and it says something about an item ARRIVING, which is what 4.79 added - '
      . 'said: ' . ( $passage || '(nothing)' ) );

like( $passage, qr/\b(remov|disappear|gone)/i,
    'and about one DISAPPEARING, the other half TKT-606 added' );

# --- THE CONTROL ------------------------------------------------------------
#
# The correction must not read as "it reports everything now". The
# first-pass-on-an-unpoliced-board silence is still true and is the whole
# reason TKT-606 took a decision rather than an else - a rule that dumped a
# hundred existing items at once would be declined and never re-enabled.

like( $passage, qr/first pass/i,
    'and it still describes the first-pass exemption, so the correction does '
      . 'not overcorrect into "task-changed reports every existing item"' );

# --- THE SAME FALSE CLAIM, A SECOND PLACE -----------------------------------
#
# Review found it: docs/POLICIES.md has TWO passages about task-changed, the
# accurate rules-table entry TKT-606 updated and a separate onboarding
# walkthrough it did not touch, still carrying the identical false sentence.
# One file, one document, the same fault in two places - so this checks every
# document that might state it, not only the one this card started from.

for my $doc (qw(SKILLS.md docs/POLICIES.md docs/commands.md README.md)) {
    my $text = do {
        local $/;
        open my $fh, '<:encoding(UTF-8)', $doc or die "Cannot read $doc: $!";
        <$fh>;
    };
    ok( $text, "$doc was read and has content to scan" )
      or BAIL_OUT("$doc came back empty, so the check below would be vacuous");
    unlike( $text, qr/freshly-added item is not reported/,
        "$doc does not carry the same false sentence, wherever in the file "
          . "it might appear" );
}

done_testing();

__END__

=head1 NAME

t/441-a-sentence-a-later-release-made-false.t - SKILLS.md must not describe a
rule's superseded behaviour as current

=head1 DESCRIPTION

C<task-changed>'s SKILLS.md passage said a freshly-added tasklist item is not
reported. TKT-606 (4.79) made that false: arrivals and removals are each
reported once. docs/POLICIES.md:381 was updated by that card and is accurate;
SKILLS.md was not touched and contradicted it.

The false sentence is precisely the belief that caused the owner to ask twice
why a new task was announced by nothing - an agent reading it would conclude
the silence was intentional and close the question wrongly.

=head2 What this file does not ask for

The first-pass-on-an-unpoliced-board silence is still correct behaviour and
still worth stating - a rule that announced a whole existing tasklist at once
would be declined and never re-enabled. The control here holds that sentence
in place rather than asking the correction to remove it.

=cut
