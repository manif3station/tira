#!/usr/bin/env perl
# A board only restarts into code that is not already the code it is running.
#
# The dashboard restarts itself when a new version is installed, so a board
# left open for a week picks up the new code instead of serving last week's.
# It decided that by reading VERSION out of .env and comparing it to the
# version compiled into the module it had loaded.
#
# Those are two different things, and .env is the one a restart cannot change.
# If the label moves and the code does not - a half-finished release, a bumped
# .env, an install that copied one file and not the other - then every check
# fires, the process restarts, loads exactly the same module, disagrees with
# .env again, and restarts again. Nothing converges, because restarting was
# what was supposed to make them agree.
#
# It cost twice in one morning:
#
#   - His four boards have been doing it every sixty seconds since Wednesday.
#     _restart_if_updated is called from the closure that serves /data, and a
#     starman worker is not the board - the master owns the socket, so the new
#     process cannot bind the port and dies, the master forks another, and the
#     next poll does it again. Twenty hours, one lost request a minute, and the
#     board never upgraded.
#
#   - The test suite hung. t/59-waiting-cards.t stubs the browser server the
#     way every board test does; it does not stub the restarter, because until
#     now nothing needed to. With .env one version ahead of the module, the
#     test process exec'd itself into the real entrypoint and served a real
#     board on port 7899, holding prove's stdout open for ever. Eighteen
#     minutes at 0.01 percent CPU, which looks exactly like a slow test.
#
# So the question the check asks changes. Not "does the label on disk differ
# from mine" but "would restarting run different code than I am running". The
# answer lives in the module on disk, which is the thing exec would load.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Restarting', dir => $root, columns => ['Backlog, Doing'] );
$tira->create_record( project => $root, type => 'ticket', title => 'Something to serve' );

# Served exactly the way the board serves it, with the restart driven through
# the same closure the page polls. Nothing here may reach a real server: the
# browser is stubbed, and the restarter is deliberately NOT a no-op - it
# records, so a restart that should not happen is caught rather than hidden.
sub serve {
    my (%args) = @_;
    my @restarted;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    my $captured;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        no warnings 'redefine';
        local *Tira::installed_version = sub { $args{env} } if exists $args{env};
        local *Tira::CLI::_version_on_disk = sub { $args{disk} } if exists $args{disk};
        Tira::CLI->run(
            command => 'dashboard', type => 'ticket',
            argv => [ '--project', $root, '-o', 'browser' ],
            tira => $tira,
            browser_server => sub { my %given = @_; $captured = \%given; return 1 },
            restarter => sub { push @restarted, [@_]; return 1 },
        );
        $captured->{data}->() if $captured;
    }
    return \@restarted;
}

# --- the code on disk is newer, so there is something to restart into -------

is( scalar @{ serve( env => '9.99', disk => '9.99' ) }, 1,
    'a board whose code on disk has moved on restarts into it' );

# --- the label moved and the code did not ----------------------------------
#
# The case that has been running his boards into the ground since Wednesday.
# Restarting would load the module already loaded, so it changes nothing, so
# it does not happen.

is( scalar @{ serve( env => '9.99', disk => $Tira::VERSION ) }, 0,
    'a board whose .env moved without its code does not restart into itself' );

# --- and it is the disk that decides, not the label ------------------------
#
# The opposite skew, which is the shape of a half-copied install: the module
# on disk is new and .env still says what it said. There is genuinely new code
# to run, so the board takes it.

is( scalar @{ serve( env => $Tira::VERSION, disk => '9.99' ) }, 1,
    'new code with an unchanged label is still new code, and is picked up' );

# --- nothing known, nothing done -------------------------------------------
#
# An unreadable version was already refused, for exactly this reason. It stays
# refused, and an unreadable module on disk is refused the same way, because
# guessing here costs a running board.

is( scalar @{ serve( env => undef, disk => '9.99' ) }, 0,
    'an unreadable .env restarts nothing, as before' );
is( scalar @{ serve( env => '9.99', disk => undef ) }, 0,
    'and neither does a module on disk that cannot be read' );

# --- the reader itself ------------------------------------------------------
#
# It has to answer about the file exec would load. Asked about this checkout it
# must agree with the module in memory - if it does not, every board restarts
# for ever, which is the fault this test exists to end.

is( Tira::CLI::_version_on_disk(), $Tira::VERSION,
    'the version read off disk is the version this process is running' );

my $missing = File::Spec->catfile( $tmp, 'no-such-module.pm' );
is( Tira::CLI::_version_on_disk($missing), undef,
    'a module that is not there reads as unknown rather than as a difference' );

my $silent = File::Spec->catfile( $tmp, 'Quiet.pm' );
open my $fh, '>', $silent or die $!;
print {$fh} "package Quiet;\n1;\n";
close $fh;
is( Tira::CLI::_version_on_disk($silent), undef,
    'and a module that declares no version reads as unknown too' );

done_testing;

__END__

=head1 NAME

123-a-restart-that-would-change-nothing.t - a board restarts into new code, not into itself

=head1 DESCRIPTION

The dashboard restarts itself when a new version is installed. It decided that
by comparing the label in F<.env> against the version compiled into the module
it had loaded - two things a restart cannot reconcile, because restarting loads
the same module again.

When the label moved and the code did not, every check fired and every restart
achieved nothing. His boards did it every sixty seconds for twenty hours, losing
a request each time and never upgrading; the test suite did it once and hung for
ever, because the test process exec'd itself into a real web server holding
prove's stdout open.

The check now asks whether restarting would run different code, by reading the
version out of the module on disk - the file exec would actually load. Unknown
on either side restarts nothing, as an unreadable F<.env> already did.

=cut
