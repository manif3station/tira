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
my $root = File::Spec->catdir( $tmp, 'warmed' );
my $tira = Tira->new( clock => sub { '2026-08-07T14:00:00Z' } );
$tira->create_project( name => 'Warmed', dir => $root );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Cached subject' );

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

my ( $status, $first_out, $err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '60', '-o', 'json',
);
is( $status, 0, 'the first cached-mode read succeeds live' );
unlike( $err, qr/served from cache/, 'the first read is not from the cache' );

my ( $second_status, $second_out, $second_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '60', '-o', 'json',
);
is( $second_status, 0, 'the repeat read succeeds' );
is( $second_out, $first_out, 'the repeat serves identical bytes' );
like( $second_err, qr/served from cache/, 'the cache is never invisible: it reports itself on stderr' );

ok( -d File::Spec->catdir( $root, '.tira', 'cache' ),
    'cache entries live under the workspace, never a shared temp path' );

my ( $bypass_status, $bypass_out, $bypass_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '60', '--no-cache', '-o', 'json',
);
is( $bypass_status, 0, 'the explicit bypass succeeds' );
unlike( $bypass_err, qr/served from cache/, '--no-cache always reads live' );

$tira->record_update( project => $root, ref => $ticket->{ref}, title => 'Rewritten subject' );
my ( $fresh_status, $fresh_out, $fresh_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '60', '-o', 'json',
);
unlike( $fresh_err, qr/served from cache/,
    'a write invalidates immediately: a caller never reads its own stale data' );
like( $fresh_out, qr/Rewritten subject/, 'the post-write read is the fresh board' );

my ( $projected_status, $projected_out, $projected_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '60', '--fields', 'ref', '-o', 'json',
);
isnt( $projected_out, $fresh_out, 'the cache keys on the full argument set' );
is_deeply( [ sort keys %{ decode_json($projected_out)->{records}[0] } ], ['ref'],
    'the projected variant is its own correct entry' );

my ( $ttl_status, undef, $ttl_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '1', '-o', 'json',
);
is( $ttl_status, 0, 'a short ttl caches' );
sleep 2;
my ( $expired_status, undef, $expired_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '1', '-o', 'json',
);
unlike( $expired_err, qr/served from cache/, 'an entry older than its ttl reads live' );

run_cli( 'export', undef, '--project', $root, '--cache-ttl', '60', '-o', 'json' );
my $cache_dir = File::Spec->catdir( $root, '.tira', 'cache' );
opendir my $dh, $cache_dir or die $!;
my @entries = map { /\A([0-9a-f]+\.json)\z/ ? $1 : () } readdir $dh;
closedir $dh;
ok( scalar @entries, 'cache entries exist on disk' );
for my $entry (@entries) {
    open my $fh, '>:raw', File::Spec->catfile( $cache_dir, $entry ) or die $!;
    print {$fh} 'not json at all';
    close $fh;
}
my ( $corrupt_status, $corrupt_out, $corrupt_err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '60', '-o', 'json',
);
is( $corrupt_status, 0, 'a corrupt cache can never break the tool' );
unlike( $corrupt_err, qr/served from cache/, 'the corrupt entry falls back to a live read' );
like( $corrupt_err, qr/cache/i, 'the fallback warns rather than staying silent' );
like( $corrupt_out, qr/Rewritten subject/, 'the live fallback returns real data' );

my ( $mutation_status, undef, $mutation_err ) = run_cli(
    'record.update', 'ticket', '--project', $root, '--ref', $ticket->{ref},
    '--title', 'Nope', '--cache-ttl', '60', '-o', 'json',
);
is( $mutation_status, 2, 'caching a mutation exits 2' );
like( $mutation_err, qr/read commands/, 'the error says caching is for reads' );

( $status, undef, $err ) = run_cli(
    'export', undef, '--project', $root, '--cache-ttl', '0', '-o', 'json',
);
is( $status, 2, 'a zero ttl exits 2 rather than meaning something surprising' );

done_testing;

__END__

=head1 NAME

37-cache.t - opt-in read-through cache (CA18)

=head1 DESCRIPTION

Proves the per-call opt-in cache: identical bytes on a hit with a
visible stderr report, workspace-local storage, --no-cache bypass,
immediate invalidation on any write (read-your-own-writes), keying by
the full argument set, ttl expiry, corrupt-entry fallback with a
warning, and exit-2 refusals for mutations and zero ttls.

=cut
