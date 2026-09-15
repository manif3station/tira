#!/usr/bin/env perl

# TKT-755. lib/Tira.pm:11622's own condition is explicit that
# tira.police.freshness reports stale for THREE cases:
#
#     stale => ( !defined $at || !defined $age || $age > $POLICE_STALE_AFTER ) ? 1 : 0
#
#   - taken_at is null                    (never policed)
#   - taken_at is present, age is null    (a stored stamp that will not parse)
#   - age exceeds $POLICE_STALE_AFTER     (policed, but too long ago)
#
# docs/commands.md already documents all three - it is "the normative
# implemented interface" and was correct. SKILLS.md documented only the
# first and third; the second (the unreadable stamp) went unwritten,
# found the same session it was added to docs/commands.md, by whoever
# wrote both and left one behind.
#
# WHY THE SECOND CASE MATTERS MOST TO NAME: the other two are
# self-explanatory from their own fields alone - a null pass time, or an
# age past a documented threshold. The unreadable-stamp case is the only
# one that LOOKS CONTRADICTORY without the sentence: taken_at present,
# stale true, no age at all. A reader who has only read SKILLS.md meets
# that combination with no documented reason for it.
#
# SCOPE, deliberately narrow. This is not a general "prose in several
# documents must agree" guard, in the family of t/433's number check -
# that is real and is its own card if anyone wants it (recorded on this
# ticket's own key_details). This asserts only the three specific
# phrases this ticket's acceptance criteria name, the same way t/433 was
# once a single hand check before TKT-704 made it a walk.

use strict;
use warnings;

use Test::More;

my $skills = do {
    open my $fh, '<:encoding(UTF-8)', 'SKILLS.md' or die "SKILLS.md: $!";
    local $/;
    <$fh>;
};

my ($paragraph) = $skills =~
  /(d2 tira\.police\.freshness.*?TKT-684\.)/s;
ok( defined $paragraph, 'the police.freshness paragraph is found in SKILLS.md' );
$paragraph //= '';

like( $paragraph, qr/null pass time/,
    'SKILLS.md names the never-policed case (taken_at null)' );

# Not just "the phrase 'recent enough to trust' appears somewhere" - that
# would still pass if the sentence stopped meaning anything about staleness.
# Codex review found the first version of this assertion proved only that
# generic prose existed, not that it is coupled to `stale`. The real
# sentence puts "recent enough to trust" and the `stale` field in the same
# clause, so requiring them within a short span is what actually says this
# paragraph claims an over-threshold age is what makes the answer stale.
like( $paragraph, qr/recent enough to trust.{0,80}\bstale\b/is,
    'SKILLS.md couples "recent enough to trust" to the stale field itself, '
      . 'not merely mentioning both somewhere in the same paragraph' );

like( $paragraph, qr/UNREADABLE|will not parse|cannot be read/,
    'SKILLS.md now names the unreadable-stamp case too - confirmed genuinely '
      . 'red before this line was written (see this ticket\'s own tests-red '
      . 'proof: the same unlike() check failed until the sentence was added)' );

# --- and the fix agrees with docs/commands.md's OWN unreadable-stamp -------
# sentence, not merely a document that happens to contain the word ---------
# somewhere else - Codex review found the first version of this check ------
# compared nothing, it only confirmed the word's existence in a 4,000-line -
# file that was always going to contain it. --------------------------------

{
    my ($commands) = do {
        open my $fh, '<:encoding(UTF-8)', 'docs/commands.md' or die "docs/commands.md: $!";
        local $/;
        <$fh>;
    };

    my ($commands_sentence) =
      $commands =~ /(So is a pass time[^.]*\.[^.]*UNREADABLE[^.]*\.)/s;
    ok( defined $commands_sentence,
        "docs/commands.md's own unreadable-stamp sentence is found, to compare "
          . 'against rather than merely confirming the word exists somewhere' );
    $commands_sentence //= '';

    for my $fact (
        [ qr/stale.{0,20}true/i,      'stale is true' ],
        [ qr/no.{0,10}age.?seconds/i, 'no age_seconds' ],
        [ qr/UNREADABLE/,             'the word UNREADABLE' ],
    ) {
        my ( $pattern, $label ) = @{$fact};
        ok( ( $paragraph =~ $pattern ), "SKILLS.md's new sentence states $label" );
        ok( ( $commands_sentence =~ $pattern ),
            "docs/commands.md's sentence states $label too - the same coupling, "
              . 'not independently-true facts stated two different ways' );
    }
}

done_testing;

__END__

=head1 NAME

1100-a-third-way-nobody-named.t - SKILLS.md names all three ways police.freshness reports stale

=head1 WHY

TKT-755. lib/Tira.pm's own condition has three branches; docs/commands.md
documents all three; SKILLS.md documented two. The missing one is the case
a reader would actually be confused by - a pass time present, and stale
true anyway, with nothing read explaining why.

=head1 WHAT IS ASSERTED

SKILLS.md's police.freshness paragraph names the never-policed case and
the too-old case (both already there), and - once this ticket's fix
lands - the unreadable-stamp case too, in wording that names UNREADABLE
the same way docs/commands.md already does.

=head1 WHAT IS NOT ASSERTED

That every fact stated in more than one document is held to a general
"they must all agree" guard - t/433's own doc-vs-code count check is the
existing example of that being worth doing, and a version of it for a
described BEHAVIOUR rather than a number is real future work, recorded on
this ticket rather than invented here.

=cut
