#!/usr/bin/env perl
# TKT-797. Follow-up on TKT-780's sticky header: once the header stays put
# while scrolling, it should also shrink once the reader has actually
# scrolled - leaving more room for cards on a narrow (mobile) screen while
# staying present - and it should carry a live count of how many cards
# still have a question awaiting an answer, and how many tasklist items
# are outstanding, so both stay visible no matter how far down the board
# a reader has scrolled.
#
# TKT-788's history is the reason this does not touch .column__head at
# all: two earlier attempts at a DIFFERENT header collision broke real
# pointer interactions by shifting a sticky element's own geometry. This
# card only changes .hero's own padding/font-size on a class toggle - it
# never moves .column__head, so it should not be able to reproduce that
# regression, but the same real interaction tests (dashboard-table.js,
# dashboard-browser.js) confirm it via tools/browser-tests.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'hero-counts' );
my $tira = Tira->new( clock => sub { '2026-09-01T12:00:00+0100' } );
$tira->create_project( name => 'Hero counts project', dir => $root );

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

# --- the header shrinks on scroll, without touching the column header -------

like( $html, qr/\.hero\{[^}]*transition:padding/,
    'the header itself transitions smoothly rather than jumping' );
like( $html, qr/\.hero\.hero--compact\{[^}]*padding:/,
    'a compact state exists that shrinks the header\'s own padding' );
like( $html, qr/\.hero\.hero--compact h1\{[^}]*font-size:/,
    "and shrinks the header's title text too" );
unlike( $html, qr/\.column__head\.column__head--compact|\.column__head\{[^}]*top:var\(--hero-h\)/,
    'this fix does not touch .column__head at all - TKT-788 already broke real '
      . 'pointer interactions twice trying that' );

like( $html, qr/heroEl\.classList\.toggle\("hero--compact"/,
    'a scroll listener toggles the compact class on .hero itself' );
like( $html, qr/window\.addEventListener\("scroll"/,
    'the toggle is driven by a real scroll listener' );

# --- a live count of outstanding questions and tasks -------------------------

like( $html, qr/class="hero__counts"/, 'the header carries a counts element' );
like( $html, qr/querySelectorAll\("\.card--waiting"\)\.length/,
    'the question count is read from the same marker the existing '
      . 'Questions-to-answer toggle already uses, not a fresh source' );
like( $html, qr{fetch\("/tasklist"}, 'the task count is read from the existing tasklist endpoint' );
like( $html, qr/MutationObserver/,
    'the question count updates when cards change, not only once at load' );
like( $html, qr/setInterval\(refreshTaskTotal/,
    'the task count refreshes periodically, not only once at load' );

done_testing();

__END__

=head1 NAME

t/466-a-header-that-makes-room-for-cards.t - the sticky header shrinks on
scroll and shows how many questions and tasks are outstanding

=head1 DESCRIPTION

Follow-up on TKT-780's sticky header, TKT-797: once the header stays put
while scrolling, shrink it once the reader has actually scrolled - so a
narrow (mobile) screen keeps more room for cards while the header stays
present - and show a live count of cards with an unanswered question
(read from the C<.card--waiting> marker the existing Questions-to-answer
toggle already relies on, not a new source) plus a live count of
outstanding tasklist items (read from the existing C</tasklist> route),
so both stay visible regardless of scroll position.

Deliberately does not touch C<.column__head> at all: TKT-788 spent two
attempts learning that shifting a sticky element's own geometry can
intercept real pointer events, so this fix only toggles C<.hero>'s own
padding/font-size via a class, verified for real via
C<tools/browser-tests>' existing C<dashboard-table.js>/
C<dashboard-browser.js> interaction tests rather than a numeric check
alone.

=cut
