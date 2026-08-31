#!/usr/bin/env perl
# TKT-780. The dashboard's top header (.hero - title, Refresh control,
# Last-updated timestamp) scrolls out of view along with the rest of the
# page content. On a board with many columns/cards, scrolling down to see
# cards loses the header entirely, including the Refresh button and
# freshness indicator that are useful to see while looking at cards
# further down the page. Owner request, via Telegram.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'sticky' );
my $tira = Tira->new( clock => sub { '2026-08-31T12:00:00+0100' } );
$tira->create_project( name => 'Sticky project', dir => $root );

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
like( $html, qr/\.hero\{[^}]*position:sticky/,
    'the header (.hero) is sticky, so scrolling the board keeps it in view - '
      . 'if this is missing, the header still scrolls away with the rest of the page' );
like( $html, qr/\.hero\{[^}]*top:0/,
    'the sticky header pins to the top of the viewport, not some other offset' );

done_testing;

__END__

=head1 NAME

t/454-a-header-that-scrolls-away.t - the dashboard's top header stays
visible while scrolling the board

=head1 DESCRIPTION

The dashboard's C<.hero> header (title, Refresh control, Last-updated
timestamp) scrolled away with the rest of the page on a board with
enough cards to need scrolling, taking the freshness indicator and
refresh control out of view along with it. Fixed by making C<.hero>
sticky to the top of the viewport. Owner request, via Telegram. TKT-780.

=cut
