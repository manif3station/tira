package Shipped;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(runnable_ok);

use Test::More ();

# What makes a file a command, asked once.
#
# On a POSIX system it is the executable bit, and nine tests asserted it with a
# bare -x. On Windows there is no such bit: -x answers for the extension, so an
# extensionless entrypoint reads as not runnable and the assertion fails on a
# release where nothing is wrong. The platform gate found five of those across
# t/169 and t/187 - and t/169's other three followed from its first, because a
# caller the test could not run returned nothing for the later assertions to
# read.
#
# t/03 had already worked this out and guarded its own count with
# ( $^O eq 'MSWin32' || -x $_ ). Copying that line into nine more places would
# have made nine copies of one decision, which is the shape this codebase keeps
# finding drifted. It lives here instead.
#
# Existence is still asserted on Windows. A command that stopped shipping is
# the fault these assertions exist for, and that fault is the same on every
# platform.
sub runnable_ok {
    my ( $path, $name ) = @_;
    return Test::More::ok( -e $path, $name ) if $^O eq 'MSWin32';
    return Test::More::ok( -x $path, $name );
}

1;

__END__

=head1 NAME

Shipped - whether an entrypoint ships in a form an agent can run

=head1 SYNOPSIS

    use lib 'lib', 't/lib';
    use Shipped qw(runnable_ok);

    runnable_ok( 'cli/changes', 'the changelog command ships and is runnable' );

=head1 DESCRIPTION

Executability is what makes a file a command on a POSIX system and is not a
concept on Windows, where C<-x> answers for the extension rather than the file.
Asked here so the answer is one decision rather than one per test, and so the
platform gate stops failing on a difference between platforms rather than a
defect in the release.

=cut
