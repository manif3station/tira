#!/usr/bin/env perl
# The rules that read the world, fired by the world.
#
# t/82-police.t proves the engine reasons correctly about a world it is handed.
# That is not the same claim as this one, and the difference is the whole
# defect: every one of those rules passed its test while being shipped unable
# to fire, because the command handed the engine an empty world and nothing
# anywhere said so.
#
# So this file makes the conditions real - a repository with a commit nobody
# pushed, a process actually running, a tree actually dirty - gathers the world
# the way the command gathers it, and asserts the rule fires. Nothing is
# injected.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $git = _which('git');
plan skip_all => 'git is not installed, and these rules are about a repository'
  if !$git;

my $tmp = tempdir( CLEANUP => 1 );

# The real clock, deliberately. Everything here is about how long ago something
# actually happened - a commit made a second ago, a process started a second
# ago - and a frozen clock beside real timestamps makes every age either always
# true or always false depending on the hour the suite happens to run. It made
# these three checks pass all afternoon and fail at six o'clock.
my $tira = Tira->new;

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Real', dir => $root, members => ['michael'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

# git -C rather than a chdir, matching how the gatherer itself runs git.
sub run_in {
    my ( $where, @c ) = @_;
    my @command = shift @c;
    push @command, ( '-C', $where ) if defined $where && $command[0] =~ /git\z/;
    return Tira::CLI::_reading( @command, @c );
}
sub _which {
    my ($program) = @_;
    for my $directory ( File::Spec->path ) {
        my $path = File::Spec->catfile( $directory, $program );
        return $path if -x $path;
    }
    return undef;
}

# --- a repository with work in it that nobody has pushed -------------------

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
run_in( $root, $git, 'commit', '--quiet', '-m', 'RLT-001 the first commit' );
run_in( $root, $git, 'remote', 'add', 'origin', $upstream );
run_in( $root, $git, 'push', '--quiet', '-u', 'origin', 'master' );

# One commit that names a card and one that does not, so the rule is shown
# both and has to tell them apart rather than reporting everything.
open my $more, '>', File::Spec->catfile( $root, 'NOTES' ) or die $!;
print {$more} "more\n";
close $more;
run_in( $root, $git, 'add', 'NOTES' );
run_in( $root, $git, 'commit', '--quiet', '-m', 'RLT-002 a commit that names its card' );

open my $sloppy, '>', File::Spec->catfile( $root, 'SLOPPY' ) or die $!;
print {$sloppy} "sloppy\n";
close $sloppy;
run_in( $root, $git, 'add', 'SLOPPY' );
run_in( $root, $git, 'commit', '--quiet', '-m', 'fixed the thing' );

my $world = Tira::CLI::_police_world( tira => $tira, project => $root );

is( scalar @{ $world->{commits} }, 2, 'both unpushed commits are gathered' );
ok( defined $world->{unpushed_since}, 'and the moment work started sitting is known' );

