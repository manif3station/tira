#!/usr/bin/env perl
# A board that says where its work lives is still backed up where it lives.
#
# Reported from developer-dashboard on 2026-08-15, and it is a regression I
# shipped. board-unbacked was raised at 07:55, escalated at 08:00 and again at
# 08:15, and between those the board was backed up three times - 08:02, 08:03,
# 08:16 - against a seven-day age. A backup twelve minutes before an escalation
# cannot leave the rule open, and it did.
#
# His guess was that police gathers the machine facts once rather than per
# round, which would make any machine-fact rule unclearable. It does not: the
# follow loop gathers them every round and says why. Believing the guess would
# have produced a fix for something that was already right.
#
# The cause is one variable answering two questions. _police_world resolves
# $where to the repository a project declared, falling back to the board
# directory, and then asks everything with it. Branches, work trees, unpushed
# commits and whether the tree is changing all want the repository. The backup
# lookup wants the board: _backup_store is <root>/.tira, which is where
# tira.backup writes and the only place it ever writes.
#
# So a board that declares a repository has its backups looked for inside the
# code, where there are none, and is told it has never been backed up - for
# ever, no matter what anybody does. A board that declares nothing has the two
# directories in the same place and works, which is why this project's own board
# settled the same rule at 07:28 while his could not.
#
# That $where arrived with TKT-178, which taught police to read the declared
# repository so card-sandbox-missing would stop reporting branches that exist.
# It fixed exactly the boards this broke, which is why he could report one rule
# settling promptly in the same breath as the other never settling.

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
# Tira::CLI::Police holds the police pass, the bridge and the world scan since
# 4.74 (TKT-607). Tira::CLI loads it with require at the point a police verb
# runs, so a test calling into it directly has to ask for it itself.
require Tira::CLI::Police;
# Tira::CLI::Serve holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Serve;

plan skip_all => 'git is not installed' if !Tira::CLI::Serve::_program_exists('git');

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Declared', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);

# Where the work lives, which is not where the board lives - his arrangement,
# and the ordinary one for a project whose board is kept outside its code.
my $repo = File::Spec->catdir( $tmp, 'code' );
make_path( File::Spec->catdir( $repo, '.git' ) );
$tira->project_update( project => $root, repo => $repo );

$tira->policy_add( project => $root, rule => 'board-unbacked', age => '7d',
    action => 'bridge-reminder' );

sub unbacked {
    my $world = Tira::CLI::Police::police_world( tira => $tira, project => $root );
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police' ), world => $world );
    return ( [ grep { $_->{rule} eq 'board-unbacked' } @{ $pass->{violations} } ], $world );
}

# --- before any backup, the rule is right -------------------------------------------

{
    my ($found) = unbacked();
    is( scalar @{$found}, 1, 'a board that has never been backed up is told so' );
}

# --- then it is backed up ------------------------------------------------------------

do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'backup', tira => $tira,
    argv => [ '-o', 'json' ] ) };

my ( $found, $world ) = unbacked();
ok( defined $world->{backed_up_at},
    'the backup is found, in the board where tira.backup wrote it' );
is_deeply( $found, [],
    'and a board that declares a repository is cleared by backing it up' );

# --- while the other five machine facts still read the repository ----------------------
#
# The half TKT-178 fixed. Answering the backup question against the board must
# not send branches and work trees back to the board, or this trades one
# project's broken rule for another's.

{
    ok( exists $world->{branches},  'branches are still gathered' );
    ok( exists $world->{worktrees}, 'and work trees' );
}

# --- and a board that declares nothing is unchanged -------------------------------------

{
    my $plain = File::Spec->catdir( $tmp, 'plain' );
    my $other = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
    $other->project_new(
        name => 'Plain', dir => $plain, members => ['claude'],
        columns => ['backlog, done'],
        sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
    );
    $other->policy_add( project => $plain, rule => 'board-unbacked', age => '7d',
        action => 'bridge-reminder' );
    do { local $ENV{TIRA_HOME} = $plain; Tira::CLI->run( command => 'backup', tira => $other,
        argv => [ '-o', 'json' ] ) };

    my $world = Tira::CLI::Police::police_world( tira => $other, project => $plain );
    ok( defined $world->{backed_up_at},
        'a board that declares no repository is found exactly as before' );
}

done_testing;

__END__

=head1 NAME

188-backed-up-where-the-board-is.t - a declared repository does not hide the backups

=head1 DESCRIPTION

C<_police_world> resolved one variable for two questions: the repository a
project declared, used for branches, work trees, commits and the changing tree,
and also used to look for backups. C<tira.backup> writes into the board's own
storage and nowhere else, so a board that declared a repository had its backups
looked for inside the code and was told it had never been backed up - permanently,
whatever anybody did about it.

=cut
