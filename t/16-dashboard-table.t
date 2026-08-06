#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'table' );
my $tira = Tira->new( clock => sub { '2026-08-06T13:10:00+0100' } );
$tira->create_project( name => 'Table project', dir => $root );
$tira->column_add( project => $root, type => 'ticket', name => 'in-progress', before => 'discard' );
$tira->create_record( project => $root, type => 'sow', title => 'Strategy' );
$tira->create_record( project => $root, type => 'epic', title => 'Experience' );
$tira->create_record( project => $root, type => 'ticket', title => '<script>alert("x")</script>' );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

my ( $status, $html, $err ) = cli( 'dashboard', '--project', $root, '--title', '-o', 'table' );
is( $status, 0, 'combined table dashboard succeeds' );
is( $err, '', 'combined table dashboard has no stderr' );
like( $html, qr/\A<!doctype html>/i, 'table output is a raw HTML document' );
like( $html, qr/<style>.*linear-gradient/s, 'table embeds a styled gradient surface' );
like( $html, qr/<script>.*addEventListener/s, 'table embeds local interaction JavaScript' );
like( $html, qr/data-sort="mtime".*data-sort="ref"/s, 'table provides mtime and ref sorting controls' );
is( scalar( () = $html =~ /class="board board--/g ), 3, 'combined dashboard stacks three type boards' );
like( $html, qr/data-type="sow".*data-type="epic".*data-type="ticket"/s,
    'combined dashboard preserves SOW, epic, ticket vertical order' );
like( $html, qr/<th[^>]*>backlog<\/th>.*<th[^>]*>in-progress<\/th>/s,
    'ticket columns render left to right' );
like( $html, qr/&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt;/,
    'record titles are HTML escaped' );
unlike( $html, qr/<script>alert/, 'record data cannot inject executable HTML' );
unlike( $html, qr/<(?:link|img|iframe)\b|https?:\/\//i, 'table has no external resources' );

( $status, $html, $err ) = cli( 'dashboard.ticket', '--project', $root, '-o', 'table' );
is( $status, 0, 'type-specific table dashboard succeeds' );
is( scalar( () = $html =~ /class="board board--/g ), 1, 'type-specific command renders one board' );
like( $html, qr/data-type="ticket"/, 'ticket command renders ticket board' );
unlike( $html, qr/data-type="(?:sow|epic)"/, 'ticket command excludes other boards' );
like( $html, qr/data-mtime="\d+"/, 'table embeds filesystem mtime for local sorting' );
unlike( $html, qr/<span class="card__title">/, 'table remains ref-only without title flag' );

( $status, my $out, $err ) = cli( 'project.show', '--project', $root, '-o', 'table' );
is( $status, 2, 'table output is rejected outside dashboard commands' );
is( $out, '', 'rejected table output emits no stdout' );
like( $err, qr/Table output is available only for dashboard commands/,
    'rejection explains the table scope' );
eval { $tira->format_output( { unrelated => 1 }, output => 'table' ) };
like( $@, qr/Table output requires dashboard data/, 'renderer rejects non-dashboard data directly' );

done_testing;

__END__

=head1 NAME

16-dashboard-table.t - Self-contained Tira Kanban table output

=head1 DESCRIPTION

Guards combined and type-specific raw HTML rendering, board/column order,
embedded styling and interaction, escaping, offline behavior, and output scope
for DD-403.

=cut
