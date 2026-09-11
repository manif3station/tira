#!/usr/bin/env perl
# TKT-1074. His own report, through the developer-dashboard bridge: the
# unpushed-work policy rule scans the declared repository and, since
# Q-140/Q-141 (TKT-998), every sandbox CLONE under ~/Sandbox/<repo>/ - but
# never a git WORKTREE (git worktree add, sharing the main repository's own
# .git object store rather than being a separate clone). police_world
# already collects worktree paths into $world->{worktrees} for
# card-sandbox-missing's own use, but never asked any of them for their
# unpushed commits, so a commit sitting only on a worktree branch was
# invisible to unpushed-work.
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
plan skip_all => 'git is not installed, and this rule is about a repository'
  if !$git;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new;

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Worktreed', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'WTS', epic_prefix => 'WTE', ticket_prefix => 'WTT',
);

sub run_in {
    my ( $where, @c ) = @_;
    my @command = shift @c;
    push @command, ( '-C', $where ) if defined $where && $command[0] =~ /git\z/;
    return Tira::CLI::Serve::_reading( @command, @c );
}
sub _which {
    my ($program) = @_;
    for my $directory ( File::Spec->path ) {
        my $path = File::Spec->catfile( $directory, $program );
        return $path if -x $path;
    }
    return undef;
}

# --- a real repository, pushed clean, then a worktree cut from it ----------

my $upstream = File::Spec->catdir( $tmp, 'upstream.git' );
run_in( undef, $git, 'init', '--quiet', '--bare', $upstream );
run_in( $root, $git, 'init', '--quiet', '-b', 'master' );
run_in( $root, $git, 'config', 'user.email', 'test@example.invalid' );
run_in( $root, $git, 'config', 'user.name', 'A Test' );
run_in( $root, $git, 'config', 'commit.gpgsign', 'false' );

open my $seed, '>', File::Spec->catfile( $root, 'README' ) or die $!;
print {$seed} "a repository\n";
close $seed;
run_in( $root, $git, 'add', 'README' );
run_in( $root, $git, 'commit', '--quiet', '-m', 'WTT-001 the first commit' );
run_in( $root, $git, 'remote', 'add', 'origin', $upstream );
run_in( $root, $git, 'push', '--quiet', '-u', 'origin', 'master' );

# The main checkout itself is clean - every commit that follows lives only on
# the worktree branch, so a world that only ever asked $root would report
# nothing at all.
my $worktree = File::Spec->catdir( $tmp, 'worktree' );
run_in( $root, $git, 'worktree', 'add', '--quiet', '-b', 'WTT-002-work', $worktree, 'master' );
# A worktree branch cut from master does not inherit master's own upstream
# tracking - a brand new branch nobody has ever pushed has nowhere to have
# been pushed, and correctly reports nothing unpushed (t/107 pins that same
# case for a plain branch). Michael's own report describes real sandboxes
# whose branches DO track a remote; set that up explicitly here rather than
# asserting a scenario this design deliberately treats as not-yet-work.
run_in( $worktree, $git, 'branch', '--set-upstream-to=origin/master', 'WTT-002-work' );
open my $work, '>', File::Spec->catfile( $worktree, 'CHANGE' ) or die $!;
print {$work} "in progress\n";
close $work;
run_in( $worktree, $git, 'add', 'CHANGE' );
run_in( $worktree, $git, 'commit', '--quiet', '-m', 'WTT-002 work sitting on a worktree branch' );

my $world = Tira::CLI::Police::police_world( tira => $tira, project => $root );

is( scalar @{ $world->{commits} }, 1, 'the worktree-only commit is gathered' );
ok( defined $world->{unpushed_since}, 'and the moment work started sitting is known' );
is( $world->{commits}[0]{subject}, 'WTT-002 work sitting on a worktree branch',
    'and it is genuinely the worktree commit, not something else' );

# --- the main checkout's own worktree entry is not double-counted ----------
#
# `git worktree list` names the main checkout first - it is a worktree of
# itself in git's own model - so a naive walk of every entry would count
# $root's own commits twice: once directly, once again as its own first
# worktree-list entry.

run_in( $root, $git, 'checkout', '--quiet', 'master' );
open my $direct, '>', File::Spec->catfile( $root, 'DIRECT' ) or die $!;
print {$direct} "on the main checkout\n";
close $direct;
run_in( $root, $git, 'add', 'DIRECT' );
run_in( $root, $git, 'commit', '--quiet', '-m', 'WTT-003 a commit on the main checkout itself' );

my $world2 = Tira::CLI::Police::police_world( tira => $tira, project => $root );
is( scalar @{ $world2->{commits} }, 2,
    'the main checkout is asked once, not twice, even though it is its own first worktree-list entry' );

done_testing;

__END__

=head1 NAME

t/1075-a-worktree-the-world-never-asked.t - unpushed-work sees commits
sitting only on a git-worktree branch

=head1 DESCRIPTION

TKT-1074. C<police_world> already collects worktree paths into
C<$world-E<gt>{worktrees}> for C<card-sandbox-missing>'s own use, but never
asked any of them for their unpushed commits the way a sandbox clone under
C<~/Sandbox/E<lt>repoE<gt>/> already is. A commit sitting only on a
worktree branch - C<git worktree add>, sharing the main repository's own
C<.git> object store - was invisible to C<unpushed-work>. Fixed by feeding
every worktree path into the same C<_unpushed_commits> scan, skipping the
main checkout's own entry (C<git worktree list> names it first) so it is
not counted twice.

=cut
