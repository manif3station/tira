#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'watched' );
my $tick = '2026-08-08T12:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Watched', dir => $root );
$tira->column_add( project => $root, type => 'ticket', name => 'doing', label => 'Doing' );
$tira->column_add( project => $root, type => 'ticket', name => 'review', label => 'Review' );

my %column = map { $_->{name} => $_ } @{ $tira->column_list( project => $root, type => 'ticket' ) };
ok( $column{doing}{watched}, 'a new column is watched without being configured' );
ok( !defined $column{doing}{notify_after}, 'and carries no limit of its own' );

my $updated = $tira->column_update(
    project => $root, type => 'ticket', name => 'doing', notify_after => 30,
);
is( $updated->{notify_after}, 30, 'a column takes its own limit in minutes' );
is( $tira->column_update( project => $root, type => 'ticket', name => 'review', watched => 0 )->{watched},
    0, 'and a column can be switched out of watching' );
%column = map { $_->{name} => $_ } @{ $tira->column_list( project => $root, type => 'ticket' ) };
is( $column{doing}{notify_after}, 30, 'the limit persists' );
is( $column{review}{watched}, 0, 'the watched flag persists' );
ok( $column{backlog}{watched}, 'other columns are untouched' );

for my $case (
    [ { notify_after => 0 },       qr/minutes/i, 'a zero limit' ],
    [ { notify_after => -5 },      qr/minutes/i, 'a negative limit' ],
    [ { notify_after => 'soon' },  qr/minutes/i, 'a non-numeric limit' ],
    [ { name => 'nosuch', watched => 0 }, qr/not found/i, 'an unknown column' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->column_update( project => $root, type => 'ticket', name => 'doing', %{$args} ) };
    like( $@, $error, "$label is refused" );
}
is( $tira->column_list( project => $root, type => 'ticket' )->[1]{notify_after}, 30,
    'a refused change leaves the stored limit alone' );

# Cards that have genuinely sat, so staleness is arithmetic not a race.
my $slow = $tira->create_record( project => $root, type => 'ticket', title => 'Sitting in doing' );
my $hidden = $tira->create_record( project => $root, type => 'ticket', title => 'Sitting in review' );
my $fresh = $tira->create_record( project => $root, type => 'ticket', title => 'Just arrived' );
$tick = '2026-08-08T12:05:00Z';
$tira->record_move( project => $root, ref => $slow->{ref}, column => 'doing' );
$tira->record_move( project => $root, ref => $hidden->{ref}, column => 'review' );
$tira->column_add( project => $root, type => 'ticket', name => 'checking', label => 'Checking' );
$tick = '2026-08-08T13:00:00Z';
$tira->record_move( project => $root, ref => $fresh->{ref}, column => 'checking' );

$tick = '2026-08-08T13:10:00Z';
my $stale = $tira->dwell_list( project => $root, stale => 1 );
is_deeply( [ map { $_->{ref} } @{$stale} ], [ $slow->{ref} ],
    'only the card past its own column limit is stale' );
is( $stale->[0]{notify_after}, 30, 'and the limit that judged it is reported' );

$tira->column_update( project => $root, type => 'ticket', name => 'review', watched => 1, notify_after => 1 );
my @refs = map { $_->{ref} } @{ $tira->dwell_list( project => $root, stale => 1 ) };
is( scalar @refs, 2, 'switching a column back on brings its cards into scope' );
$tira->column_update( project => $root, type => 'ticket', name => 'review', watched => 0 );
is_deeply( [ map { $_->{ref} } @{ $tira->dwell_list( project => $root, stale => 1 ) } ],
    [ $slow->{ref} ], 'an unwatched column is excluded however old its cards are' );

# The project-wide default covers columns that set no limit of their own.
is_deeply( $tira->dwell_list( project => $root, stale => 1, type => 'sow' ), [],
    'a board with no limits anywhere reports nothing stale' );
$tira->project_update( project => $root, notify_after => 2 );
is( $tira->project_show( project => $root )->{notify_after}, 2, 'the project default is stored' );
my @with_default = map { $_->{ref} } @{ $tira->dwell_list( project => $root, stale => 1 ) };
ok( scalar( grep { $_ eq $fresh->{ref} } @with_default ),
    'a card in a column with no limit of its own is judged by the project default' );
eval { $tira->project_update( project => $root, notify_after => 'later' ) };
like( $@, qr/minutes/i, 'an invalid project default is refused' );

sub run_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out, $err );
}

my ( $status, $out, $err ) = run_cli( 'column.update',
    '--project', $root, '--type', 'ticket', '--name', 'doing', '--notify-after', '45', '-o', 'json' );
is( $status, 0, 'the CLI sets a column limit' );
is( decode_json($out)->{notify_after}, 45, 'and reports it back' );

( $status, $out, $err ) = run_cli( 'column.update',
    '--project', $root, '--type', 'ticket', '--name', 'doing', '--no-watch', '-o', 'json' );
is( decode_json($out)->{watched}, 0, 'the CLI switches watching off' );
( $status, $out, $err ) = run_cli( 'column.update',
    '--project', $root, '--type', 'ticket', '--name', 'doing', '--watch', '-o', 'json' );
is( decode_json($out)->{watched}, 1, 'and back on' );

( $status, $out, $err ) = run_cli( 'stale', '--project', $root, '--stale', '-o', 'json' );
is( $status, 0, 'the stale command applies per-column limits' );
ok( scalar @{ decode_json($out) }, 'and finds the cards that are past them' );

( $status, $out, $err ) = run_cli( 'column.update',
    '--project', $root, '--type', 'ticket', '--name', 'doing', '--notify-after', 'soon', '-o', 'json' );
is( $status, 2, 'an invalid CLI limit exits 2' );

done_testing;

__END__

=head1 NAME

45-column-watch.t - per-column staleness limits and watching

=head1 DESCRIPTION

Proves that each column carries its own staleness limit in minutes and
its own watched flag, both stored on the board config beside the
column's name and order; that a column with no limit falls back to the
project default and, with neither, is never stale; that an unwatched
column is excluded however old its cards are; and that invalid values
are refused without changing what is stored.

=cut
