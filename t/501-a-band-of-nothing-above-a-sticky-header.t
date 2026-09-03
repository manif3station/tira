#!/usr/bin/env perl
# The space above the board, and why most of it was never seen.
#
# TKT-855, his words: "Useless whitespace on top of dashboard." One of four
# dashboard-appearance cards filed in a single sitting.
#
# MEASURED BEFORE THIS FILE WAS WRITTEN:
#
#     .shell   padding: 3.5rem 0 5rem
#     .hero    margin:  0 0 2.5rem
#     .hero    position: sticky; top: 0
#
# The 3.5rem earns almost nothing, and the sticky rule is why: it sits ABOVE an
# element that pins itself to the viewport, so on first paint it is a band of
# empty background and once anybody scrolls it is gone. It is not breathing room
# around the header - the header has its own padding.
#
# IT IS NOT A NO-OP, THOUGH, and the first version of this file said it was.
# Review corrected it: the shell's top padding is part of the header's
# normal-flow position, so it also sets how far the page must scroll before the
# header pins. At 3.5rem the header stuck later; at 1rem it sticks sooner. On a
# board page that is a second reason to cut it - the header reaches its useful
# position earlier - but it is a different claim from "nobody sees it twice",
# and a number worth defending should be defended on both.
#
# WHY THAT IS WORTH A CARD, in his own words on it: vertical space above the
# columns comes directly off how many cards are visible without scrolling, which
# is the whole point of the view.
#
# WRITTEN RED against the values above.
#
# HOW AN APPEARANCE CARD IS TESTED WITHOUT A BROWSER, which he keeps: this does
# not assert the page looks better - nothing can. It asserts two numbers came
# down and that the things which are NOT dead space were left alone. Both are
# facts about the file.
#
# THE ASSERTIONS THAT KEEP THIS HONEST are the ones about what must NOT change.
# A test that only demanded smaller numbers would be satisfied by deleting the
# header's own padding too, which would be a worse page and a passing suite.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my $css = do {
    open my $fh, '<:raw', 'lib/Tira/views/dashboard.css' or die "dashboard.css: $!";
    local $/;
    <$fh>;
};

# non-empty is the whole claim: every assertion below reads a rule out of this
# text, and an unreadable file would fail them all for the wrong reason.
like( $css, qr/\S/, 'the stylesheet is there to be read' );

sub rule {
    my ($selector) = @_;
    my ($body) = $css =~ /\Q$selector\E\{([^}]*)\}/;
    return $body // '';
}

sub value {
    my ( $selector, $property ) = @_;
    my ($found) = rule($selector) =~ /(?:^|;)\s*\Q$property\E:\s*([^;]+)/;
    return $found // '';
}

# --- the premise, established first ------------------------------------------
#
# The whole argument is that the shell's top padding sits above a STICKY header.
# If the header were not sticky it would be ordinary spacing and this card would
# be a matter of taste. Asserted so the reasoning cannot rot silently: if
# somebody makes the header static later, this fails and the next reader is told
# why the number was chosen.

like( rule('.hero'), qr/position:\s*sticky/,
    'the header is sticky, which is what makes the space above it dead' );
like( rule('.hero'), qr/top:\s*0/,
    'and pinned to the very top, so nothing above it is ever seen after a scroll' );

# --- the two numbers this card is about --------------------------------------

my $shell = value( '.shell', 'padding' );
my ($shell_top) = $shell =~ /\A\s*([\d.]+)rem/;
ok( defined $shell_top, 'the shell states its padding in rem, so it can be compared' );
cmp_ok( $shell_top, '<', 3.5,
    'the clearance above the sticky header is less than the 3.5rem it was' );

my $hero = value( '.hero', 'margin' );
my ($hero_bottom) = $hero =~ /([\d.]+)rem\s*\z/;
ok( defined $hero_bottom, 'the header states its bottom margin in rem' );
cmp_ok( $hero_bottom, '<', 2.5,
    'and the gap below the header is less than the 2.5rem it was' );

# --- and what must NOT have been taken -------------------------------------
#
# The card's acceptance draws this line: remove the clearance, keep the
# breathing room. Without these, "make the numbers smaller" would be satisfied
# by stripping the header's own padding, which is a worse page and a green
# suite.

isnt( value( '.hero', 'padding' ), '',
    'the header keeps its own padding - the space removed is the clearance, not the content' );
like( rule('.hero--compact'), qr/padding:\s*\.4rem/,
    'and the compact state is untouched, since it is what the page collapses to on scroll' );

# The header's internal layout belongs to TKT-854, and when this file was
# written that card was parked awaiting his answer to Q-110 about which axis he
# meant - so this asserted align-items:end, pinning the value TKT-855 must not
# touch. TKT-854 has since landed: his screenshot answered it with two red lines
# and "make both sides align", and the value is now stretch.
#
# THE ASSERTION IS KEPT RATHER THAN DELETED, and only its expected value moved.
# What it guards is unchanged and is still worth guarding: a card about PADDING
# must not quietly alter how the two columns line up. Deleting it because the
# number changed would remove that guarantee for the next appearance card, which
# is how a suite loses the checks that were never about the number.
like( rule('.hero'), qr/align-items:\s*stretch/,
    'the header alignment is whatever TKT-854 settled on, and this card - which '
      . 'is about padding - did not move it' );

cmp_ok( $shell_top, '>', 0,
    'and the clearance is not zero - the sticky header has rounded bottom corners '
      . 'and would meet the viewport edge as a torn line on first paint' );

done_testing();

__END__

=head1 NAME

501-a-band-of-nothing-above-a-sticky-header.t - the space above the board

=head1 WHY

TKT-855. C<.shell> put 3.5rem of padding above a header that is
C<position: sticky; top: 0> - a band of empty background on first paint that
disappears on the first scroll and is never seen again. C<.hero> added 2.5rem
below it. Roughly 6rem before the first board on a page whose purpose is showing
cards.

=head1 THE PREMISE IS ASSERTED, NOT ASSUMED

That the header is sticky is what makes the space above it dead rather than
merely large. If somebody makes it static later, this file fails and says why
the number was chosen.

=head1 THE INTERESTING ASSERTIONS ARE THE NEGATIVE ONES

"Make the numbers smaller" would also be satisfied by deleting the header's own
padding, which is a worse page and a green suite. What must not change is
asserted alongside what must.

=cut
