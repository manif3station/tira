#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
    # Windows' own MoveFileEx, standing in for the real one so the Windows
    # branch can be driven in the Linux container. It is deliberately not a
    # stub that returns true: it performs the replacement, so what is being
    # covered is our branch reaching the right call with the right flags and
    # the file genuinely ending up replaced. The real call is proved on the
    # lab, which is the only place it can be.
    package Win32API::File;
    sub MOVEFILE_REPLACE_EXISTING { 1 }
    sub MOVEFILE_WRITE_THROUGH    { 8 }
    our @SEEN;
    sub MoveFileEx {
        my ( $from, $to, $flags ) = @_;
        push @SEEN, { from => $from, to => $to, flags => $flags };
        return 0 if !( $flags & MOVEFILE_REPLACE_EXISTING() );
        unlink $to;
        return rename( $from, $to ) ? 1 : 0;
    }
    $INC{'Win32API/File.pm'} = __FILE__;
}

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-12T09:00:00Z' } );

# --- what the platform lab found ------------------------------------------

# Tira writes every file by writing a temporary one beside it and renaming it
# over the target, so a reader sees the old file or the new one and never half
# of either. POSIX rename replaces. Win32 rename refuses when the destination
# exists - so on Windows the first write to any file that already exists died
# with "Cannot replace ...: Permission denied", and every card update, every
# board change and every config write with it.
#
# Linux cannot run that branch, so it is driven here rather than left to a lab
# that is only visited at the end of a release.

my $path = File::Spec->catfile( $tmp, 'target.txt' );
$tira->_atomic_write( $path, "first\n" );
is( slurp($path), "first\n", 'a file is written' );

$tira->_atomic_write( $path, "second\n" );
is( slurp($path), "second\n", 'and written again over itself, which is the case that failed' );

# --- the same thing, down the Windows path --------------------------------

{
    local $Tira::WINDOWS = 1;

    $tira->_atomic_write( $path, "third\n" );
    is( slurp($path), "third\n",
        'the Windows replace puts the new content in place of the old' );

    my $fresh = File::Spec->catfile( $tmp, 'new-file.txt' );
    $tira->_atomic_write( $fresh, "created\n" );
    is( slurp($fresh), "created\n", 'and creates a file that was not there' );

    # No temporary files left lying beside it either way.
    my @leftovers = glob File::Spec->catfile( $tmp, '.tira-write-*' );
    is( scalar @leftovers, 0, 'leaving no temporary file behind' );

    # The flags are the whole fix. Without MOVEFILE_REPLACE_EXISTING this is
    # the call that was already failing, and with an unlink instead of a
    # replace it would no longer be atomic - which the documentation promises.
    my $call = $Win32API::File::SEEN[-1];
    ok( $call->{flags} & Win32API::File::MOVEFILE_REPLACE_EXISTING(),
        'asking for a replace, which is the difference between working and not' );
    ok( $call->{flags} & Win32API::File::MOVEFILE_WRITE_THROUGH(),
        'and for the write to have reached the disk before it is called done' );
}

# --- when the replace fails ------------------------------------------------

# The error has to name the file and say why, and the temporary must not be
# left behind - that is true on both paths, and the Windows one is new code
# that could easily have neither.
{
    local $Tira::WINDOWS = 1;
    no warnings 'redefine';
    local *Tira::_replace_file = sub { $! = 13; return 0 };

    my $doomed = File::Spec->catfile( $tmp, 'doomed.txt' );
    ok( !eval { $tira->_atomic_write( $doomed, "never\n" ); 1 },
        'a replace that fails is an error, not a silent nothing' );
    like( $@, qr/\Q$doomed\E/, 'and the error names the file' );
    like( $@, qr/\S/, 'and says why' );

    my @leftovers = glob File::Spec->catfile( $tmp, '.tira-write-*' );
    is( scalar @leftovers, 0, 'and the temporary file is cleaned up' );
}

# --- the second Windows bug, which the first one hid -----------------------

# YAML::PP's load_file leaves the handle open. On Linux that is untidy and
# harmless; on Windows an open handle makes a file impossible to replace, so
# every board config write failed with "Access is denied" immediately after the
# config had been read. Nothing about it is visible on Linux, which is why it
# is asserted here rather than left to a lab.
{
    my $config = File::Spec->catfile( $tmp, 'config.yml' );
    open my $out, '>', $config or die $!;
    print {$out} "prefix: TKT\ndigits: 3\n";
    close $out;

    my $read = $tira->_load_yaml($config);
    is( $read->{prefix}, 'TKT', 'yaml is read' );

    my $open_after = open_handles($config);
    is( $open_after, 0, 'and the file is not left open, which is what broke Windows' );

    local $Tira::WINDOWS = 1;
    $tira->_atomic_write( $config, "prefix: NEW\n" );
    is( $tira->_load_yaml($config)->{prefix}, 'NEW',
        'so a config can be replaced immediately after being read' );
}

# How many open handles this process has on a file. /proc is Linux's own
# answer, and the container is where this runs.
sub open_handles {
    my ($file) = @_;
    return 0 if !-d '/proc/self/fd';
    my $count = 0;
    opendir my $dh, '/proc/self/fd' or return 0;
    for my $entry ( readdir $dh ) {
        next if $entry =~ /\A\.\.?\z/;
        my $link = readlink "/proc/self/fd/$entry";
        $count++ if defined $link && $link eq $file;
    }
    closedir $dh;
    return $count;
}

sub slurp {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

done_testing;

__END__

=head1 NAME

95-windows-replace.t - replacing a file, on a platform where rename does not

=head1 DESCRIPTION

The Windows lab found that Tira could create files and never change one. Perl's
C<rename> on Win32 refuses when the destination exists, and every write in Tira
is a write-beside-and-rename - so the first update to any card died.

The fix has to stay atomic. C<docs/foundation.md> says Tira writes through
same-directory temporary files and atomically renames completed data; unlinking
the target first and then renaming would work on Windows and would make that
sentence false, leaving a window in which the file does not exist at all.

The branch cannot run in the Linux container, so the container drives it
directly rather than trusting a lab that is visited once a release.

=cut
