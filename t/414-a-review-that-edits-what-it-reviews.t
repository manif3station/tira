#!/usr/bin/env perl

# The mandated code review must not be able to destroy the work it reviews.
#
# The verify column's REQ-030 says "Ask Codex to do code review", so every card
# entering verify runs a reviewing agent against this checkout - and on
# 2026-08-27 one of them ran, inside this repository:
#
#   git diff -- README.md docs/POLICIES.md | head -120
#   git checkout -- README.md docs/POLICIES.md && git status --short
#
# Two documentation paragraphs, written while the review was running, were
# reverted to HEAD. Taken from that session's own log, not inferred. The loss is
# silent in the worst way: afterwards git status shows the files unmodified,
# which is indistinguishable from the edit never having been made.
#
# The read-only sandbox had refused to start twice - "Codex's Linux sandbox uses
# bubblewrap and needs access to create user namespaces" - which is what led to
# running with full access, which is what gave it the write.
#
# A flat copy of the changed files was tried on TKT-625 and is safe: three
# reviews, tree untouched each time, verified by md5. But the reviewer said,
# unprompted, that it "can't run the supplied test directly from this reduced
# directory because it has no lib/Tira.pm", and went looking in sibling project
# directories for dependencies. So the copy protects the tree by starving the
# reviewer and pointing it at unrelated work.
#
# A throwaway worktree is isolated AND complete: real history, whole tree, the
# suite can run, and a checkout inside it destroys only the throwaway.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

plan skip_all => 'git is not available' if system('git --version >/dev/null 2>&1') != 0;

my $tool = abs_path('tools/review-worktree') // 'tools/review-worktree';
my $have_tool = -e $tool && -x $tool;
ok( $have_tool, 'tools/review-worktree exists and is executable' );

