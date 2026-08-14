#!/usr/bin/env perl
# The world police is handed has to be the real one.
#
# Every rule about the machine rather than the board reads a fact out of
# $world: a running process, a running container, a commit, when the tree last
# changed, when the last push was, when the board was last backed up. The
# engine never looks for those itself, on purpose - Tira invokes no shell, and
# that guarantee is what lets it be trusted inside another tool. The command is
# supposed to look for them and hand them in.
#
# It did not. _police_world returned five empty lists and nothing else, so six
# declared rules evaluated against nothing and stayed silent - which is
# indistinguishable from a board with nothing wrong, and is the exact sentence
# police prints to the owner when a rule is missing entirely.
#
# Found on 2026-08-12 by running police against this board and watching
# board-unbacked report "the board has never been backed up" while the backups
# it was asking for sat in ~/.tira-backups, written by the push gate itself.

use strict;
use warnings;

use File::Path ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-12T17:30:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Worldly', dir => $root, members => ['michael'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'WLS', epic_prefix => 'WLE', ticket_prefix => 'WLT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

# --- what the command gathers ---------------------------------------------
#
# Named one at a time rather than counted, so a field quietly dropped from the
# gatherer fails by name instead of by arithmetic.

my $world = Tira::CLI::_police_world( project => $root );

for my $list (qw(branches worktrees processes containers commits)) {
    is( ref $world->{$list}, 'ARRAY', "$list is gathered as a list" );
}

for my $fact (qw(working_since unpushed_since backed_up_at card_in_progress)) {
    ok( exists $world->{$fact},
        "$fact is gathered, rather than left absent for a rule to read as nothing wrong" );
}

# --- the fact that started this -------------------------------------------
#
# tools/board-backup writes ~/.tira-backups/<slug>/<stamp>, one directory per
# run, named for the moment it ran. Police was never shown them, so the rule
# could only ever say "never".

my $backups = File::Spec->catdir( $tmp, 'backups', 'a-board' );
File::Path::make_path( File::Spec->catdir( $backups, '20260812T164254Z' ) );

my $seen = Tira::CLI::_police_world( project => $root, backups => $backups );
like( $seen->{backed_up_at}, qr/\A2026-08-12T16:42:54/,
    'a backup that exists is found, and read as the moment it was taken' );

my $none = Tira::CLI::_police_world(
    project => $root, backups => File::Spec->catdir( $tmp, 'backups', 'never-backed-up' ) );
ok( !defined $none->{backed_up_at},
    'and a board with no backup at all still says so, rather than inventing one' );

File::Path::make_path( File::Spec->catdir( $backups, '20260812T170000Z' ) );
my $newest = Tira::CLI::_police_world( project => $root, backups => $backups );
like( $newest->{backed_up_at}, qr/\A2026-08-12T17:00:00/,
    'the most recent backup is the one that counts, not the first one found' );

# --- and the rule goes quiet once it can see them --------------------------
#
# Proved through the rule rather than through the field, because a field with
# the right value in it and a rule that still fires is a fix that has not
# landed.

$tira->policy_add( project => $root, rule => 'board-unbacked', age => '24h',
    action => 'bridge-reminder' );

sub police {
    my ($handed) = @_;
    return $tira->police_pass( project => $root, store => $store, world => $handed );
}

is( scalar @{ police($newest)->{violations} }, 0,
    'board-unbacked is satisfied by a backup taken half an hour ago' );
is( scalar @{ police($none)->{violations} }, 1,
    'and fires when there really is no backup' );

# --- the boundary it must not cross ----------------------------------------
#
# The whole reason the world is gathered out here is that the engine promises
# to invoke nothing. Gathering it must not quietly move that line.

my $engine = do { local $/; open my $fh, '<', 'lib/Tira.pm' or die $!; <$fh> };
# Code only. The prose in this file says "system" and quotes commands in
# backticks all over, and a check that reads its own documentation as a
# violation is a check nobody will keep.
$engine =~ s/^=\w.*?^=cut//gmsx;
$engine =~ s/^\s*#.*$//gm;
# Perl's own calls, not anything that merely reads like one. The browser
# JavaScript this module serves contains pattern.exec(text), and a check that
# reports its own dashboard as a shell invocation is a check nobody will keep -
# so a preceding dot or word character rules the match out.
like( $engine, qr/package Tira/,
    'the engine source really was read, so the denial below is about code' );
unlike( $engine,
    qr/(?: qx[\{\(\/] | (?<![.\w]) system \s* \( | (?<![.\w]) exec \s* \( | open \s* \( [^)]* \| )/x,
    'the engine still invokes no shell, which is why the world is handed in at all' );

done_testing();

__END__

=head1 NAME

106-police-world.t - the world police is handed has to be the real one

=head1 DESCRIPTION

Every rule about the machine rather than the board reads a fact out of the
world it is given: a running process, a running container, a commit, when the
tree last changed, when the last push was, when the board was last backed up.
The engine never looks for any of it itself, because Tira invokes no shell -
the guarantee that lets it be trusted inside another tool.

The command that gathers those facts returned five empty lists and nothing
else, so six declared rules evaluated against nothing and stayed silent. A rule
that is silent because it was shown nothing looks exactly like a rule being
obeyed, which is the very sentence police prints when a rule is missing.

Found on 2026-08-12, when board-unbacked reported that the board had never been
backed up while the backups the push gate writes on every release sat in the
owner's home directory.

=cut
