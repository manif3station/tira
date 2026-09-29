#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# TKT-1198. _atomic_write asks for its temporary file with UNLINK => 0, so
# nothing removes it automatically, and TKT-1196 made the print, close and
# replace exits remove it. One exit was left: _canonical_path runs on the fresh
# temporary file straight after tempfile() returns, and it can die - "Cannot
# resolve" when realpath gives nothing, "Unsafe control character" when the
# resolved path holds one - before any of that cleanup is in reach. The file was
# already on disk, so each such failure left a .tira-write-* file behind.
#
# A directory whose name holds a control character is real and portable on
# POSIX, so that branch is proven with the real thing rather than a stand-in.
# realpath does not fail on a file that exists, so the other branch is proven by
# making _canonical_path die, which is what a vanished directory or a filesystem
# that will not resolve would do.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-29T20:30:00Z' } );

sub leftovers {
    my ($dir) = @_;
    opendir my $dh, $dir or die "Cannot read $dir: $!";
    my @left = grep { /\A\.tira-write-/ } readdir $dh;
    closedir $dh;
    return @left;
}

# --- a real directory whose name contains a control character -------------------

{
    my $dir = File::Spec->catdir( $tmp, "ctl\x01dir" );

    # Only these four assertions depend on the filesystem accepting the name; a
    # filesystem that refuses it must not also skip the cases below.
  SKIP: {
        skip 'this filesystem will not create a control-character directory', 4 if !mkdir $dir;
        my $target = File::Spec->catfile( $dir, 'target.txt' );

        my $ok    = eval { $tira->_atomic_write( $target, "never lands\n" ); 1 };
        my $error = $@;
        ok( !$ok, 'a write into a control-character directory is refused' );
        like(
            $error,
            qr/\AUnsafe control character in temporary file for '\Q$target\E'\n\z/,
            'and says why, exactly as _canonical_path put it'
        );
        is_deeply( [ leftovers($dir) ], [], 'and leaves no .tira-write-* file behind in that directory' );
        ok( !-e $target, 'and the target was never created' );
    }
}

# --- _canonical_path forced to die: the "Cannot resolve" branch -------------------

{
    my $dir    = tempdir( DIR => $tmp, CLEANUP => 1 );
    my $target = File::Spec->catfile( $dir, 'target.txt' );
    my $said   = "Cannot resolve temporary file for '$target'\n";

    my $ok = do {
        no warnings 'redefine';
        local *Tira::_canonical_path = sub { die $said };
        eval { $tira->_atomic_write( $target, "never lands\n" ); 1 };
    };
    my $error = $@;
    ok( !$ok, 'a write whose temporary file cannot be resolved is refused' );
    is( $error, $said, 'and the caller gets the original message unchanged, not one the cleanup wrote over' );
    is_deeply( [ leftovers($dir) ], [], 'and leaves no .tira-write-* file behind' );
    ok( !-e $target, 'and the target was never created' );
}

# --- repeated failures must not add up ---------------------------------------------

{
    my $dir    = tempdir( DIR => $tmp, CLEANUP => 1 );
    my $target = File::Spec->catfile( $dir, 'target.txt' );
    no warnings 'redefine';
    local *Tira::_canonical_path = sub { die "Cannot resolve temporary file for '$target'\n" };
    eval { $tira->_atomic_write( $target, "never lands\n" ) } for 1 .. 5;
    is_deeply( [ leftovers($dir) ], [], 'five failed writes in a row still leave the directory empty' );
}

# --- the exit that already worked must keep working ---------------------------------

{
    my $dir    = tempdir( DIR => $tmp, CLEANUP => 1 );
    my $target = File::Spec->catfile( $dir, 'ok.txt' );
    is( $tira->_atomic_write( $target, "landed\n" ), 1, 'a write that can land still returns 1' );
    open my $in, '<', $target or die "Cannot read $target: $!";
    is( scalar <$in>, "landed\n", 'and the content is what was written' );
    close $in;
    is_deeply( [ leftovers($dir) ], [], 'and leaves no temporary file either' );
}

done_testing;

__END__

=head1 NAME

1198-a-canonical-path-failure-keeps-no-temp-file.t - a temporary file that cannot be validated is not left behind

=head1 DESCRIPTION

TKT-1198. C<Tira::_atomic_write> asks for its temporary file with
C<UNLINK =E<gt> 0>, so every way out after the file exists has to remove it
itself. TKT-1196 covered the print, close and replace exits, but
C<_canonical_path> runs on the fresh temporary file before any of them, and it
dies with C<Cannot resolve> or C<Unsafe control character> - so a failure there
left a C<.tira-write-*> file in the board directory each time.

The control-character case uses a real directory whose name contains
C<\x01>, so the true C<Unsafe control character> branch is exercised rather than
a stand-in. The C<Cannot resolve> case forces C<_canonical_path> to die, since
C<realpath> does not fail on a file that exists. Each case asserts the original
error message reaches the caller unchanged, that the directory holds no
C<.tira-write-*> file, and that the target was never created; a run of five
failures proves they do not accumulate, and a control case proves an ordinary
write still returns 1 and leaves nothing behind.

=cut
