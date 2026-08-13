#!/usr/bin/env perl
# A board can be backed up with a command that ships.
#
# board-unbacked has been reporting "the board has never been backed up" on his
# own bridge, and Tira shipped nothing that could back one up. What wrote the
# backups the rule reads was tools/board-backup - a development tool inside
# Tira's own repository, run by its push gate. On that repository the rule works
# and there are 287 backups; on anybody else's board it fires, the escalation
# line points at tira.policy.list, which backs nothing up, and there is no
# command that would clear it. A rule that can only be obeyed by switching it
# off teaches whoever reads the bridge that some lines are not worth acting on,
# which is the failure police exists to prevent.
#
# He asked for what he asked for: "Use Git. git init, git add ., git commit. And
# Tira should manage the local git repo." The repository sits beside project.yml,
# has no origin, and a backup is a commit.
#
# The reason it matters at all is on the record: the dev board was destroyed on
# 11 August with nothing to restore from, because a Tira board lives outside git
# by design. Every board using this skill has that hole.
#
# Git is run from the CLI layer and never from the engine, which invokes no
# shell or external process - the guarantee in docs/foundation.md that lets Tira
# be trusted inside another tool.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-13T12:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Backed up', dir => $root, members => ['michael'],
    columns => ['backlog, doing, done'],
    sow_prefix => 'BUS', epic_prefix => 'BUE', ticket_prefix => 'BUT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Worth keeping' );

my $note = File::Spec->catfile( $tmp, 'evidence.txt' );
open my $fh, '>', $note or die $!;
print {$fh} "something worth not losing\n";
close $fh;
$tira->attachment_add( project => $root, ref => $card->{ref}, file => $note );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => shift(@argv), tira => $tira,
            argv => [ '--project', $root, @argv ] );
    };
    return ( $status, $out, $err );
}

my $store = File::Spec->catdir( $root, '.tira' );
my $repository = File::Spec->catdir( $store, '.git' );

# --- nothing is created by asking -------------------------------------------
#
# A board that leaves backups out must be untouched on disk. A command that
# creates a repository just by being asked a question would put one on every
# board that ever ran a police pass.

ok( !-d $repository, 'a board that has never been backed up has no repository' );
is( Tira::CLI::_last_backup_commit($store), undef, 'and nothing to report about one' );
ok( !-d $repository, 'and asking did not make one' );

# --- the first backup ---------------------------------------------------------

my ( $status, $out ) = run( 'backup', '-o', 'json' );
is( $status, 0, 'a board can be backed up' );
my $first = decode_json($out);
ok( -d $repository, 'the first backup creates the repository beside project.yml' );
ok( $first->{commit}, 'and reports the commit it made' );
is( $first->{created}, 1, 'saying it was the first, because that is worth knowing' );

# --- and it really holds the board ------------------------------------------
#
# A commit that exists and holds nothing is the shape of every backup nobody
# tested. The card and the attachment have to be in it.

my $tracked = join "\n", @{ Tira::CLI::_reading( 'git', '-C', $store, 'ls-tree', '-r', '--name-only', 'HEAD' ) };
like( $tracked, qr/project\.yml/, 'the commit holds the project' );
like( $tracked, qr/\Q$card->{ref}\E/, 'and the card' );
like( $tracked, qr{attachments/}, 'and the attachments, because a backup is everything or it is not one' );

# --- the lock is not board state --------------------------------------------
#
# Restoring a lock file would restore somebody else's half-finished write. It is
# the one thing under .tira that is about right now rather than about the board.

unlike( $tracked, qr/\.lock/, 'the lock is left out, because a restored lock is a wedged board' );

# --- nothing changed is not a failure ---------------------------------------
#
# Police asks for a backup on a schedule. If backing up an unchanged board were
# an error, the rule would teach whoever reads it to ignore the command.

( $status, $out ) = run( 'backup', '-o', 'json' );
is( $status, 0, 'backing up an unchanged board is not an error' );
my $again = decode_json($out);
is( $again->{changed}, 0, 'it says nothing had changed' );
is( $again->{commit}, $first->{commit}, 'and points at the backup that still stands' );

# --- a change is a new commit -----------------------------------------------

$tira->record_update( project => $root, ref => $card->{ref}, description => 'now it says something' );
( $status, $out ) = run( 'backup', '-o', 'json' );
is( $status, 0, 'a changed board backs up again' );
my $second = decode_json($out);
isnt( $second->{commit}, $first->{commit}, 'as a new commit' );
is( $second->{changed}, 1, 'saying that something had changed' );
is( $second->{created}, 0, 'and that the repository was already there' );

# --- when the last one was ---------------------------------------------------
#
# What board-unbacked has to read. A directory of stamps was the old answer and
# only one repository on earth wrote it.

my $when = Tira::CLI::_last_backup_commit($store);
like( $when, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/, 'the last backup is readable as a time' );

# --- no origin ----------------------------------------------------------------
#
# A board that lives on a filesystem must not need somebody else's machine to be
# backed up.

is_deeply( Tira::CLI::_reading( 'git', '-C', $store, 'remote' ), [],
    'the repository has no remote, so a backup cannot fail because a server is down' );

# --- and the engine still touches nothing ------------------------------------
#
# The guarantee that lets Tira be trusted inside another tool. Backing up is a
# command, not something the engine does.

ok( !Tira->can('backup'), 'the engine has no backup of its own to run' );

done_testing;

__END__

=head1 NAME

125-a-board-can-back-itself-up.t - a board can be backed up with a command that ships

=head1 DESCRIPTION

C<board-unbacked> reported that a board had never been backed up while Tira
shipped nothing that could back one up: the backups it read were written by a
development tool inside Tira's own repository. Every other board could obey the
rule only by switching it off.

C<tira.backup> makes a commit in a git repository Tira manages beside
F<project.yml>, created on first use and carrying the cards and the attachments.
It has no remote, an unchanged board is not an error, and a board that never
backs up has no repository at all. Git is run from the CLI layer, because the
engine invokes no external process.

=cut
