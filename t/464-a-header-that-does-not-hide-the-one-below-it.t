#!/usr/bin/env perl
# TKT-788. Follow-up to TKT-780: .hero and .column__head are both
# position:sticky at top:0, so once the page scrolls past the hero's
# height, both stick to the same point on the viewport. .hero has the
# higher z-index (5 vs 2), so it paints over .column__head - a column
# header scrolling up disappears behind the hero band instead of
# remaining visible.
#
# Two earlier attempts moved .column__head's own top offset to
# var(--hero-h) instead, and both broke real pointer interactions in
# dashboard-table.js/dashboard-browser.js (confirmed via a controlled
# A/B test - see TKT-788's own comment history). Hypothesis: .board__scroll
# {overflow-x:auto} makes .board__scroll (rather than the viewport) the
# sticky positioning containing block for .column__head, per the
# well-known CSS Overflow spec quirk that overflow-x:auto without an
# explicit overflow-y forces the computed overflow-y away from
# 'visible' too - so a nonzero top offset resolves against the wrong
# box. This fix avoids that landmine entirely: both rules keep top:0
# exactly as shipped, and only .column__head's z-index moves above
# .hero's, so it paints on top instead of hiding underneath - zero
# geometry change, so it cannot recreate the interaction regression.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'sticky-collision' );
my $tira = Tira->new( clock => sub { '2026-09-01T04:00:00+0100' } );
$tira->create_project( name => 'Sticky collision project', dir => $root );

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

like( $html, qr/\.hero\{[^}]*position:sticky/, '.hero is still sticky, unchanged by this fix' );
like( $html, qr/\.hero\{[^}]*top:0/, '.hero still pins to top:0, unchanged by this fix' );
like( $html, qr/\.column__head\{[^}]*position:sticky/, '.column__head is still sticky, unchanged by this fix' );
like( $html, qr/\.column__head\{[^}]*top:0/,
    ".column__head still pins to top:0 - the earlier top-offset fix broke real pointer "
      . 'interactions twice, so this fix does not touch it' );

my ($hero_block)   = $html =~ /(\.hero\{[^}]*\})/;
my ($column_block) = $html =~ /(\.column__head\{position:sticky[^}]*\})/;
ok( $hero_block,   'found the sticky .hero rule to read its z-index' );
ok( $column_block, 'found the sticky .column__head rule to read its z-index' );

my ($hero_z)   = $hero_block   =~ /z-index:(\d+)/;
my ($column_z) = $column_block =~ /z-index:(\d+)/;
ok( defined $hero_z,   '.hero declares a z-index' );
ok( defined $column_z, '.column__head declares a z-index' );
cmp_ok( $column_z, '>', $hero_z,
    ".column__head's z-index ($column_z) must be strictly above .hero's ($hero_z) - "
      . 'otherwise the header stays hidden behind the sticky hero band during scroll, '
      . 'the exact bug this card fixes' );

done_testing;

__END__

=head1 NAME

t/464-a-header-that-does-not-hide-the-one-below-it.t - a column header
scrolling up stays visible, painted above the sticky hero band rather
than hidden behind it

=head1 DESCRIPTION

C<.hero> and C<.column__head> are both C<position:sticky;top:0>, so once
scrolled past the hero's height they compete for the same point on the
viewport - and with C<.hero>'s higher z-index, it painted over the
column header, hiding it. TKT-788.

Two earlier fixes shifted C<.column__head>'s own C<top> offset instead
and both broke real pointer interactions in the Playwright interaction
suite (dashboard-table.js/dashboard-browser.js), confirmed via a
controlled A/B test. This fix does not touch either rule's C<top> or
C<position> at all - only C<.column__head>'s C<z-index> moves above
C<.hero>'s, so it paints on top instead of underneath. Zero geometry
change, so it cannot reproduce the interaction regression the earlier
attempts caused.

=cut
