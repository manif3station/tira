#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

{
    package DashboardCountingTira;
    use parent 'Tira';
    sub _read_json {
        my ( $self, @args ) = @_;
        $self->{json_reads}++;
        return $self->SUPER::_read_json(@args);
    }
}

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'dashboard' );
my $writer = Tira->new( clock => sub { '2026-08-06T12:00:00+0100' } );
$writer->create_project( name => 'Fast dashboard', dir => $root );
my $first = $writer->create_record( project => $root, type => 'ticket', title => 'First title' );
my $second = $writer->create_record( project => $root, type => 'ticket', title => 'Second title' );
my $third = $writer->create_record( project => $root, type => 'ticket', title => 'Newest title' );
my $column = File::Spec->catdir( $root, '.tira', 'ticket', 'backlog' );
utime 100, 100, File::Spec->catfile( $column, "$first->{ref}.json" );
utime 100, 100, File::Spec->catfile( $column, "$second->{ref}.json" );
utime 200, 200, File::Spec->catfile( $column, "$third->{ref}.json" );
open my $noise, '>', File::Spec->catfile( $column, 'not-a-card.json' ) or die $!;
print {$noise} '{}';
close $noise;

my $tira = DashboardCountingTira->new;
my $fast = $tira->dashboard( project => $root, type => 'ticket', summary => 1 );
is( $tira->{json_reads} // 0, 0, 'ref-only dashboard performs no JSON reads' );
is_deeply( [ map { $_->{ref} } @{ $fast->{ticket}{backlog} } ],
    [ $third->{ref}, $first->{ref}, $second->{ref} ],
    'dashboard sorts newest mtime first and breaks ties by ref' );
is_deeply( [ sort keys %{ $fast->{ticket}{backlog}[0] } ], ['ref'],
    'default dashboard cards contain only refs' );

$tira->{json_reads} = 0;
my $titled = $tira->dashboard( project => $root, type => 'ticket', summary => 1, with_title => 1 );
is( $tira->{json_reads}, 3, 'title dashboard reads each valid card exactly once' );
is_deeply( [ map { $_->{title} } @{ $titled->{ticket}{backlog} } ],
    [ 'Newest title', 'First title', 'Second title' ], 'title mode preserves mtime ordering' );

unlink File::Spec->catfile( $column, 'not-a-card.json' ) or die $!;
$tira->{json_reads} = 0;
my $full = $tira->dashboard( project => $root, type => 'ticket' );
is( $tira->{json_reads}, 3, 'full JSON-compatible dashboard retains board scan behavior' );
ok( exists $full->{ticket}{backlog}[0]{description}, 'full dashboard retains complete records' );
is( $full->{ticket}{backlog}[0]{ref}, $third->{ref}, 'full dashboard uses the same newest-first order' );

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => 'dashboard', argv => \@argv, tira => DashboardCountingTira->new );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = cli( '--project', $root, '--type', 'ticket', '-o', 'human' );
is( $status, 0, 'default human dashboard succeeds' );
like( $out, qr/`\Q$third->{ref}\E`/, 'default human dashboard shows refs' );
unlike( $out, qr/Newest title/, 'default human dashboard omits titles' );
is( $err, '', 'default human dashboard has no warnings' );

( $status, $out, $err ) = cli( '--project', $root, '--type', 'ticket', '--title', '-o', 'human' );
like( $out, qr/`\Q$third->{ref}\E` Newest title/, 'title flag adds titles to human dashboard' );
is( $err, '', 'title human dashboard has no warnings' );

( $status, $out, $err ) = cli( '--project', $root, '--type', 'ticket', '-o', 'json' );
ok( exists decode_json($out)->{ticket}{backlog}[0]{description}, 'JSON output remains the full dashboard' );

done_testing;

__END__

=head1 NAME

15-dashboard-fast.t - Fast ref-only and titled Tira dashboard behavior

=head1 DESCRIPTION

Proves metadata-free default dashboard reads, filesystem mtime ordering,
optional title reads, stable ties, valid filename filtering, and full JSON
compatibility for DD-402.

=cut
