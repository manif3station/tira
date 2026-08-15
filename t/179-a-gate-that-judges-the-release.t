#!/usr/bin/env perl
# The release gate proves the commits being pushed, not the desk they were
# written on.
#
# The pre-push suite ran against the working directory, so anything sitting
# there judged the release. Three times that refused a push for a reason that
# was not about it, and the third lost a release outright:
#
#     1.85  refused on t/86, because the next card had already added a rule to
#           the catalogue that was not yet implemented. The commit was green
#           when it was made and green again twenty minutes later; only the
#           tree it was judged against was ever wrong. 1.85 never reached
#           origin, and a card sat in done carrying a version nobody could
#           install until it was corrected by hand.
#
# Before that: a red test written for the NEXT card refused a finished one, and
# the repair both times was to move work in progress out of the way by hand -
# which is exactly the habit a gate people retry past produces. TKT-176's own
# words apply unchanged: a release refused for a reason that is not about the
# release teaches whoever is pushing to retry rather than to read.
#
# It is the standing state of this repository rather than an unusual one. The
# process is write the failing test first, and the process is also push each
# card as it finishes, so every release made while the next card is in tests-red
# meets this.
#
# What replaces it must be STRICTER, not looser. Testing a clean checkout of
# what is being pushed catches something the old way could not: a commit that
# passes only because of an uncommitted file - a test helper never added, a
# module still sitting unstaged - which reads as green on the desk and is broken
# for everybody else.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira::CLI;

plan skip_all => 'git is not installed here' if !Tira::CLI::_program_exists('git');

my $hook = File::Spec->catfile(qw(tools hooks pre-push));
ok( -f $hook, 'the gate ships in the repository rather than only in .git/hooks' );

open my $fh, '<', $hook or die "$hook: $!";
my $source = do { local $/; <$fh> };
close $fh;

# --- it builds a checkout of what is being pushed ------------------------------------

like( $source, qr/git worktree add/,
    'the gate makes a checkout of the commits being pushed' );
like( $source, qr/worktree add[^\n]*\bHEAD\b/,
    'at the commit being pushed rather than at whatever is lying around' );

# --- and runs the suite against that, not against the desk ------------------------------
#
# The container mounts the skill directory. Overriding that mount for the run is
# what makes the suite see the checkout at the path it expects, so the rest of
# the harness needs no knowledge of any of this.

like( $source, qr/-v\s+"?\$\{?\w+\}?:\/workspace\/skills\/tira/,
    'and mounts it over the path the suite runs in' );

# --- and takes it away afterwards, however it ends -------------------------------------
#
# A gate that leaves a checkout behind on every failure fills the disk of the
# machine it is protecting. The cleanup has to survive the failure paths, which
# are the common ones.

like( $source, qr/git worktree remove/, 'the checkout is removed' );
like( $source, qr/\btrap\b[^\n]*(?:EXIT|INT|TERM)/,
    'on the way out however the gate ends, because its failure paths are the busy ones' );

# --- proved on git itself, rather than asserted about a script -------------------------
#
# The whole claim is that a checkout at HEAD carries what was committed and
# nothing else. That is a property of git rather than of this repository, so it
# is shown rather than trusted.

my $tmp = tempdir( CLEANUP => 1 );
my $repo = File::Spec->catdir( $tmp, 'repo' );
mkdir $repo;

# Each argument quoted rather than joined with spaces. The first version let
# the shell split them and every call came back "Syntax error", which read as
# git refusing rather than as the test never asking it anything.
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

$git->( $repo, 'init', '-q', '.' );
$git->( $repo, 'config', 'user.email', 'gate@test' );
$git->( $repo, 'config', 'user.name', 'gate' );

my $committed = File::Spec->catfile( $repo, 'committed.t' );
open my $good, '>', $committed or die $!;
print {$good} "ok 1\n";
close $good;
$git->( $repo, 'add', '-A' );
$git->( $repo, 'commit', '-q', '-m', 'a green commit' );

# The state this whole card is about: the next card's failing test, written and
# not committed, sitting beside a finished one.
my $wip = File::Spec->catfile( $repo, 'next-card.t' );
open my $red, '>', $wip or die $!;
print {$red} "not ok 1 - the next card, not this release\n";
close $red;

my $checkout = File::Spec->catdir( $tmp, 'checkout' );
my ( $status, $said ) = $git->( $repo, 'worktree', 'add', '--detach', '--quiet', $checkout, 'HEAD' );
is( $status, 0, 'a checkout of the pushed commit can be made' ) or diag($said);

ok( -f File::Spec->catfile( $checkout, 'committed.t' ),
    'and it carries what was committed' );
ok( !-e File::Spec->catfile( $checkout, 'next-card.t' ),
    'and not the work in progress that has nothing to do with this release' );

# --- while a broken commit is still caught ------------------------------------------------
#
# The point of being stricter. If the checkout carried only what happens to be
# on disk this would be a way of shipping anything.

{
    my $broken = File::Spec->catfile( $repo, 'broken.t' );
    open my $bad, '>', $broken or die $!;
    print {$bad} "not ok 1 - committed and broken\n";
    close $bad;
    $git->( $repo, 'add', '-A' );
    $git->( $repo, 'commit', '-q', '-m', 'a commit that is genuinely broken' );

    my $second = File::Spec->catdir( $tmp, 'second' );
    $git->( $repo, 'worktree', 'add', '--detach', '--quiet', $second, 'HEAD' );
    ok( -f File::Spec->catfile( $second, 'broken.t' ),
        'a commit that is broken on its own is in the checkout, so it still fails the gate' );
}

# --- and a green desk cannot hide a commit that is missing a file ----------------------------
#
# The case the old way could not catch at all, and the reason this is stricter
# rather than looser: a module or helper that was never added reads as green on
# the desk and is broken for everybody else.

{
    my $helper = File::Spec->catfile( $repo, 'helper.pm' );
    open my $h, '>', $helper or die $!;
    print {$h} "1;\n";
    close $h;    # written, never added

    my $third = File::Spec->catdir( $tmp, 'third' );
    $git->( $repo, 'worktree', 'add', '--detach', '--quiet', $third, 'HEAD' );
    ok( !-e File::Spec->catfile( $third, 'helper.pm' ),
        'a file that was never committed is absent from the checkout, so the gate meets what everybody else would' );
}

done_testing;

__END__

=head1 NAME

179-a-gate-that-judges-the-release.t - the gate proves the commits, not the desk

=head1 DESCRIPTION

The pre-push suite ran against the working directory, so uncommitted work judged
the release. It refused three pushes for reasons that were not about them, and
the third lost 1.85 entirely - refused because the next card had already added a
rule to the catalogue that was not yet implemented.

The gate now runs its suite against a checkout of the commits being pushed,
mounted over the path the container expects, and removes it however the run
ends. That is stricter than before rather than looser: a commit that passes only
because of an uncommitted file no longer passes at all.

=cut