SKIP: {
    skip 'tools/review-worktree has not been written yet', 14 if !$have_tool;

# --- a repository with committed history and uncommitted work in it ----------

my $tmp  = tempdir( CLEANUP => 1 );
my $repo = File::Spec->catdir( $tmp, 'repo' );
make_path($repo);

sub git_in { my ( $dir, @args ) = @_; return system( 'git', '-C', $dir, @args ) == 0; }

git_in( $repo, 'init', '--quiet' ) or plan skip_all => 'could not create a test repository';
git_in( $repo, 'config', 'user.email', 'test@example.invalid' );
git_in( $repo, 'config', 'user.name',  'Test' );

sub write_file {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text // '';
}

my $doc = File::Spec->catfile( $repo, 'DOC.md' );
write_file( $doc, "committed line\n" );
my $lib = File::Spec->catdir( $repo, 'lib' );
make_path($lib);
write_file( File::Spec->catfile( $lib, 'Thing.pm' ), "package Thing;\n1;\n" );
git_in( $repo, 'add', '-A' );
git_in( $repo, 'commit', '--quiet', '-m', 'first' );

# The uncommitted work - the shape that was lost.
write_file( $doc, "committed line\nA PARAGRAPH WRITTEN WHILE THE REVIEW RAN\n" );

like( read_file($doc), qr/A PARAGRAPH WRITTEN WHILE THE REVIEW RAN/,
    'the tree holds uncommitted work before the review runs' );

# --- the review sees the uncommitted work ------------------------------------
#
# Isolation that hides the change under review would satisfy "do not destroy it"
# by making the review worthless, which is the second acceptance criterion.

my $seen = File::Spec->catfile( $tmp, 'seen.txt' );
my $rc   = system( $tool, $repo, 'sh', '-c', "cat DOC.md > '$seen'; ls lib/Thing.pm >> '$seen'" );
is( $rc, 0, 'the tool runs a command inside the worktree and reports success' );

my $review_saw = read_file($seen);
like( $review_saw, qr/A PARAGRAPH WRITTEN WHILE THE REVIEW RAN/,
    'the reviewer sees the uncommitted work, not just what was committed' );
like( $review_saw, qr{lib/Thing\.pm},
    'and it sees the rest of the tree too - the flat copy could not run anything' );

# --- the review cannot destroy it --------------------------------------------
#
# The exact command that did the damage, run deliberately.

my $rc_destructive = system( $tool, $repo, 'sh', '-c', 'git checkout -- . && git status --short' );
is( $rc_destructive, 0, 'a destructive review command still completes' );

like( read_file($doc), qr/A PARAGRAPH WRITTEN WHILE THE REVIEW RAN/,
    'and the uncommitted work is STILL THERE - checked by reading the file, not by trusting git status' );

# --- the REPOSITORY is isolated, not only the working tree --------------------
#
# The first version used a linked worktree, which shares the source's git
# directory. The first review run through it proved the hole rather than
# asserting it: 'git config --local' inside the throwaway wrote to the source
# repo's config, and 'git update-ref' moved the source's branch.

git_in( $repo, 'config', '--local', 'review.escape', 'untouched' );
system( $tool, $repo, 'sh', '-c', 'git config --local review.escape ESCAPED' );
my $escaped = `git -C '$repo' config --local --get review.escape`;
chomp $escaped;
is( $escaped, 'untouched',
    "the reviewer's git config writes stay inside the throwaway" );

my $head_before = `git -C '$repo' rev-parse HEAD`;
chomp $head_before;
write_file( $doc, "committed line\nA PARAGRAPH WRITTEN WHILE THE REVIEW RAN\nand more\n" );
git_in( $repo, 'add', '-A' );
git_in( $repo, 'commit', '--quiet', '-m', 'second' );
my $head_two = `git -C '$repo' rev-parse HEAD`;
chomp $head_two;
system( $tool, $repo, 'sh', '-c', 'git update-ref refs/heads/master HEAD~1 2>/dev/null || true' );
my $head_after = `git -C '$repo' rev-parse HEAD`;
chomp $head_after;
is( $head_after, $head_two, "and its ref writes cannot rewind the live repository" );
isnt( $head_two, $head_before, 'the two commits really are different, so the check above could have failed' );

# --- what is STAGED arrives staged -------------------------------------------
#
# Applying one combined diff reproduced the file contents and lost the index, so
# a reviewer asking what is staged was told nothing was.

write_file( $doc, "staged edit\n" );
git_in( $repo, 'add', $doc );
my $staged_seen = File::Spec->catfile( $tmp, 'staged.txt' );
system( $tool, $repo, 'sh', '-c', "git diff --cached --name-only > '$staged_seen'" );
like( read_file($staged_seen), qr/DOC\.md/,
    'a staged change arrives in the clone still staged, not merely present' );
git_in( $repo, 'reset', '--quiet', 'HEAD', $doc );

# --- an untracked symlink stays a symlink ------------------------------------
#
# cp -p dereferences: a link became a copy of its target, and a dangling one
# made the tool fail before the review ran at all.

my $link = File::Spec->catfile( $repo, 'untracked-link' );
symlink 'DOC.md', $link or diag("symlink unsupported here: $!");
SKIP: {
    skip 'symlinks unsupported on this filesystem', 1 if !-l $link;
    my $kind = File::Spec->catfile( $tmp, 'kind.txt' );
    my $rc_link = system( $tool, $repo, 'sh', '-c', "test -L untracked-link && echo LINK > '$kind' || echo PLAIN > '$kind'" );
    is( read_file($kind), "LINK\n", 'an untracked symlink is copied as a symlink, not flattened into its target' );
}
unlink $link;

# --- and it refuses what it cannot isolate -----------------------------------
#
# A symlink pointing out of the tree would carry a write straight back out, so
# the tool says so instead of offering isolation it does not have.

my $escape = File::Spec->catfile( $repo, 'escape-link' );
symlink File::Spec->catfile( $tmp, 'outside.txt' ), $escape;
SKIP: {
    skip 'symlinks unsupported on this filesystem', 1 if !-l $escape;
    my $refused = system( $tool, $repo, 'true' );
    isnt( $refused, 0, 'a symlink pointing outside the tree is refused rather than silently followed' );
}
unlink $escape;

# --- and it does not leave the throwaway behind ------------------------------
#
# Asserted from an empty scratch directory rather than from 'git worktree list':
# a clone is never registered as a worktree, so that check would now pass
# whatever the tool did with its temporary files.

my $tmpdir = File::Spec->catdir( $tmp, 'scratch' );
make_path($tmpdir);
{
    local $ENV{TMPDIR} = $tmpdir;
    system( $tool, $repo, 'sh', '-c', 'exit 3' );
}
opendir my $dh, $tmpdir or die $!;
my @left = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
closedir $dh;
is( scalar @left, 0, 'the throwaway is removed even when the review exits non-zero' )
  or diag( 'left behind: ' . join ', ', @left );
}

done_testing();

__END__

=head1 NAME

t/414-a-review-that-edits-what-it-reviews.t - the mandated review must not be
able to revert the work it is reviewing

=head1 DESCRIPTION

C<REQ-030> on the verify column template runs a reviewing agent against this
checkout for every card. One of them ran C<git checkout --> on two files that
held uncommitted documentation and reverted them; the loss was silent, because
afterwards C<git status> showed the files unmodified.

The test holds three things at once, and the middle one is the reason the
obvious fix is wrong: the reviewer must SEE the uncommitted work, must see
enough of the tree to run something, and must not be able to destroy either.
Isolation that hides the change would satisfy the third by defeating the first.

=cut
