#!/usr/bin/env perl
# TKT-814. .hero h1's line-height:.9, combined with the gradient text fill
# (-webkit-background-clip:text;color:transparent), leaves descenders (the
# tail of a g, j, p, q, y) unpainted: the gradient background used to fill
# the glyph is sized to the line-box, and a line-height under 1 makes that
# box shorter than the font's actual glyph extent, so the descender pixels
# get no fill at all. Confirmed live: a standalone Playwright render of the
# real dashboard.css against the real header markup showed the two 'g's in
# "Budgeting" losing their bottom loop; raising line-height to 1.15 in the
# same render restored both with no other visible change. Owner report via
# Telegram photo msg 6359.

use strict;
use warnings;

use Test::More;

open my $css, '<', 'lib/Tira/views/dashboard.css' or die "Cannot read dashboard.css: $!";
my $text = do { local $/; <$css> };
close $css;

my ($hero_h1) = $text =~ /\.hero h1\{([^}]*)\}/;
ok( defined $hero_h1, 'the .hero h1 rule exists at all' );

my ($line_height) = $hero_h1 =~ /line-height:([0-9.]+)/;
ok( defined $line_height, '.hero h1 declares a line-height' );

cmp_ok( $line_height, '>=', 1.1,
    '.hero h1\'s line-height leaves headroom for descenders - below 1.1, a live '
      . 'render of the real CSS against the real header markup shows the tail of '
      . 'a g, j, p, q, or y losing its gradient fill entirely, not just visually '
      . 'tight spacing' );

done_testing;

__END__

=head1 NAME

t/469-a-title-that-loses-its-tail.t - the header title's gradient text fill
does not swallow descenders

=head1 DESCRIPTION

C<.hero h1> renders the board title as gradient text via
C<-webkit-background-clip:text;color:transparent>. That gradient is painted
over the element's line-box, and a C<line-height> under 1 makes that box
shorter than the font's real glyph extent - so a descender (the tail of a g,
j, p, q, or y) falls outside the painted area and gets no fill at all. It is
not a spacing problem; the pixels are unpainted, not just cramped.

Confirmed with a direct reproduction rather than a guess from reading the
CSS: a standalone page loading the real F<dashboard.css> against the real
header markup, rendered with Playwright. At C<line-height:.9> both g's in
"Budgeting" lost their bottom loop; raising it to C<1.15> in the same
render restored them fully with no other visible change. Owner report via
Telegram photo msg 6359. TKT-814.

=cut
