#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Time::HiRes ();
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

# --- a record rewritten in place ------------------------------------------

# The fingerprint used to read the modification times of the column
# directories only. A file rewritten in place changes no name in its directory,
# so on NTFS the directory's time is untouched, the cache is judged current,
# and the caller is served the board as it was before its own write.
#
# Rewriting in place is the same on every filesystem: no rename, no name added
# or removed, so no directory time changes anywhere. That makes this the real
# condition rather than an imitation of it.
{
    my $before = Tira::CLI::_board_fingerprint($root);

    my $column = File::Spec->catdir( $root, '.tira', 'ticket', 'backlog' );
    my ($file) = glob File::Spec->catfile( $column, '*.json' );
    ok( $file, 'a record file to rewrite' );

    my @directory_before = Time::HiRes::stat($column);

    open my $fh, '<:raw', $file or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    $body =~ s/"title" : "[^"]*"/"title" : "Rewritten in place"/;
    open my $out, '>:raw', $file or die $!;
    print {$out} $body;
    close $out;

    my @directory_after = Time::HiRes::stat($column);
    is( $directory_after[9], $directory_before[9],
        'rewriting a file in place leaves its directory untouched, which is the whole problem' );

    isnt( Tira::CLI::_board_fingerprint($root), $before,
        'and the fingerprint changes anyway, because it reads the records themselves' );
}

# --- two writes inside one tick of the clock -------------------------------

# Modification times are not fine-grained everywhere. Windows hands out the
# same time to everything written inside one clock tick, about sixteen
# milliseconds, so a fingerprint made of times alone can say nothing changed
# while a card was rewritten. Tira raises a counter on every write and the
# fingerprint reads it, so the answer does not depend on a clock at all.
SKIP: {
    # Putting a time back exactly needs sub-second resolution, which
    # Time::HiRes does not implement everywhere. Where it cannot, this cannot
    # be staged - and the counter it proves is the same code on every platform.
    skip 'this system cannot set a time to better than a second', 2
      if !eval { Time::HiRes::utime( time, time, $root ); 1 };

    my $file = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog',
        $ticket->{ref} . '.json' );
    ok( -f $file, 'the card is where it should be' );

    my @watched = (
        $file, $root,
        File::Spec->catdir( $root, '.tira' ),
        File::Spec->catdir( $root, '.tira', 'ticket' ),
        File::Spec->catdir( $root, '.tira', 'ticket', 'backlog' ),
        File::Spec->catfile( $root, '.tira', 'project.yml' ),
    );

    # Taken before the write, so putting them back really does undo the passage
    # of time rather than restoring what the write had just set.
    my %was = map { $_ => [ Time::HiRes::stat($_) ] } @watched;

    my $before = Tira::CLI::_board_fingerprint($root);
    $tira->record_update( project => $root, ref => $ticket->{ref}, title => 'Same tick' );

    # Every modification time put back exactly as it was: the strongest form of
    # the problem, where nothing about any time has changed anywhere.
    # Time::HiRes' own utime, because the core one takes whole seconds: putting
    # a time back to the nearest second changes the fraction and the fingerprint
    # differs for that alone, which would let this pass without proving
    # anything.
    Time::HiRes::utime( $was{$_}[8], $was{$_}[9], $_ ) for @watched;

    isnt( Tira::CLI::_board_fingerprint($root), $before,
        'a write is still visible when every modification time says otherwise' );
}

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
