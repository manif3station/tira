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
my $root = File::Spec->catdir( $tmp, 'grouped' );
my $tira = Tira->new( clock => sub { '2026-08-07T09:00:00Z' } );
$tira->create_project( name => 'Grouped', dir => $root );
my $one = $tira->create_record( project => $root, type => 'ticket', title => 'Batch one' );
my $two = $tira->create_record( project => $root, type => 'ticket', title => 'Batch two' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Batch epic' );

my $batch = $tira->record_show_many(
    project => $root, refs => [ $two->{ref}, $one->{ref} ],
);
is( $batch->{count}, 2, 'the batch reports how many refs were requested' );
is_deeply( $batch->{order}, [ $two->{ref}, $one->{ref} ],
    'order matches the request, not storage' );
is( $batch->{records}{ $one->{ref} }{title}, 'Batch one', 'records are keyed by ref' );
is( $batch->{records}{ $two->{ref} }{title}, 'Batch two', 'every requested record arrives' );

$batch = $tira->record_show_many(
    project => $root, refs => [ $one->{ref}, $epic->{ref} ],
);
is( $batch->{records}{ $epic->{ref} }{type}, 'epic',
    'a batch crosses record types in one call' );

$batch = $tira->record_show_many(
    project => $root, refs => [ $one->{ref}, 'TKT-999', $two->{ref} ],
);
ok( $batch->{records}{'TKT-999'}{not_found},
    'a missing ref is an explicit marker, never a silent omission' );
is( $batch->{records}{ $two->{ref} }{title}, 'Batch two',
    'one bad ref does not lose the rest of the call' );

$batch = $tira->record_show_many(
    project => $root, refs => [ $one->{ref}, $one->{ref} ],
);
is( $batch->{count}, 1, 'repeated refs deduplicate to one read' );

$batch = $tira->record_show_many(
    project => $root, refs => [ $one->{ref} ], fields => ['column'],
);
is_deeply( [ sort keys %{ $batch->{records}{ $one->{ref} } } ], [qw(column ref)],
    'batch reads compose with projection' );

eval { $tira->record_show_many( project => $root, refs => [] ) };
like( $@, qr/at least one ref/, 'an empty batch is refused' );
eval { $tira->record_show_many( project => $root, refs => [ map { "TKT-$_" } 1 .. 101 ] ) };
like( $@, qr/at most 100/, 'the documented maximum is enforced with a clear error' );
eval { $tira->record_show_many( project => $root, refs => [ $one->{ref} ], fields => ['nosuchfield'] ) };
like( $@, qr/Unknown field 'nosuchfield'/,
    'a validation error fails the whole call loudly instead of becoming not-found' );

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

my ( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root,
    '--ref', $one->{ref}, '--ref', $two->{ref}, '-o', 'json',
);
is( $status, 0, 'repeated --ref flags batch' );
my $payload = decode_json($out);
is( $payload->{records}{ $two->{ref} }{title}, 'Batch two', 'the CLI batch is keyed by ref' );
is_deeply( $payload->{order}, [ $one->{ref}, $two->{ref} ], 'the CLI batch preserves request order' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root,
    '--refs', "$one->{ref},TKT-999", '-o', 'json',
);
is( $status, 0, 'a comma list batches' );
ok( decode_json($out)->{records}{'TKT-999'}{not_found}, 'CLI missing refs carry the marker' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root, '--ref', $one->{ref}, '-o', 'json',
);
is( decode_json($out)->{ref}, $one->{ref}, 'a single ref still returns the plain record' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root,
    '--ref', $one->{ref}, '--refs', "$two->{ref},$epic->{ref}", '-o', 'json',
);
is( $status, 0, 'a single --ref composes with a --refs list' );
$payload = decode_json($out);
is_deeply( $payload->{order}, [ $one->{ref}, $two->{ref}, $epic->{ref} ],
    'the composed batch keeps --ref first, then the list' );

( $status, $out, $err ) = run_cli(
    'record.show', 'ticket', '--project', $root,
    '--refs', "$one->{ref},$two->{ref}", '--if-changed', ( 'a' x 64 ), '-o', 'json',
);
is( $status, 2, 'batches refuse --if-changed' );
like( $err, qr/content_hash/, 'the refusal points at the cheap alternative' );

( $status, $out, $err ) = run_cli(
    'record.move', 'ticket', '--project', $root,
    '--ref', $one->{ref}, '--ref', $two->{ref}, '--column', 'backlog', '-o', 'json',
);
is( $status, 2, 'multiple refs on a mutation exit 2' );
like( $err, qr/only.*show/i, 'the error says batches are show-only' );

done_testing;

__END__

=head1 NAME

33-batch.t - batch reads (CA19)

=head1 DESCRIPTION

Proves C<record_show_many> and the CLI batch surface: keyed-by-ref
results with request order and count, cross-type batches, explicit
not-found markers with partial results preserved, deduplication, the
documented 100-ref maximum, loud validation failures, projection
composition, the single-ref path unchanged, the if-changed refusal with
its cheaper alternative, and mutation guards.

=cut
