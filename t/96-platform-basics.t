#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use POSIX ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# --- the clock ------------------------------------------------------------

# strftime's %z is a numeric offset on POSIX and a zone name on Windows, so
# every timestamp Tira wrote there was malformed - and malformed is worse than
# missing, because the failure surfaces wherever the timestamp is next parsed
# rather than where it was made.
my $stamp = Tira->new->{clock}->();
like( $stamp, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}\z/,
    'the default clock stamps an ISO time with a numeric offset' );

# Numeric is not the same as right. A named moment in a named zone has one
# correct offset, and this is the assertion that would catch a sign flip or an
# offset built from the wrong pair of times.
SKIP: {
    skip 'this system does not take a named time zone from the environment', 3
      if !eval { POSIX::tzset(); 1 };

    local $ENV{TZ} = 'Asia/Hong_Kong';
    POSIX::tzset();
    like( Tira->new->{clock}->(), qr/\+0800\z/, 'and the offset is the one the zone has' );

    local $ENV{TZ} = 'UTC';
    POSIX::tzset();
    like( Tira->new->{clock}->(), qr/\+0000\z/, 'including where there is none' );

    # A zone behind UTC, because a sign flip passes everything above.
    local $ENV{TZ} = 'America/New_York';
    POSIX::tzset();
    like( Tira->new->{clock}->(), qr/-0[45]00\z/, 'and west of it the sign is negative' );
}

# --- finding an installed agent -------------------------------------------

ok( Tira::CLI::_agent_available('sh'), 'a program on the PATH is found' )
  if $^O ne 'MSWin32';
ok( !Tira::CLI::_agent_available('definitely-not-a-real-program-anywhere'),
    'and one that is not there is not' );

# The Windows path, driven where Windows is not: a semicolon-separated PATH and
# an executable that is only executable because of its extension. Both are
# facts about the platform rather than about the file, and neither can be
# reached from Linux without saying so.
{
    local $Tira::CLI::WINDOWS = 1;
    local $ENV{PATHEXT} = '.COM;.EXE;.BAT';

    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    open my $fh, '>', File::Spec->catfile( $dir, 'claude.EXE' ) or die $!;
    print {$fh} "not really a program\n";
    close $fh;

    local $ENV{PATH} = join ';', 'C:\\nowhere', $dir;
    ok( Tira::CLI::_agent_available('claude'),
        'a Windows program is found by its extension on a semicolon-separated path' );
    ok( !Tira::CLI::_agent_available('codex'),
        'and one that is not installed is still not found' );
}

# --- the bytes that leave the process --------------------------------------

# A text-mode layer rewrites every newline on the way out. Windows puts one on
# standard output by default; here it is pushed deliberately, so what only ever
# happened on Windows is proved on Linux. Tira caches output bytes and serves
# them back, so bytes that differ by platform are a broken contract rather than
# a cosmetic difference.
#
# Not run under a harness on Windows, where replacing standard output while the
# harness is reading it through a pipe hangs the test rather than failing it -
# and a hang is worse than a failure because nothing after it ever runs. What
# this proves is covered there by t/01-cli.t, which runs real commands as child
# processes and reads their output: those assertions failed on Windows before
# this fix and pass after it. The reason is written here rather than left as a
# bare skip, because a skip that hides a limitation reads as coverage.
SKIP: {
    skip 'replacing standard output under a harness hangs on Windows', 3
      if $^O eq 'MSWin32';

    # A real file rather than an in-memory handle: the layers on a scalar handle
    # behave differently on Windows, and the thing being tested is what reaches
    # a file or a terminal.
    my $log = File::Spec->catfile( File::Temp::tempdir( CLEANUP => 1 ), 'out.txt' );
    open my $capture, '>', $log or die $!;
    binmode $capture, ':crlf';

    my $tmp = File::Temp::tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'lines' );
    Tira->new->project_new( name => 'Lines', dir => $root, columns => ['backlog, doing'] );

    my $status = do {
        local *STDOUT = $capture;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'record.create', type => 'ticket',
            argv => [ '--title', 'A card', '-o', 'human' ] ) };
    };
    close $capture;
    is( $status, 0, 'a command that prints runs' );

    open my $back, '<:raw', $log or die $!;
    my $written = do { local $/; <$back> };
    close $back;

    # Named rather than merely non-empty: an assertion that nothing has a
    # carriage return passes for free when nothing was written at all, and
    # that is exactly what happens when the layer is left in place.
    like( $written, qr/TKT-001/, 'and writes the card it made' );
    unlike( $written, qr/\r/, 'with not one carriage return Tira did not write' );
}

done_testing;

__END__

=head1 NAME

96-platform-basics.t - the two things Tira assumed about the machine it was written on

=head1 DESCRIPTION

The Windows lab found both of these, and neither announced itself as an error.
The default clock produced a timestamp with a zone name where a numeric offset
belongs, so every record written on Windows carried a stamp nothing could parse.
The search for an installed coding agent split PATH on a colon and looked for a
file with no extension, so onboarding decided nothing was installed however much
was.

Both are exercised here rather than only on the lab, because a branch that can
only be reached on a machine visited once a release is a branch nobody is
watching.

=cut
