#!/usr/bin/env perl
# The world gatherer has to work on the platforms this ships to.
#
# It asks whether a program exists before running it, and the lookup it used
# searched for a file with the exact name given, testing it with -x. On Windows
# git is git.exe, and -x answers for the extension rather than the file - so the
# lookup found nothing, and git facts, the process table and everything built on
# them came back empty. Four rules from the git side and one from the ps side
# reported nothing on Windows whatever the machine was doing.
#
# That is TKT-072 again - a rule shipped unable to fire, with silence
# indistinguishable from compliance - reintroduced inside the fix for TKT-072.
# The lookup that handles PATHEXT and uses -f was already in the same file,
# twelve lines above, written for this project for exactly this reason.
#
# Driven from here rather than from whatever platform the suite runs on. A
# Windows claim proved only by running on Windows can only be checked when
# somebody has a Windows machine to hand, and that is how it went unchecked for
# eleven releases.

use strict;
use warnings;

use File::Path ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira::CLI;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

my $tmp = tempdir( CLEANUP => 1 );

# A directory that looks like somewhere Windows keeps git: the program is
# git.exe, and there is no extensionless file beside it.
my $windows_bin = File::Spec->catdir( $tmp, 'Windows', 'bin' );
File::Path::make_path($windows_bin);
for my $program ('git.exe') {
    my $path = File::Spec->catfile( $windows_bin, $program );
    open my $fh, '>', $path or die $!;
    print {$fh} "not really a program\n";
    close $fh;
}

# And one that looks like a POSIX machine: an executable called git, no suffix.
my $posix_bin = File::Spec->catdir( $tmp, 'posix', 'bin' );
File::Path::make_path($posix_bin);
my $posix_git = File::Spec->catfile( $posix_bin, 'git' );
open my $fh, '>', $posix_git or die $!;
print {$fh} "#!/bin/sh\n";
close $fh;
chmod 0755, $posix_git;

# --- as Windows -----------------------------------------------------------

{
    local $Tira::CLI::WINDOWS = 1;
    local $ENV{PATHEXT} = '.COM;.EXE;.BAT;.CMD';
    local $ENV{PATH} = $windows_bin;

    ok( Tira::CLI::Serve::_program_exists('git'),
        'git is found on Windows, where it is called git.exe' );
    ok( !Tira::CLI::Serve::_program_exists('definitely-not-installed'),
        'and something that is not there is still not there' );
}

# --- as POSIX -------------------------------------------------------------

SKIP: {

    # The POSIX half is the only part that cannot be simulated from the other
    # side. It turns on -x, and a Windows host has no executable bit to set:
    # chmod does nothing there and -x answers for the extension. The Windows
    # half needs no such escape, because -f means the same thing everywhere -
    # which is why that is the half that was broken and went unnoticed.
    skip 'the executable bit is not a thing on Windows, so POSIX cannot be simulated here', 2
      if $^O eq 'MSWin32';

    local $Tira::CLI::WINDOWS = 0;
    local $ENV{PATH} = $posix_bin;

    ok( Tira::CLI::Serve::_program_exists('git'),
        'git is found on POSIX, where it is called git' );
    ok( !Tira::CLI::Serve::_program_exists('definitely-not-installed'),
        'and something that is not there is still not there' );
}

# --- one lookup, not two --------------------------------------------------
#
# The bug was two searches for the same thing, one of which had been taught
# about Windows and one of which had not. Two that agree today drift apart the
# first time somebody fixes only the one they were looking at.

{
    local $Tira::CLI::WINDOWS = 1;
    local $ENV{PATHEXT} = '.COM;.EXE;.BAT;.CMD';
    local $ENV{PATH} = $windows_bin;
    is( Tira::CLI::Serve::_program_exists('git') ? 1 : 0,
        Tira::CLI::_agent_available('git') ? 1 : 0,
        'both searches answer the same on Windows, because they are the same search' );
}

# --- the process table ----------------------------------------------------
#
# ps does not exist on Windows. Asking for it there is asking a question that
# can only be answered with nothing, and nothing is what "no leftover
# processes" looks like.

is_deeply( [ Tira::CLI::Serve::_process_command(0) ], [ 'ps', '-eo', 'pid=,lstart=,args=' ],
    'on POSIX the process table comes from ps' );
is_deeply( [ Tira::CLI::Serve::_process_command(1) ], [ 'tasklist', '/fo', 'csv', '/nh' ],
    'and on Windows from tasklist, which is what exists there' );

# --- and it is read, not merely asked for ---------------------------------

my $listed = Tira::CLI::Serve::_processes_from_windows( [
    '"perl.exe","4321","Console","1","52,000 K"',
    '"prove.exe","4322","Console","1","9,000 K"',
    '',
] );
is( scalar @{$listed}, 2, 'tasklist output is read, and the blank line is not a process' );
is( $listed->[0]{pid}, 4321, 'with the process number' );
like( $listed->[0]{command}, qr/perl\.exe/, 'and what is running' );

# tasklist does not say when a process started, and inventing a time would make
# every age rule wrong rather than silent - which is worse. Said plainly
# instead, so a rule that needs an age can tell it does not have one.
ok( !defined $listed->[0]{started_at},
    'and no start time, because tasklist does not give one and an invented one would make every age wrong' );

done_testing();

__END__

=head1 NAME

118-world-on-windows.t - the world gatherer works on the platforms this ships to

=head1 DESCRIPTION

The gatherer asked whether a program existed using a search that looked for an
exact filename and tested it with -x. On Windows git is git.exe and -x answers
for the extension, so the search found nothing and every fact built on git came
back empty - along with the process table, since ps does not exist there.

Four rules from the git side and one from ps reported nothing on Windows
whatever the machine was doing, which is the defect the previous release was
about, reintroduced inside its own fix.

Driven from here rather than from the platform running the suite, because a
Windows claim that can only be checked on Windows is one that goes unchecked.

=cut
