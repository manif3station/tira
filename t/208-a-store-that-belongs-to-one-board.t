#!/usr/bin/env perl
# A board's enforcement store belongs to that board and no other.
#
# The store was named for the --project OPTION rather than for the board police
# discovered, and substituted the word "here" when no option was given. Police
# started from inside a project directory passes no --project, so every board
# worked that way wrote to one shared directory.
#
# What is shared is not only the version each board last heard - which is why a
# board is never told about an upgrade another board already announced - but the
# violation numbering, the escalation counts, the suspensions and the bridge log
# they are written to.
#
# Measured before the fix: policing one board left the shared store saying board
# MT5 at version 2.01, and policing a different board from its own directory
# left the same file saying board Repro at 2.04. Two unrelated boards, one file.
#
# The correct pattern was already in the same file. _backup_home names its
# directory from the absolute path of the board "so two projects on one machine
# never write over each other", and returns undef rather than inventing a
# fallback when it has nothing to name.

use strict;
use warnings;

use Cwd ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

{
    local $ENV{HOME} = $tmp;

    my $one = Tira::CLI::_police_store('/tmp/board-one');
    my $two = Tira::CLI::_police_store('/tmp/board-two');

    isnt( $one, $two, 'two boards are given two stores' );
    like( $one, qr/board-one/, 'and each store is named for the board it belongs to' );

    # The fault itself: nothing to name meant a shared bucket rather than a
    # refusal, and a shared bucket is silent about being shared.
    my $nameless = eval { Tira::CLI::_police_store(undef) };
    my $refused  = $@;

    ok( $refused, 'a store with no board to name is refused rather than invented' );

    # Asserted on the refusal rather than on what was returned. Once the refusal
    # exists there is nothing returned to look at, so a check against the return
    # value would pass by having no subject - which is the shape t/147 exists to
    # catch, and the one this test would otherwise take on the moment it goes
    # green.
    like(
        $refused // '',
        qr/board/i,
        'and the refusal says what it was missing, rather than inventing a shared name'
    );
}

# And the half that matters at the call site: police started with no --project
# must still write to the store belonging to the board it discovered. The unit
# above can be correct while a caller hands it the option it was given, which is
# exactly the fault - so the board is discovered here the way police discovers
# it, and the store is required to be that board's.
{
    local $ENV{HOME} = $tmp;

    my $board = File::Spec->catdir( $tmp, 'watched' );
    my $tira  = Tira->new( clock => sub {'2026-08-15T17:00:00Z'} );
    $tira->project_new(
        name => 'Watched', dir => $board, members => ['michael'],
        columns => ['backlog, done'],
    );

    my $discovered = $tira->discover_project( project => $board );
    my $expected   = Tira::CLI::_police_store($discovered);

    unlike( $expected, qr/(?:\A|[\/])here\z/,
        'the store for a discovered board is never the shared one' );
    like( $expected, qr/watched/,
        'and carries the name of the board police is watching' );

    # The assertion that actually catches the fault. The two above test the
    # helper given a board, which always worked; the bug was a caller handing it
    # the option it was given instead. So police is run the way the owner runs
    # it - from inside the project, with no --project and no --store - and the
    # directory it creates is required to be that board's.
    $tira->policy_add(
        project => $board, rule => 'card-unassigned', action => 'bridge-reminder',
    );

    my $before = File::Spec->catdir( $tmp, '.tira-police' );
    mkdir $before;
    opendir my $was, $before or die $!;
    my %existed = map { $_ => 1 } readdir $was;
    closedir $was;

    # No --project, and standing in the board's own directory: the way the
    # owner starts it, and the only way that reaches the fault.
    my $back = Cwd::getcwd();
    chdir $board or die "cannot stand in the board: $!";
    eval {
        local *STDERR;
        open STDERR, '>', \my $noise;
        Tira::CLI->run( command => 'police', tira => $tira,
            argv => [ '--once', '-o', 'json' ] );
    };
    chdir $back or die "cannot return: $!";

    opendir my $now, $before or die $!;
    my @created = grep { !$existed{$_} && !/\A\.\.?\z/ } readdir $now;
    closedir $now;

    is_deeply( [ grep { $_ eq 'here' } @created ], [],
        'and police itself never creates the shared store' );
    ok( ( grep { /watched/ } @created ), 'it creates one named for the board it watched' );
}

done_testing;

__END__

=head1 NAME

208-a-store-that-belongs-to-one-board.t - one board, one store

=head1 DESCRIPTION

C<_police_store> named its directory for the C<--project> option and used the
word C<here> when none was given, so every board policed from its own directory
shared one enforcement store - one announced version, one violation ledger, one
bridge log.

C<_backup_home>, in the same file, already did it correctly: named from the
absolute path of the board, and undef rather than a fallback when there is
nothing to name.

=cut
