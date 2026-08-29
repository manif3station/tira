#!/usr/bin/env perl
# A project says where its repository is, rather than police guessing.
#
# developer-dashboard reported card-sandbox-missing firing on a card whose
# branch, directory and work tree all existed:
#
#     missing a branch named DD-532 (the machine reported 0 branches) and the
#     work tree it records, /home/mv/dd-worktree-sandbox/dd-532 - the machine
#     reported no work trees at all, which is what police watching the wrong
#     repository looks like
#
# The rule was right and its subject was wrong. Police runs git in the project
# directory - the one holding the board - and their board does not sit inside
# the repository the work happens in. _is_repository walks up from there, finds
# no .git, and every answer comes back empty. Nothing about the project could
# say otherwise.
#
# So a project declares its repository, and police reads that. The rule then
# gives the same verdict wherever the board lives and wherever police was
# started, which is the actual fault: a check whose subject depends on how it
# was launched cannot be relied on.
#
# Their third suggestion is here too, and it matters even with the first: a
# policy declared where no repository can be resolved should be refused when it
# is set, not discovered later as a violation nobody can clear. That is this
# project's own rule about missing arguments - a policy police cannot follow is
# worse than no policy, because it reads as cover.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira;
use Tira::CLI;
# Tira::CLI::Police holds the police pass, the bridge and the world scan since
# 4.74 (TKT-607). Tira::CLI loads it with require at the point a police verb
# runs, so a test calling into it directly has to ask for it itself.
require Tira::CLI::Police;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $tmp = tempdir( CLEANUP => 1 );

my $git = sub {
    my $where = shift;

    # Run rather than described to a shell. This built one string with each
    # argument single-quoted and ran it through backticks, which is correct
    # POSIX quoting and no quoting at all on Windows - where cmd.exe read the
    # quotes as part of the path and every call came back "The filename,
    # directory name, or volume label syntax is incorrect". -C rather than cd,
    # for the same reason. TKT-222.
    return run_capturing( 'git', '-C', $where, @_ );
};

# A repository somewhere else entirely, with a branch on it - their shape: the
# work is in one place and the board is in another.
my $repo = File::Spec->catdir( $tmp, 'work' );
mkdir $repo;
$git->( $repo, 'init', '-q', '.' );
$git->( $repo, 'config', 'user.email', 'work@test' );
$git->( $repo, 'config', 'user.name', 'work' );
open my $seed, '>', File::Spec->catfile( $repo, 'README' ) or die $!;
print {$seed} "work happens here\n";
close $seed;
$git->( $repo, 'add', '-A' );
$git->( $repo, 'commit', '-q', '-m', 'first' );

# The board, deliberately outside that repository.
my $board = File::Spec->catdir( $tmp, 'board' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Elsewhere', dir => $board, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ELS', epic_prefix => 'ELE', ticket_prefix => 'ELT',
);

# --- today, police finds nothing, because the board is not in a repository ---------

{
    my $world = Tira::CLI::Police::police_world( project => $board );
    is_deeply( $world->{branches}, [],
        'a board outside any repository reports no branches, which is what they saw' );
    is_deeply( $world->{worktrees}, [],
        'and no work trees, however many the real repository has' );
}

# --- a project can say where its repository is ------------------------------------

$tira->project_update( project => $board, repo => $repo );
is( $tira->project_show( project => $board )->{repo}, $repo,
    'a project records the repository its work lives in' );

# --- and police reads it ------------------------------------------------------------
#
# The whole point: the answer is the same wherever the board sits, because it no
# longer depends on where the board sits.

{
    my $world = Tira::CLI::Police::police_world( project => $board );
    ok( scalar @{ $world->{branches} },
        'police now reads the declared repository and finds its branches' );
    ok( scalar @{ $world->{worktrees} },
        'and its work trees' );
}

# --- a repository that is not one is refused when it is set --------------------------
#
# Discovered at declaration rather than as a violation nobody can clear.

{
    my $nowhere = File::Spec->catdir( $tmp, 'not-a-repo' );
    mkdir $nowhere;
    ok( !eval { $tira->project_update( project => $board, repo => $nowhere ); 1 },
        'a directory that is not a repository is refused' );
    like( $@, qr/repositor/i, 'saying what is wrong with it' );

    ok( !eval { $tira->project_update( project => $board, repo => '/no/such/place' ); 1 },
        'and so is one that is not there at all' );
}

# --- and a project that has declared nothing is unchanged ------------------------------
#
# No board upgrades into a different verdict. A project whose board does sit in
# its repository keeps working exactly as it did.

{
    my $inside = File::Spec->catdir( $repo, 'board-inside' );
    my $other = Tira->new;
    $other->project_new(
        name => 'Inside', dir => $inside, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'INS', epic_prefix => 'INE', ticket_prefix => 'INT',
    );
    my $world = Tira::CLI::Police::police_world( project => $inside );
    ok( scalar @{ $world->{branches} },
        'a board that does sit inside its repository still finds it, with nothing declared' );
}

# --- declaring the sandbox rule without a resolvable repository is refused ---------------
#
# Their third suggestion. A policy police cannot follow is worse than no policy,
# because it reads as cover - which is this project's own rule about missing
# arguments, applied to the one rule that reads the machine.

{
    my $stranded = File::Spec->catdir( $tmp, 'stranded' );
    my $lost = Tira->new;
    $lost->project_new(
        name => 'Stranded', dir => $stranded, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'SDS', epic_prefix => 'SDE', ticket_prefix => 'SDT',
    );

    ok( !eval {
            $lost->policy_add( project => $stranded, rule => 'card-sandbox-missing',
                enter => 'implement', sandbox => '/sandboxes', action => 'bridge-reminder' );
            1;
        },
        'declaring card-sandbox-missing where no repository can be resolved is refused' );
    like( $@, qr/repositor/i, 'saying so, rather than leaving it to be found as a violation' );

    # And accepted the moment the project says where to look.
    $lost->project_update( project => $stranded, repo => $repo );
    ok( eval {
            $lost->policy_add( project => $stranded, rule => 'card-sandbox-missing',
                enter => 'implement', sandbox => '/sandboxes', action => 'bridge-reminder' );
            1;
        },
        'and accepted once the project says where its repository is' ) or diag($@);
}

# --- while a board that IS in a repository can still declare it ---------------------------

{
    my $ok = File::Spec->catdir( $repo, 'board-ok' );
    my $fine = Tira->new;
    $fine->project_new(
        name => 'Fine', dir => $ok, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'FNS', epic_prefix => 'FNE', ticket_prefix => 'FNT',
    );
    ok( eval {
            $fine->policy_add( project => $ok, rule => 'card-sandbox-missing',
                enter => 'implement', sandbox => '/sandboxes', action => 'bridge-reminder' );
            1;
        },
        'a board inside a repository declares it without having to say where' ) or diag($@);
}

done_testing;

__END__

=head1 NAME

183-where-the-repository-is.t - a project says where its repository is

=head1 DESCRIPTION

C<card-sandbox-missing> reads the machine, and police ran git in the directory
holding the board. A project whose board does not sit inside the repository its
work happens in got empty answers to every question - no branches, no work trees
- and the rule reported every card as missing both, which is what
developer-dashboard saw.

A project can now declare its repository, and police reads that instead. A
directory that is not a repository is refused when it is set, and declaring
C<card-sandbox-missing> where no repository can be resolved is refused too,
rather than producing a violation nobody can clear. A board that does sit inside
its repository is unaffected.

=cut
