#!/usr/bin/env perl
# The header's two columns, and the two edges he drew.
#
# TKT-854, his words on the card: "Page header project title on the left not
# align to the right side." He attached a screenshot on 2026-09-02 at 15:10 and
# I asked him which edge he meant before opening it. His reply, Q-110: "This
# question is because you didn't check on the screenshot picture or you still
# not understand after looked at the screenshot?"
#
# THE SCREENSHOT ANSWERS IT, and it was read before this file was written.
# 1012x163, with TWO red lines drawn on it: one across the TOP of the left block,
# above "TIRA KANBAN - FILESYSTEM-NATIVE FLOW", sloping down to the right-hand
# text; one from the bottom of the "Tira Development" h1 sloping up to the
# right-hand block. Between them, in red: "make both sides align".
#
# So it is BOTH edges. Not a choice between them, which is what Q-110 wrongly
# offered him.
#
# MEASURED BEFORE THIS FILE WAS WRITTEN:
#
#     .hero         display:flex; align-items:end; justify-content:space-between
#     .hero__aside  display:grid; justify-items:end; gap:.7rem
#     .hero h1      margin:.35rem 0 0; font-size:clamp(2.2rem,6vw,4.8rem)
#
# WHY align-items:end DOES NOT ALREADY DO IT. It aligns the two columns' BOXES
# at the bottom, and the left box is far taller than its text - a clamp() size up
# to 4.8rem with line-height 1.15 puts leading below the baseline. So the boxes
# meet at the bottom while the text does not, and nothing at all lines up at the
# top, because the left column is simply taller. Two edges wrong, one rule.
#
# WHAT STRETCH DOES INSTEAD. Both columns take the full height of the taller one,
# and the right column distributes its own rows from top to bottom - so its first
# line reaches the top edge and its last reaches the bottom. That is the shape his
# two lines describe.
#
# WRITTEN RED against the values above.
#
# HOW AN APPEARANCE CARD IS TESTED WITHOUT A BROWSER, which he keeps: this does
# not assert the header looks right - nothing here can. It asserts the two rules
# that decide the vertical relationship changed, and that everything which is NOT
# about that relationship was left alone. Both are facts about the file, and he
# confirms the rest by eye.
#
# THE ASSERTIONS THAT KEEP THIS HONEST are the ones about what must NOT change. A
# test demanding only "align-items is not end" would be satisfied by deleting the
# rule, by dropping justify-content and collapsing the two columns together, or by
# breaking the narrow-viewport override - each a worse page and a passing suite.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;

my $css = Suite::view_source('dashboard.css');

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
# Both rules must be findable before anything is claimed about them, or a
# renamed selector would make every assertion below pass against nothing.

isnt( rule('.hero'), '', 'the hero rule can be read' );
isnt( rule('.hero__aside'), '', 'the aside rule can be read' );

# --- the two columns share a vertical extent ---------------------------------

is( value( '.hero', 'align-items' ), 'stretch',
    'the header stretches its two columns to one height, so there is a top '
      . 'edge and a bottom edge for them to share' );

isnt( value( '.hero', 'align-items' ), 'end',
    'and no longer aligns only their box bottoms, which left the top edge '
      . 'unaddressed and the bottom edge only boxes-deep' );

# --- and the right column reaches both of them -------------------------------
#
# align-content, not justify-content: the aside is display:grid, so the block
# axis is the align- one. justify-content there would move the columns
# sideways and change nothing about the edges he drew.

is( value( '.hero__aside', 'align-content' ), 'space-between',
    'the right column spreads its rows top to bottom, so its first line '
      . 'reaches the top edge and its last reaches the bottom' );

# --- what must NOT change ----------------------------------------------------
#
# Each of these would be a way to satisfy the assertions above while making the
# header worse.

is( value( '.hero', 'justify-content' ), 'space-between',
    'the two columns are still pushed to opposite sides - the horizontal '
      . 'split is not what he asked about' );

is( value( '.hero', 'display' ), 'flex', 'the header is still a flex row' );

is( value( '.hero__aside', 'justify-items' ), 'end',
    'and the right column still right-aligns its own text, which is the edge '
      . 'his title was being compared against' );

is( value( '.hero__aside', 'display' ), 'grid', 'the aside is still a grid' );

# space-between distributes only the space LEFT OVER after the rows, so a gap
# that had been deleted would not read as tidier - it would read as the rows
# flying to the far ends of a stretched column. The exact length is the
# designer's: non-empty is the whole claim.
like( value( '.hero__aside', 'gap' ), qr/\S/,
    'and still has a gap between its rows' );

# The sticky header is TKT-855's work and is nothing to do with alignment.
is( value( '.hero', 'position' ), 'sticky',
    'the header still pins itself to the viewport - TKT-855, untouched here' );

# --- and the narrow viewport is left alone -----------------------------------
#
# Under 720px the hero becomes display:block and the aside left-aligns, which is
# a different layout entirely: align-items does nothing to a block box. Asserted
# because a careless fix would "simplify" the override away and break the phone.

like( $css, qr/\@media\(max-width:720px\)/,
    'the narrow-viewport block is still there' );

my ($narrow) = $css =~ /\@media\(max-width:720px\)\{(.*)$/s;
$narrow //= '';
like( $narrow, qr/\.hero\{display:block\}/,
    'and still stacks the header on a phone, where stretching two columns to '
      . 'one height would mean nothing' );
like( $narrow, qr/\.hero__aside\{justify-items:start/,
    'and still left-aligns the aside there, since there is no right-hand '
      . 'column to line up with once they are stacked' );

done_testing();

__END__

=head1 NAME

504-two-sides-that-never-met.t - the header's two columns, and both edges

=head1 WHY

TKT-854. His screenshot carries two red lines - one along the top edges, one
along the bottom - and the words "make both sides align". The header was
C<align-items:end>, which meets the columns' boxes at the bottom only, and the
left box is much taller than its text because of the h1's C<clamp()> size and
leading. So neither edge lined up.

=head1 WHAT IS ASSERTED, AND WHAT IS NOT

Not that the header looks right; nothing here can say that, and the browser
checks are his. What is asserted is that the two rules deciding the vertical
relationship changed - C<align-items:stretch> on the header, C<align-content:
space-between> on the right column - and that everything not about that
relationship was left alone: the horizontal split, the right-alignment of the
aside's own text, the sticky header from TKT-855, and the whole narrow-viewport
override where the columns are stacked and none of this applies.

=head1 THE LESSON THIS FILE CARRIES

The requirement was in an attachment, not in the card's text. It sat there for
four hours while I asked him which edge he meant. An entry-gate audit that walks
every FIELD and never asks whether anything is ATTACHED will do that again.

=cut
