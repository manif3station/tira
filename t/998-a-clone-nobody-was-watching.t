#!/usr/bin/env perl
# TKT-998. unpushed-work's world scan reads exactly one repository - the
# project's declared repo, or the board's own directory - and his real
# working pattern is several clones of one remote, each doing its own
# work: CODE stays a pristine reference at origin/master and actual work
# happens in per-ticket clones at ~/Sandbox/<repo>/<card-ref>/. A clone
# with unpushed commits there was invisible to this rule unless it
# happened to be the one declared path.
#
# His answer (Q-140/Q-141): auto-discover every immediate subdirectory of
# ~/Sandbox/<basename of the declared repo>/, and watch each the same way
# the declared repo itself is watched.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;
require Tira::CLI::Police;
require Tira::CLI::Serve;

my $git = _which('git');
plan skip_all => 'git is not installed, and this rule is about repositories'
  if !$git;

my $tmp = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $tmp;

sub run_in {
    my ( $where, @c ) = @_;
    my @command = shift @c;
    push @command, ( '-C', $where ) if defined $where && $command[0] =~ /git\z/;
    return Tira::CLI::Serve::_reading( @command, @c );
}

sub init_repo {
    my ($dir) = @_;
    mkdir $dir;
    run_in( $dir, $git, 'init', '--quiet', '-b', 'master' );
    run_in( $dir, $git, 'config', 'user.email', 'test@example.invalid' );
    run_in( $dir, $git, 'config', 'user.name', 'A Test' );
    run_in( $dir, $git, 'config', 'commit.gpgsign', 'false' );
    return $dir;
}

sub commit_file {
    my ( $dir, $name, $message ) = @_;
    open my $fh, '>', File::Spec->catfile( $dir, $name ) or die $!;
    print {$fh} "$name\n";
    close $fh;
    run_in( $dir, $git, 'add', $name );
    run_in( $dir, $git, 'commit', '--quiet', '-m', $message );
}

# --- a bare "origin" every clone shares -------------------------------------

my $origin = File::Spec->catdir( $tmp, 'origin.git' );
mkdir $origin;
run_in( $origin, $git, 'init', '--quiet', '--bare', '-b', 'master' );

# --- CODE: the declared repo, pristine, always in sync with origin ---------

my $code = init_repo( File::Spec->catdir( $tmp, 'code' ) );
commit_file( $code, 'README', 'RLT-001 initial' );
run_in( $code, $git, 'remote', 'add', 'origin', $origin );
run_in( $code, $git, 'push', '--quiet', '-u', 'origin', 'master' );

my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'board' );
$tira->project_new(
    name => 'Watched', dir => $root, members => ['claude'], repo => $code,
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);

# --- a Sandbox clone with unpushed work, named the way he actually works ---

my $sandbox_clone = File::Spec->catdir( $tmp, 'Sandbox', 'code', 'RLT-042' );
mkdir File::Spec->catdir( $tmp, 'Sandbox' );
mkdir File::Spec->catdir( $tmp, 'Sandbox', 'code' );
run_in( undef, $git, 'clone', '--quiet', $origin, $sandbox_clone );
run_in( $sandbox_clone, $git, 'config', 'user.email', 'test@example.invalid' );
run_in( $sandbox_clone, $git, 'config', 'user.name', 'A Test' );
run_in( $sandbox_clone, $git, 'config', 'commit.gpgsign', 'false' );
commit_file( $sandbox_clone, 'FEATURE', 'RLT-042 work done in the sandbox clone, never pushed' );

# CODE itself stays clean - the whole point of his pattern.
is_deeply( Tira::CLI::Police::_unpushed_commits($code), [],
    'the declared repo itself has nothing unpushed - work happens in the clone' );

my $world = Tira::CLI::Police::police_world( tira => $tira, project => $root );

ok( scalar @{ $world->{commits} },
    'the world sees the unpushed commit even though it lives in a Sandbox clone, not the declared repo' );
ok( ( grep { $_->{subject} =~ /never pushed/ } @{ $world->{commits} } ),
    'and it is the right commit' );
ok( defined $world->{unpushed_since}, 'unpushed_since is set from the clone, not left empty' );

# --- a second clone with nothing unpushed changes nothing -------------------

my $quiet_clone = File::Spec->catdir( $tmp, 'Sandbox', 'code', 'RLT-050' );
run_in( undef, $git, 'clone', '--quiet', $origin, $quiet_clone );
my $again = Tira::CLI::Police::police_world( tira => $tira, project => $root );
is( scalar @{ $again->{commits} }, scalar @{ $world->{commits} },
    'a second, clean clone contributes nothing extra' );

# --- something under Sandbox that is not a git repository is skipped, not fatal -

mkdir File::Spec->catdir( $tmp, 'Sandbox', 'code', 'not-a-clone' );
my $safe = eval { Tira::CLI::Police::police_world( tira => $tira, project => $root ); 1 };
ok( $safe, 'a non-repository entry under the Sandbox directory does not blow up the scan' ) or diag($@);

# --- found along the way: _tree_changing_since's own "found" branch was
# never actually exercised anywhere in the suite - every existing caller's
# changed file happened to be gone by the time `stat` ran, so line 943
# onward stayed at zero. Not TKT-998's own scope, but the same file this
# card already touches. ------------------------------------------------

my $dirty_repo = init_repo( File::Spec->catdir( $tmp, 'dirty' ) );
commit_file( $dirty_repo, 'README', 'RLT-060 initial' );
open my $fh, '>', File::Spec->catfile( $dirty_repo, 'README' ) or die $!;
print {$fh} "changed, and still here when stat runs\n";
close $fh;
my $since = Tira::CLI::Police::_tree_changing_since($dirty_repo);
like( $since, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/,
    '_tree_changing_since reports a real timestamp when the changed file still exists to stat' );

done_testing();

sub _which {
    my ($name) = @_;
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        my $path = File::Spec->catfile( $dir, $name );
        return $path if -x $path;
    }
    return undef;
}

__END__

=head1 NAME

998-a-clone-nobody-was-watching.t - unpushed-work discovers every Sandbox
clone of the declared repository, not only the declared path itself

=head1 DESCRIPTION

TKT-998. C<police_world> now also globs every immediate subdirectory of
C<~/Sandbox/E<lt>basename of the declared repoE<gt>/> and merges each
clone's own unpushed commits into the world it hands the engine, so a
clone with work in progress is seen regardless of which path happens to
be the one declared repository.

=cut