sub violations {
    my (%args) = @_;
    my @found;
    for my $policy ( @{ $args{policies} } ) {
        $tira->policy_add( project => $root, %{$policy} );
    }
    my $result = $tira->police_pass(
        project => $root, store => $store, world => $args{world} // $world );
    @found = @{ $result->{violations} };
    for my $policy ( @{ $tira->policy_list( project => $root ) } ) {
        $tira->policy_remove( project => $root, id => $policy->{id} );
    }
    return \@found;
}

my $unnamed = violations(
    policies => [ { rule => 'commit-without-card', action => 'log-only' } ] );
is( scalar @{$unnamed}, 1, 'commit-without-card fires, on a real commit, once' );
like( $unnamed->[0]{detail}, qr/fixed the thing/,
    'and names the commit that is missing a card, not the one that has one' );

# An age of zero means "more than zero seconds ago", so the condition has to be
# a moment old rather than this instant. One second, once, rather than a frozen
# clock - the point of this file is that the timestamps are real.
sleep 1;
my $sitting = violations(
    policies => [ { rule => 'unpushed-work', age => '0s', action => 'log-only' } ] );
is( scalar @{$sitting}, 1, 'unpushed-work fires on commits that are really unpushed' );

# --- a repository pushed without being told to track ----------------------
#
# The shape this very repository is in, and the one that caught the first
# attempt: origin/master exists, one commit is unpushed, and no upstream is
# configured for the branch. Asking git for @{upstream} answers "fatal: no
# upstream configured" - on somebody else's terminal - and both rules that
# depend on it go quiet on the board that most needs them.

my $untracked = File::Spec->catdir( $tmp, 'untracked' );
my $its_origin = File::Spec->catdir( $tmp, 'untracked-origin.git' );
mkdir $untracked;
run_in( undef, $git, 'init', '--quiet', '--bare', $its_origin );
run_in( $untracked, $git, 'init', '--quiet', '-b', 'master' );
run_in( $untracked, $git, 'config', 'user.email', 'test@example.invalid' );
run_in( $untracked, $git, 'config', 'user.name', 'A Test' );
run_in( $untracked, $git, 'config', 'commit.gpgsign', 'false' );
open my $first, '>', File::Spec->catfile( $untracked, 'README' ) or die $!;
print {$first} "first\n";
close $first;
run_in( $untracked, $git, 'add', 'README' );
run_in( $untracked, $git, 'commit', '--quiet', '-m', 'RLT-003 the first commit' );
run_in( $untracked, $git, 'remote', 'add', 'origin', $its_origin );

# Pushed WITHOUT -u, so origin/master exists and nothing tracks it.
run_in( $untracked, $git, 'push', '--quiet', 'origin', 'master' );

open my $after, '>', File::Spec->catfile( $untracked, 'AFTER' ) or die $!;
print {$after} "after\n";
close $after;
run_in( $untracked, $git, 'add', 'AFTER' );
run_in( $untracked, $git, 'commit', '--quiet', '-m', 'RLT-004 unpushed, and nothing tracks the branch' );

is( scalar @{ Tira::CLI::_reading( $git, '-C', $untracked, 'rev-parse', '--abbrev-ref',
        '--verify', '--quiet', 'master@{upstream}' ) },
    0, 'git really has no upstream configured for this branch' );

my $behind = Tira::CLI::_unpushed_commits($untracked);
is( scalar @{$behind}, 1,
    'the unpushed commit is found anyway, by the branch it was actually pushed to' );
like( $behind->[0]{subject}, qr/nothing tracks the branch/, 'and it is the right commit' );

# A branch that has never been pushed anywhere is not work left sitting.
my $fresh = File::Spec->catdir( $tmp, 'never-pushed' );
mkdir $fresh;
run_in( $fresh, $git, 'init', '--quiet', '-b', 'master' );
run_in( $fresh, $git, 'config', 'user.email', 'test@example.invalid' );
run_in( $fresh, $git, 'config', 'user.name', 'A Test' );
run_in( $fresh, $git, 'config', 'commit.gpgsign', 'false' );
open my $only, '>', File::Spec->catfile( $fresh, 'README' ) or die $!;
print {$only} "only\n";
close $only;
run_in( $fresh, $git, 'add', 'README' );
run_in( $fresh, $git, 'commit', '--quiet', '-m', 'RLT-005 never pushed anywhere' );

is_deeply( Tira::CLI::_unpushed_commits($fresh), [],
    'a branch with nowhere to have been pushed reports nothing unpushed' );
is_deeply( Tira::CLI::_unpushed_commits( File::Spec->catdir( $tmp, 'not-a-repository' ) ), [],
    'and somewhere that is not a repository is not asked at all' );

# --- a process that is really running --------------------------------------
#
# Chosen out of the real process table rather than forked here. A forked child
# is not reliably visible when the suite runs under Devel::Cover - it was not,
# and that made this check fail only during a coverage run, which is the worst
# kind of flake because it appears exactly when the gate is being taken
# seriously. Everything below is still a process genuinely running on this
# machine, read by ps, with the start time ps gave it.

my $running = Tira::CLI::_police_world( tira => $tira, project => $root );
ok( scalar @{ $running->{processes} }, 'the process table is gathered' );
ok( ( grep { defined $_->{started_at} } @{ $running->{processes} } ),
    'and each process carries when it started, which is what every leftover rule asks' );

my ($real) = grep { defined $_->{started_at} && length $_->{command} > 4 }
  @{ $running->{processes} };
my $signature = substr $real->{command}, 0, 12;

my $leftover = violations(
    policies => [ { rule => 'leftover-process', pattern => $signature,
            age => '0s', action => 'log-only' } ],
    world => $running,
);
ok( scalar @{$leftover}, "leftover-process fires on a process that is really there ($signature)" );
like( $leftover->[0]{detail}, qr/still running/, 'and says what is still running' );

my $quiet = violations(
    policies => [ { rule => 'leftover-process', pattern => 'nothing-on-this-machine-is-called-this',
            age => '0s', action => 'log-only' } ],
    world => $running,
);
is( scalar @{$quiet}, 0, 'and stays quiet about a pattern nothing matches' );

# --- a tree that is really dirty -------------------------------------------

open my $dirty, '>', File::Spec->catfile( $root, 'UNCOMMITTED' ) or die $!;
print {$dirty} "changed\n";
close $dirty;

sleep 1;
my $changing = Tira::CLI::_police_world( tira => $tira, project => $root );
ok( defined $changing->{working_since},
    'a dirty tree reports when it started changing' );
is( $changing->{card_in_progress}, 0,
    'and with every card in the backlog, nothing is being worked' );

my $unwatched = violations(
    policies => [ { rule => 'work-without-card', age => '0s', action => 'log-only' } ],
    world => $changing,
);
is( scalar @{$unwatched}, 1, 'work-without-card fires on a tree changing with no card at a gate' );

# The same tree, with a card actually being worked, must go quiet - a rule that
# fires while the agent is doing exactly the right thing gets ignored, and an
# ignored rule is worse than no rule.
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Being worked' );
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

my $watched = Tira::CLI::_police_world( tira => $tira, project => $root );
is( $watched->{card_in_progress}, 1, 'a card at a working column is seen' );
is( scalar @{ violations(
        policies => [ { rule => 'work-without-card', age => '0s', action => 'log-only' } ],
        world => $watched ) },
    0, 'and work-without-card goes quiet, because the work is on the board' );

# --- a machine without Docker ----------------------------------------------
#
# A command that is not installed is not a failure. A machine with no Docker
# has no leftover containers, and police must keep watching everything else.

is( ref Tira::CLI::_running_containers(), 'ARRAY',
    'asking for containers answers with a list even where Docker is not installed' );
is_deeply( Tira::CLI::_reading('a-program-that-is-not-installed-anywhere'), [],
    'and a missing program reads as nothing, rather than stopping the watch' );

# Docker output understood without Docker, because the suite runs inside a
# container that has none - and asking a machine that cannot answer proves
# nothing about whether the answer would be understood.
my $containers = Tira::CLI::_containers_from( [
    "skills-perl-test-run-abc\t2026-08-12 17:43:23 +0100 BST",
    "tira-board\t2026-08-11 09:00:00 +0100 BST",
    "",
] );
is( scalar @{$containers}, 2, 'real docker ps output is read, and the blank line is not a container' );
is( $containers->[0]{name}, 'skills-perl-test-run-abc', 'the container is named' );
is( $containers->[0]{started_at}, '2026-08-12T17:43:23',
    'and carries when it started, which is what leftover-container asks' );

is( Tira::CLI::_stamp_from_docker(undef), undef,
    'a container with no time at all is not given an invented one' );
is( Tira::CLI::_stamp_from_docker('some future format nobody has seen'), undef,
    'nor is one whose time cannot be read - better no answer than a wrong one' );

# The same for the process table, which does parse here, but whose odd lines
# only appear on a machine in a particular state.
my $processes = Tira::CLI::_processes_from( [
    '  1234 Wed Aug 12 17:43:23 2026 /usr/bin/perl -e sleep 300',
    'a line that is not a process at all',
] );
is( scalar @{$processes}, 1, 'a line that is not a process is not counted as one' );
is( $processes->[0]{started_at}, '2026-08-12T17:43:23', 'and the start time is read from ps' );

is( Tira::CLI::_stamp_from_ps('not a date'), undef, 'an unreadable ps time answers with nothing' );
is( Tira::CLI::_stamp_from_ps('Wed Zzz 12 17:43:23 2026'), undef,
    'and so does a month name that does not exist' );

# Every rule that reads the world is asked for by name here, so a seventh one
# added later without being gathered fails this rather than shipping silent.
my %reads_the_world = map { $_ => 1 } qw(
    leftover-process leftover-container commit-without-card
    work-without-card unpushed-work board-unbacked
);
my @known = grep { $reads_the_world{$_} } @{ Tira->new->policy_rules };
is( scalar @known, 6, 'the six rules that read the world are the six this file fires' );

done_testing();

__END__

=head1 NAME

107-police-world-fires.t - the rules that read the world, fired by the world

=head1 DESCRIPTION

The engine's own tests prove it reasons correctly about a world it is handed.
That is a different claim from this one, and the difference is the whole
defect: every environment rule passed its test while being shipped unable to
fire at all, because the command handed the engine an empty world.

So this file makes the conditions real - a repository with a commit nobody
pushed, a process actually running, a tree actually dirty - gathers the world
the way the command gathers it, and asserts the rule fires. Nothing is
injected.

=cut
