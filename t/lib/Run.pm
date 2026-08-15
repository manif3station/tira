package Run;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(run_quietly run_capturing run_split);

use File::Spec;
use File::Temp qw(tempfile);

# Running a command without asking a shell to read it.
#
# Four tests shelled out by building one string and letting the shell take it
# apart: 'git' 'init' '-q' '/path' > '/out' 2>&1, and `cd '$where' && git ...`.
# That is correct POSIX quoting and it is not quoting at all on Windows, where
# cmd.exe treats the single quotes as part of the filename. The platform gate
# found it as five failures across four files, reported as git refusing or as
# "The filename, directory name, or volume label syntax is incorrect" - neither
# of which reads as "the test never ran the command it meant to". TKT-222.
#
# system with a list never involves a shell, so nothing has to be quoted for
# one. Output goes where it is wanted by moving the handles rather than by
# writing a redirect into a string, which is the same thing the CLI does for
# the same reason.
#
# The status is returned as the process exit code, not as the raw wait value,
# because every caller here wants the former and shifting it themselves is one
# more thing to get wrong on one platform and not the other.
sub _run {
    my ( $capture, @command ) = @_;

    my ( $handle, $path ) = tempfile( UNLINK => 1 );
    close $handle;

    open my $saved_out, '>&', \*STDOUT or die "stdout: $!";
    open my $saved_err, '>&', \*STDERR or die "stderr: $!";
    open STDOUT, '>', $path            or die "$path: $!";
    open STDERR, '>&', \*STDOUT        or die "stderr: $!";

    my $raw = system @command;

    open STDOUT, '>&', $saved_out or die "stdout: $!";
    open STDERR, '>&', $saved_err or die "stderr: $!";

    my $status = $raw == -1 ? -1 : $raw >> 8;
    return $status if !$capture;

    open my $read, '<', $path or die "$path: $!";
    my $output = do { local $/; <$read> };
    close $read;
    return ( $status, $output // '' );
}

sub run_quietly   { return _run( 0, @_ ) }
sub run_capturing { return _run( 1, @_ ) }

# The two streams kept apart, for the one caller that is about which of them a
# command wrote to. Merging them would answer a different question than the one
# that test is asking.
sub run_split {
    my (@command) = @_;

    my ( $out_handle, $out_path ) = tempfile( UNLINK => 1 );
    my ( $err_handle, $err_path ) = tempfile( UNLINK => 1 );
    close $out_handle;
    close $err_handle;

    open my $saved_out, '>&', \*STDOUT or die "stdout: $!";
    open my $saved_err, '>&', \*STDERR or die "stderr: $!";
    open STDOUT, '>', $out_path        or die "$out_path: $!";
    open STDERR, '>', $err_path        or die "$err_path: $!";

    my $raw = system @command;

    open STDOUT, '>&', $saved_out or die "stdout: $!";
    open STDERR, '>&', $saved_err or die "stderr: $!";

    my $read = sub {
        my ($path) = @_;
        open my $fh, '<:raw', $path or return '';
        my $text = do { local $/; <$fh> };
        close $fh;
        return $text // '';
    };
    return ( $raw == -1 ? -1 : $raw >> 8, $read->($out_path), $read->($err_path) );
}

1;

__END__

=head1 NAME

Run - run a command without a shell, on either platform

=head1 SYNOPSIS

    use lib 'lib', 't/lib';
    use Run qw(run_quietly run_capturing);

    is( run_quietly( 'git', 'init', '-q', $repo ), 0, 'a repository to work in' );
    my ( $status, $output ) = run_capturing( 'git', '-C', $repo, 'status' );

=head1 DESCRIPTION

C<system> with a list never involves a shell, so nothing has to be quoted for
one - which is what four tests were doing, correctly for POSIX and not at all
for Windows. Output is moved by rearranging handles rather than by writing a
redirect into a command string, and the status comes back as the exit code.

=cut
