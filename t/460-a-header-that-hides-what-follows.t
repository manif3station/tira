#!/usr/bin/env perl
# TKT-788. TKT-780 made .hero position:sticky;top:0;z-index:5 - a real,
# opaque panel with non-negligible height. .column__head was already
# position:sticky;top:0;z-index:2 (an earlier ticket, covered by t/16).
# Both now anchor to the identical top:0 offset: as the page scrolls, a
# column header reaches the viewport top at exactly the point the opaque
# hero already occupies, and the hero's higher z-index paints over it -
# the column's name/count/accent border disappears behind the hero band
# during scroll instead of stacking visibly below it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'stacked' );
my $tira = Tira->new( clock => sub { '2026-08-31T12:00:00+0100' } );
$tira->create_project( name => 'Stacked project', dir => $root );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

my ( $status, $html ) = cli( 'dashboard', '-o', 'table' );
is( $status, 0, 'table dashboard succeeds' );

# Both rules still declare top - only its VALUE must now differ, not the
# property's presence, so both anchors are read out explicitly.
like( $html, qr/\.hero\{[^}]*top:0/,
    'the hero still pins to the very top of the viewport (TKT-780 unchanged)' );

# .column__head appears in three rules in this stylesheet (a discard-column
# color override, a fit-width static-position override, and this one, the
# sticky rule itself) - anchored on position:sticky so a plain substring
# search cannot grab the wrong one, the mistake this test itself made on
# its first draft.
my ($column_head_rule) = $html =~ /(\.column__head\{position:sticky[^}]*\})/;
ok( defined $column_head_rule, 'the sticky .column__head rule is found to read' );

unlike( $column_head_rule, qr/top:0(?![.\d])/,
    'a column header no longer anchors to the exact same top offset as the hero - '
      . 'if this is missing, the header stacks underneath the opaque hero band and disappears during scroll' );

like( $column_head_rule, qr/top:var\(--hero-h/,
    'the column header offsets by the same shared height variable the hero itself declares, '
      . 'so the two can never silently drift back to the same offset independently' );

like( $html, qr/\.hero\{[^}]*min-height:var\(--hero-h/,
    'the hero declares a minimum height from that same shared variable, so the offset it hands the column header is honest' );

# The static CSS value alone is not enough: a Codex review of this fix
# found the hero's real rendered height is fluid (a clamp()-sized h1,
# plus a mobile @media(max-width:720px) override that stacks its content
# vertically instead of side-by-side), so no single static rem value
# covers every viewport - a fixed --hero-h that "plausibly" covers one
# width still collides on another, exactly the failure mode this ticket
# was filed for in the first place. --hero-h is measured and overwritten
# at runtime from the hero's own actual offsetHeight, on load and on
# resize, so the offset column__head reads is always the truth rather
# than a guess. That JS lives in board-bindings.js; a static Perl test
# cannot execute a browser layout, so this only confirms the syncing
# code is present and wired up on both events - the pixel-level claim
# itself needs a live/Playwright check, which the verify gate for this
# card records separately.
open my $js, '<', 'lib/Tira/views/board-bindings.js' or die "Cannot read board-bindings.js: $!";
my $js_text = do { local $/; <$js> };
close $js;

like( $js_text, qr/document\.documentElement\.style\.setProperty\("--hero-h"/,
    'the hero height is measured and written back into the CSS variable at runtime, not left to one static guess' );
like( $js_text, qr/window\.addEventListener\("resize",\s*syncHeroHeight\)/,
    'and re-measured on resize, since the hero\'s real height changes with viewport width (the clamp() font and the mobile stacked layout)' );

done_testing;

__END__

=head1 NAME

t/460-a-header-that-hides-what-follows.t - a column header no longer
disappears behind the sticky hero band while scrolling

=head1 DESCRIPTION

TKT-780 made C<.hero> sticky at C<top:0>, but C<.column__head> (sticky
since an earlier ticket) already anchored to the same C<top:0> - so a
column header scrolling up slid underneath the opaque, higher-z-index
hero band and vanished instead of stopping visibly below it. Fixed with
a shared CSS custom property, C<--hero-h>: C<.hero> declares
C<min-height:var(--hero-h)> and C<.column__head> offsets by
C<top:var(--hero-h)>, so the two can never drift back to colliding
independently. A Codex review then found the static C<6.5rem> guess did
not actually cover the hero's real, fluid height on common desktop
widths or the mobile stacked layout - C<--hero-h> is now measured from
the hero's own C<offsetHeight> at runtime (on load and on resize) in
C<board-bindings.js>, rather than guessed once in CSS. TKT-788.

=cut
