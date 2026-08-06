#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $now = '2026-08-06T21:00:00+0100';
my $tira = Tira->new( clock => sub { $now } );
my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'stamps' );
$tira->create_project( name => 'Stamp project', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->create_record( project => $root, type => 'ticket', title => 'Card' );

my $first = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', filename => 'early.txt', content => "early\n",
);
is( $first->{added_at}, '2026-08-06T21:00:00+0100', 'content uploads stamp their added time' );

$now = '2026-08-06T22:00:00+0100';
my $second = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', filename => 'late.txt', content => "late\n",
);
is( $second->{added_at}, '2026-08-06T22:00:00+0100', 'each upload keeps its own added time' );

$now = '2026-08-06T23:00:00+0100';
my $dedup = $tira->attachment_add_content(
    project => $root, ref => 'TKT-001', filename => 'early-again.txt', content => "early\n",
);
ok( $dedup->{deduped}, 'identical content dedups' );
is( $dedup->{added_at}, '2026-08-06T21:00:00+0100',
    'a deduplicated re-add retains the original added time' );

my $file = File::Spec->catfile( $tmp, 'path.txt' );
open my $fh, '>', $file or die $!;
print {$fh} "from path\n";
close $fh;
my $from_path = $tira->attachment_add( project => $root, ref => 'TKT-001', file => $file );
is( $from_path->{added_at}, '2026-08-06T23:00:00+0100', 'file-path adds stamp their added time too' );

my $listed = $tira->attachment_list( project => $root, ref => 'TKT-001' );
is( scalar( grep { defined $_->{added_at} } @{$listed} ), 3, 'every stored reference carries added_at' );

sub browser_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @calls ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, argv => \@argv, tira => $tira,
        browser_server => sub { push @calls, { @_ }; return 1 },
    );
    return ( $status, $out, $err, \@calls );
}

my ( $status, undef, undef, $calls ) =
  browser_cli( 'dashboard.ticket', '--project', $root, '--title', '-o', 'browser' );
is( $status, 0, 'browser dashboard starts' );
my $live_html = $calls->[0]{render}->();

like( $live_html, qr/card-composer-toggle/, 'the composer collapses behind a toggle' );
like( $live_html, qr/renderMarkdown/, 'comment bodies render through the markdown renderer' );
like( $live_html, qr/data-md/, 'the formatting bar tags its controls' );
like( $live_html, qr/\["bold","B"/, 'the formatting bar offers bold' );
like( $live_html, qr/\["list",/, 'the formatting bar offers bullet lists' );
like( $live_html, qr/added_at/, 'attachment chips consult the added time' );
unlike( $live_html, qr/innerHTML/, 'the renderer never assigns raw HTML' );

done_testing;

__END__

=head1 NAME

24-dashboard-comments-attachments.t - attachment timestamps and composer contract

=head1 DESCRIPTION

Guards added_at stamping (content and path adds, dedup retention, listing),
and the dialog contract for the collapsed markdown composer, formatting bar,
safe renderer, and timestamp-aware attachment chips.

=cut
