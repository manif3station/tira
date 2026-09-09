#!/usr/bin/env perl
# lib/Tira.pm's line count is stated in three places, all three disagree,
# and nothing checks any of them.
#
# The same shape t/433 already solved for the police rule count: one guard
# measures the real value and holds every live claim of it to that value,
# rather than a hand-corrected number that drifts again on the next release
# that touches the file - which is most of them.
#
# THIS DOES NOT CHECK EVERY MENTION OF A LINE COUNT NEAR "lib/Tira.pm" -
# only a present-tense claim about the file's CURRENT size ("is N lines").
# Two of the three original claims are deliberately not that:
#
#   README.md:763    "lib/Tira.pm` was 15,264 lines" - past tense, narrating
#                     the 5.23 split's own starting point. Correct as
#                     history, the same reason t/433 exempts a fenced
#                     transcript - a number in a past-tense sentence records
#                     what was true when it was written, not what is true now.
#   TKT-746's title   "Tira.pm is 14,621 lines" - present tense on its face,
#                     but the card is done: its title is a record of the
#                     board's own state on 2026-09-03, not a live claim.
#                     Decided rather than silently left inconsistent (CHK-004):
#                     excluded, and this paragraph is the decision.
#
# EVERYTHING ELSE IS A LIVE CLAIM AND IS HELD TO THE ENGINE - not only
# SKILLS.md's "is N,NNN lines after four lifts". README.md carries a SECOND
# claim beside its historical one, "`lib/Tira.pm` is\nN,NNN lines so far" -
# missed by this file's own first draft, which matched line-by-line and
# never saw a sentence an ordinary markdown reflow had wrapped across two of
# them. Caught by Codex review, fixed by joining a paragraph before
# matching rather than by naming the file as a second exception.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Find ();
use Test::More;

# t/486 marker: about this file, not its code - the claim under test is
# literally THIS file's own line count, not any behaviour lib/Tira.pm
# implements, the same exception t/426/t/344 already have for the same
# reason.
my $real_lines = do {
    open my $fh, '<', 'lib/Tira.pm' or die "lib/Tira.pm: $!";
    my $n = 0;
    $n++ while <$fh>;
    close $fh;
    $n;
};
cmp_ok( $real_lines, '>', 1000, "lib/Tira.pm was measured - $real_lines lines" );

# --- what counts as a live claim --------------------------------------------
#
# A number (comma-grouped or not) directly ahead of "lines", with "is" doing
# the verb work within the same short run of words - "is N lines", "is now
# N lines", not "was N lines" and not a bare "N lines" inside a comparison
# ("down from N lines"). Matching the shape rather than one exact sentence,
# same reasoning t/433 gives for its own wider match.
#
# CODEX REVIEW: a line-by-line match missed README.md's own claim, which
# wraps "lib/Tira.pm` is" onto one line and "14,164 lines" onto the next -
# an ordinary markdown paragraph reflow, not a fence or a list. Paragraphs
# are joined with a single space before matching (a blank line, a fence, or
# a list marker starts a new paragraph and is not joined across), and the
# reported line is wherever the paragraph's OWN first line started - close
# enough to find the sentence, since paragraphs in this suite's docs run a
# few lines at most.

sub _live_claims_in {
    my ($text) = @_;
    my ( @claims, $fenced, @paragraph, $paragraph_start );

    my $flush = sub {
        return if !@paragraph;
        my $joined = join ' ', @paragraph;
        while ( $joined =~ /\blib\/Tira\.pm\b.{0,20}?\bis\b(?:\s+now)?\s+([\d,]+)\s+lines\b/g ) {
            push @claims, { line => $paragraph_start, claimed => $1 };
        }
        @paragraph = ();
    };

    my $line_number = 0;
    for my $line ( split /\n/, $text, -1 ) {
        $line_number++;
        if ( $line =~ /^ {0,3}(?:```|~~~)/ ) { $flush->(); $fenced = !$fenced; next }
        if ($fenced)                         { next }
        if ( $line !~ /\S/ )                 { $flush->(); next }
        if ( $line =~ /^ {0,3}(?:[-*+]|\d+[.)])\s/ ) { $flush->() }
        push @paragraph, $line;
        $paragraph_start = $line_number if @paragraph == 1;
    }
    $flush->();
    return \@claims;
}

# The control: a past-tense claim, a comparison, a claim wrapped across two
# lines (the shape README.md's own real claim turned out to have - missed by
# the first, line-by-line draft, caught by Codex review), and a live one -
# exactly the two live ones are found.
my $fixture = <<'FIXTURE';
lib/Tira.pm was 15,264 lines before the first lift.

lib/Tira.pm is 14,164 lines after four lifts, down from 15,264.

`lib/Tira.pm` is
14,164 lines so far, measured at the fourth lift.
FIXTURE

is_deeply( [ map { $_->{claimed} } @{ _live_claims_in($fixture) } ], [ '14,164', '14,164' ],
    'both present-tense "is N lines" claims are found - the ordinary one and '
      . 'the one wrapped across two lines by a paragraph reflow - and neither '
      . 'the past-tense claim nor the "down from" comparison is' );

# --- every document that might carry a live claim ---------------------------

my @documents;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return if !/\.md\z/;
            return if $File::Find::name =~ m{/(?:cover_db|node_modules|\.git)/};
            push @documents, $File::Find::name;
        },
    },
    '.'
);
cmp_ok( scalar @documents, '>=', 3, 'the documents were walked' );

my @claims;
for my $document ( sort @documents ) {
    open my $fh, '<', $document or die "$document: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    push @claims, map { { %{$_}, document => $document } } @{ _live_claims_in($text) };
}

cmp_ok( scalar @claims, '>=', 1,
    'at least one live claim exists - '
      . join( ', ', map { "$_->{document}:$_->{line} says $_->{claimed}" } @claims ) );

( my $real_formatted = reverse $real_lines ) =~ s/(\d{3})(?=\d)/$1,/g;
$real_formatted = reverse $real_formatted;

for my $claim (@claims) {
    is( $claim->{claimed}, $real_formatted,
        "$claim->{document}:$claim->{line} - 'is $claim->{claimed} lines' "
          . "matches the real, measured count ($real_formatted)" );
}

done_testing();

__END__

=head1 NAME

t/876-a-count-that-outgrew-its-own-claim.t - every live claim of lib/Tira.pm's line count matches the real one

=head1 WHY

TKT-876, self-found: lib/Tira.pm's line count is stated in three places
(README.md, SKILLS.md, TKT-746's own title), all three disagree with each
other and with the real, current count, and nothing checked any of them.
Modeled directly on t/433's own police-rule-count guard.

=head1 WHAT IS ASSERTED

Every present-tense "lib/Tira.pm is N lines" claim, in any markdown
document, matches the file's real, measured line count.

=head1 WHAT IS NOT ASSERTED

A past-tense claim narrating history (README.md's own "was 15,264 lines,"
correct as a record of the 5.23 split's starting point) or a done ticket's
own title (TKT-746's "is 14,621 lines," a record of the board's state on
2026-09-03) - both are historical record, not live claims, the same
reasoning t/433 gives for exempting a fenced transcript.

=cut
