#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# TKT-1196. _atomic_write writes a temporary file beside the target and renames
# it over the target. It asks for that file with UNLINK => 0, so nothing removes
# it automatically - which means every exit after the file exists has to remove
# it itself. The replace-failure exit did; the write-failure and close-failure
# exits died and left a .tira-write-* file in the board directory each time.
#
# A full disk is the realistic cause and cannot be produced in a portable test,
# so tempfile() is stood in for: it still creates a real file where the real one
# would be, but hands back a handle on /dev/full, which refuses every byte with
# ENOSPC. A small write is buffered and fails at close; a write bigger than the
# buffer fails at print. Those are the two branches under test.

use POSIX ();

# Being writable by -w proves nothing about opening it, so the probe opens it.
plan skip_all => '/dev/full cannot be opened here (POSIX only)'
  if !open( my $probe, '>', '/dev/full' );
close $probe;

# The original error must survive the cleanup, not just its prefix.
my $enospc = do { local $! = POSIX::ENOSPC(); "$!" };

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-29T18:00:00Z' } );

sub leftovers {
    my ($dir) = @_;
    opendir my $dh, $dir or die "Cannot read $dir: $!";
    my @left = grep { /\A\.tira-write-/ } readdir $dh;
    closedir $dh;
    return @left;
}

sub write_that_cannot_land {
    my ( $dir, $content ) = @_;
    my $target = File::Spec->catfile( $dir, 'target.txt' );
    my $counter = 0;
    no warnings 'redefine';
    local *Tira::tempfile = sub {
        my ( $template, %opt ) = @_;
        my $path = File::Spec->catfile( $opt{DIR}, sprintf( '.tira-write-T%05d', ++$counter ) );
        open my $real, '>', $path or die "Cannot create $path: $!";
        close $real;
        open my $fh, '>', '/dev/full' or die "Cannot open /dev/full: $!";
        return ( $fh, $path );
    };
    my $ok = eval { $tira->_atomic_write( $target, $content ); 1 };
    return ( $ok, $@, $target );
}

# --- the close-failure exit ------------------------------------------------

{
    my $dir = tempdir( DIR => $tmp, CLEANUP => 1 );
    my ( $ok, $error, $target ) = write_that_cannot_land( $dir, "small enough to stay in the buffer\n" );
    ok( !$ok, 'a write that cannot land is refused' );
    like( $error, qr/\ACannot close temporary file for '\Q$target\E'/, 'and says the close failed, as it always did' );
    like( $error, qr/\Q$enospc\E/, 'and still carries the original ENOSPC text, which the cleanup must not overwrite' );
    is_deeply( [ leftovers($dir) ], [], 'a failed close leaves no .tira-write-* file behind' );
    ok( !-e $target, 'and the target was never created' );
}

# --- the print-failure exit ------------------------------------------------

{
    my $dir = tempdir( DIR => $tmp, CLEANUP => 1 );
    my ( $ok, $error, $target ) = write_that_cannot_land( $dir, 'x' x ( 4 * 1024 * 1024 ) );
    ok( !$ok, 'a write too big for the buffer is refused' );
    like( $error, qr/\ACannot write temporary file for '\Q$target\E'/, 'and says the write failed, as it always did' );
    like( $error, qr/\Q$enospc\E/, 'and still carries the original ENOSPC text, which the cleanup must not overwrite' );
    is_deeply( [ leftovers($dir) ], [], 'a failed print leaves no .tira-write-* file behind' );
    ok( !-e $target, 'and the target was never created' );
}

# --- the exits that already worked must keep working ------------------------

{
    my $dir    = tempdir( DIR => $tmp, CLEANUP => 1 );
    my $target = File::Spec->catfile( $dir, 'ok.txt' );
    $tira->_atomic_write( $target, "landed\n" );
    open my $in, '<', $target or die "Cannot read $target: $!";
    is( scalar <$in>, "landed\n", 'a write that can land still lands' );
    close $in;
    is_deeply( [ leftovers($dir) ], [], 'and leaves no temporary file either' );
}

done_testing;

__END__

=head1 NAME

1196-a-failed-write-keeps-no-temp-file.t - a write that fails leaves no .tira-write-* file behind

=head1 DESCRIPTION

TKT-1196. C<Tira::_atomic_write> asks for its temporary file with
C<UNLINK =E<gt> 0>, so nothing removes it automatically, yet only the
replace-failure exit unlinked it: a failed print or a failed close died and
left a C<.tira-write-*> file in the board directory each time. A full disk or
a quota is the realistic cause and cannot be produced portably, so
C<Tira::tempfile> is stood in for with a version that still creates a real file
where the real one would be but returns a handle on C</dev/full>, which refuses
every byte with ENOSPC. A small write is buffered and fails at close; a write
larger than the buffer fails at print. Each case asserts the same error message
as before, no leftover temporary file, and no target created, and a control case
proves an ordinary write still lands and leaves nothing behind.

=cut
