#!/usr/bin/env perl
# A command run quietly stays quiet even when its caller captured its output.
#
# _running_quietly hands the child a filehandle for its ERROR stream, which is
# the fix t/139 records, and a pipe for its standard output, which it drains and
# throws away. That works whenever this process's standard output has a file
# descriptor behind it.
#
# It stops working in the one case the whole suite depends on. When the caller
# has captured its own output into a string - local *STDOUT onto a scalar, which
# is how every test here reads what a command printed, and how the served
# dashboard collects a response - the glob has no descriptor. open3 cannot set
# the child's standard output up against it, and the child inherits the real
# descriptor 1 instead. So "git version 2.52.0" arrives on the process's actual
# standard output: in the middle of a command's output, in the dashboard's
# response, or in this suite's TAP stream, from a call whose entire purpose was
# to run something without it being heard.
#
# Three earlier attempts at this test passed while the fault was present, and
# each was wrong in a way worth keeping.
#
# The first checked the helper's return value, which is unaffected.
#
# The second printed either side of the call and captured STDOUT into a string,
# on the theory that the caller's handle was being closed. It is not - both
# prints arrive intact - and the theory was a misreading recorded on the card.
#
# The third pointed descriptor 1 at a file and read the file back. That passed
# because it fixed the very condition that causes the fault: with a real
# descriptor to work against, the helper is correct.
#
# So both conditions have to hold at once, and that is what this does. The real
# descriptor 1 is aimed at a file so anything leaking to it can be read, and
# Perl's STDOUT is a fresh in-memory glob so the leak actually happens.
#
# The return value is asserted as well. An empty file is also what you get when
# the command never ran, which is how the first attempt went green.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

plan skip_all => 'git is not installed here'
  if !Tira::CLI::Serve::_program_exists('git');

my $tmp  = tempdir( CLEANUP => 1 );
my $leak = File::Spec->catfile( $tmp, 'anything-that-got-past.txt' );

my $worked;
{
    open my $saved, '>&', \*STDOUT
      or die "Cannot remember the real standard output: $!";
    open my $sink, '>', $leak
      or die "Cannot open somewhere to catch a leak: $!";

    # Descriptor 1 now points at a file, so anything reaching it can be read
    # back. Perl's STDOUT is then replaced by a glob with no descriptor at all,
    # which is the state a captured caller is in.
    open STDOUT, '>&', $sink
      or die "Cannot aim the real standard output at the file: $!";

    {
        local *STDOUT;
        open STDOUT, '>', \my $captured
          or die "Cannot capture standard output into a string: $!";
        $worked = Tira::CLI::Serve::_running_quietly( 'git', '--version' );
    }

    # Silencing a child must not cost the caller its own output. That is the
    # failure t/139 records from a different attempt at the same problem, so it
    # is asserted rather than assumed: this print goes to the file, and the file
    # is checked for it below.
    print "the caller can still be heard\n";

    open STDOUT, '>&', $saved
      or die "Cannot put the real standard output back: $!";
    close $sink;
    close $saved;
}

ok( $worked, 'the command ran and reported that it worked' );

open my $said, '<', $leak or die "Cannot read what got past: $!";
my $written = do { local $/; <$said> };
close $said;

unlike(
    $written,
    qr/git version/,
    'and nothing the command printed reached the output of the process that ran it'
);

like(
    $written,
    qr/the caller can still be heard/,
    'while the caller kept the output it had - silencing the child cost it nothing'
);

is(
    $written,
    "the caller can still be heard\n",
    'so what arrived is the caller own line and nothing else'
);

done_testing;

__END__

=head1 NAME

204-a-quiet-command-that-silences-its-caller.t - quiet means quiet everywhere

=head1 DESCRIPTION

C<_running_quietly> handed the child a filehandle for its error stream and a
pipe for its output, which works while this process's standard output has a file
descriptor behind it. When the caller has captured its own output into a string
- every test here, and the served dashboard collecting a response - the glob has
no descriptor, C<open3> cannot set the child's output up against it, and the
child inherits the real descriptor 1. A command run quietly was then heard by
whoever the caller was talking to.

The descriptors themselves are pointed at the null device around the call and
put back afterwards, so the child inherits harmless ones whatever the globs are
doing. The same hole was on the error stream, which C<t/139> never reached
because it reopens C<STDERR> onto a real file.

Both conditions have to hold at once for the fault to appear, which is why three
earlier attempts at this test passed while it was present.

=cut
