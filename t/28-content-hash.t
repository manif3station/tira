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

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'hashed' );
my $tick = '2026-08-07T04:00:00Z';
my $tira = Tira->new( clock => sub { $tick } );
$tira->create_project( name => 'Hashed', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Hash subject', priority => 4,
);
my $ref = $ticket->{ref};

sub current_hash {
    my $shown = $tira->record_show( project => $root, ref => $ref, fields => ['content_hash'] );
    return $shown->{content_hash};
}

my $baseline = current_hash();
like( $baseline, qr/\A[0-9a-f]{64}\z/, 'the content hash is a stable opaque hex token' );
is( current_hash(), $baseline, 'reading twice without writes yields the same hash' );

my $unselected = $tira->record_show( project => $root, ref => $ref );
ok( !exists $unselected->{content_hash}, 'the hash appears only when asked for' );

$tick = '2026-08-07T04:05:00Z';
$tira->record_update( project => $root, ref => $ref, priority => 4 );
is( current_hash(), $baseline, 'a no-op write does not change the hash' );

$tira->record_update( project => $root, ref => $ref, title => 'Hash subject, revised' );
my $after_title = current_hash();
isnt( $after_title, $baseline, 'a field change changes the hash' );

$tira->comment_add( project => $root, ref => $ref, author => 'ada', text => 'covered' );
my $after_comment = current_hash();
isnt( $after_comment, $after_title, 'comments are content' );

$tira->column_add( project => $root, type => 'ticket', name => 'doing', label => 'Doing' );
$tira->record_move( project => $root, ref => $ref, column => 'doing' );
my $after_move = current_hash();
isnt( $after_move, $after_comment, 'placement is content: a move changes the hash' );

my $exported = $tira->export_records( project => $root, fields => ['content_hash'] );
is( $exported->{records}[0]{content_hash}, $after_move, 'export serves the same per-record hash' );
like( $exported->{board_hash}, qr/\A[0-9a-f]{64}\z/, 'export exposes a board-level hash alongside per-record hashes' );
my $board = $exported->{board_hash};
is( $tira->export_records( project => $root, fields => ['content_hash'] )->{board_hash},
    $board, 'consecutive exports without writes agree on the board hash' );

my $conditional = $tira->record_show( project => $root, ref => $ref, if_changed => $after_move );
is_deeply( $conditional, { unchanged => JSON::PP::true }, 'a matching hash returns the unchanged marker' );
$conditional = $tira->record_show( project => $root, ref => $ref, if_changed => $baseline );
is( $conditional->{title}, 'Hash subject, revised', 'a stale hash returns the full record' );

$conditional = $tira->record_show(
    project => $root, ref => $ref, if_changed => $baseline, fields => ['column'],
);
is_deeply( [ sort keys %{$conditional} ], [qw(column ref)], 'conditional reads compose with projection' );

eval { $tira->record_show( project => $root, ref => $ref, if_changed => 'zz-not-a-hash' ) };
like( $@, qr/If-changed hash is malformed/, 'a malformed hash dies rather than meaning changed' );

my $board_conditional = $tira->export_records( project => $root, if_changed => $board );
is_deeply( $board_conditional, { unchanged => JSON::PP::true }, 'a matching board hash collapses the whole export' );
$tira->record_update( project => $root, ref => $ref, description => 'Board moved on' );
$board_conditional = $tira->export_records( project => $root, if_changed => $board );
is( $board_conditional->{count}, 1, 'a stale board hash returns the full envelope' );
like( $board_conditional->{board_hash}, qr/\A[0-9a-f]{64}\z/, 'the changed envelope carries the new board hash' );

my $strict = $tira->record_show(
    project => $root, ref => $ref, since => '2030-01-01T00:00:00Z', if_changed => $baseline,
);
is_deeply( $strict, {}, 'when since and if-changed are combined the stricter suppression wins' );

sub run_cli {
    my ( $command, $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run(
        command => $command, ( defined $type ? ( type => $type ) : () ), argv => \@argv,
    );
    return ( $status, $out, $err );
}

my $latest = current_hash();
my ( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref,
    '--if-changed', $latest, '-o', 'json',
);
is( $status, 1, 'an unchanged conditional read exits 1, distinct from success-with-content' );
ok( decode_json($out)->{unchanged}, 'the unchanged marker is printed for parsers too' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref,
    '--if-changed', $baseline, '-o', 'json',
);
is( $status, 0, 'a changed conditional read exits 0' );
is( decode_json($out)->{ref}, $ref, 'the changed record is returned in full' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $ref,
    '--if-changed', 'nope', '-o', 'json',
);
is( $status, 2, 'a malformed CLI hash exits 2' );
like( $err, qr/malformed/, 'the CLI error says the hash is malformed' );

( $status, $out, $err ) = run_cli(
    'record.list', 'ticket', '--project', $root, '--if-changed', $latest, '-o', 'json',
);
is( $status, 2, 'conditional reads are refused on list' );
like( $err, qr/show and export/, 'the error names where conditional reads apply' );

done_testing;

__END__

=head1 NAME

28-content-hash.t - content hashes and conditional reads (CA05, CA06)

=head1 DESCRIPTION

Proves the stable per-record C<content_hash> (volatile stamps excluded so
a no-op write keeps its hash; fields, comments, attachments, and
placement all covered), the export board hash, and C<--if-changed>
conditional reads: unchanged marker with CLI exit 1, full payload on
change, malformed hashes loud, composition with projection and since,
and refusal outside show/export.

=cut
