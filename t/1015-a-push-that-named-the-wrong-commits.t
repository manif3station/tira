#!/usr/bin/env perl
# tools/hooks/pre-push always checks local HEAD's own commit range, ignoring
# which ref/sha is actually being pushed.
#
# TKT-1015. Git passes the real <local ref> <local sha1> <remote ref>
# <remote sha1> to a pre-push hook on stdin, one line per ref being pushed -
# and the hook reads none of it, computing "the cards this push is about"
# from "origin/$branch..HEAD" regardless. Reproduced live: pushing an older
# local sha (holding back a later, not-yet-reviewed commit at HEAD) still
# named the held-back commit's own card, and refused for a reason that had
# nothing to do with what was actually being pushed.
#
# THE EXTRACTED BLOCK, NOT A PARAPHRASE: the full hook shells out to `d2`
# for the board backup step, which this test environment does not have -
# so the exact "about" computation lines are pulled out of the real file
# and run in isolation, the same technique t/969 uses for tools/gate-run's
# own embedded script, rather than re-typing the logic somewhere a second
# copy could drift from what actually ships.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $root = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, '..' ) );

# A HOME OF ITS OWN, not the ambient one. Cloning and committing needs a
# user identity and, since git 2.35.2, an explicit "safe.directory" for a
# repository this process does not itself own - a plain container run (no
# prior manual "git config --global") has neither, and this test failed
# exactly that way the first time it ran inside the ordinary full-suite
# invocation rather than a manually-configured shell. A scratch HOME with
# its own .gitconfig is both the fix and the more hermetic choice: nothing
# here touches whatever global git config the container or a real
# developer's machine already carries.
my $home = File::Temp->newdir;
$ENV{HOME} = "$home";
open my $gitconfig, '>', File::Spec->catfile( "$home", '.gitconfig' ) or die $!;
print {$gitconfig} "[user]\n\tname = Test\n\temail = t\@t.test\n[safe]\n\tdirectory = *\n";
close $gitconfig;

sub run { my (@cmd) = @_; my $out = `@cmd 2>&1`; return ( $?, $out ); }

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

# --- extract the real "about" computation, unedited -------------------------

my $hook = slurp('tools/hooks/pre-push');
my ($stdin_block) = $hook =~ /^(pushed_sha="HEAD"\n(?:.*\n)*?fi\n)/m;
my ($about_block)  = $hook =~ /^(about=""\n(?:.*\n)*?fi\n)/m;
ok( defined $stdin_block && defined $about_block,
    'the stdin-reading and about= computation blocks were found in the real hook, to extract rather than retype' )
  or BAIL_OUT('the hook changed shape - update this extraction, not the assertion below it');

# --- a throwaway clone, the same pattern tools/prove-the-gate's own -----
# version_probe uses: origin/<branch> in the clone genuinely points back
# at this repository.

my $tmp = tempdir( CLEANUP => 1 );
my $clone = File::Spec->catdir( $tmp, 'clone' );
my ( $clone_status, $clone_out ) = run( 'git', 'clone', '--quiet', '--no-hardlinks', $root, $clone );
is( $clone_status, 0, 'cloned the real repository' ) or diag($clone_out);

run("cd $clone && git config user.email t\@t.test && git config user.name Test");
( undef, my $branch ) = run("cd $clone && git rev-parse --abbrev-ref HEAD");
chomp $branch;

# Two commits, each naming a distinct fake card - "old" is the one being
# pushed, "new" is held back at HEAD, not yet reviewed.
run("cd $clone && echo old >> README.md && git add README.md && git commit --quiet -m 'TKT-9001: old, reviewed'");
( undef, my $old_sha ) = run("cd $clone && git rev-parse HEAD");
chomp $old_sha;
run("cd $clone && echo new >> README.md && git add README.md && git commit --quiet -m 'TKT-9002: new, not yet reviewed'");

# A standalone script: the real branch= line from the hook, the extracted
# about= block verbatim, then a print of what it resolved to - run against
# the crafted stdin a pre-push hook would actually receive for this push.
my $script = File::Spec->catfile( $tmp, 'about.sh' );
open my $sh, '>', $script or die $!;
print {$sh} "#!/usr/bin/env bash\nset -euo pipefail\ncd '$clone'\n";
print {$sh} "branch=\"\$(git rev-parse --abbrev-ref HEAD)\"\n";
print {$sh} $stdin_block;
print {$sh} $about_block;
print {$sh} "printf '%s' \"\$about\"\n";
close $sh;
chmod 0755, $script;

my $remote_sha = '0' x 40;
my $stdin_line = "refs/heads/pushed $old_sha refs/heads/$branch $remote_sha\n";

open my $to_script, '|-', "$script > '$tmp/about.out' 2>'$tmp/about.err'" or die $!;
print {$to_script} $stdin_line;
close $to_script;

my $about = slurp("$tmp/about.out");

like( $about, qr/TKT-9001/, "the pushed (old) commit's card is named" );
unlike( $about, qr/TKT-9002/, "the held-back (new) commit's card is NOT named" )
  or diag("about resolved to: '$about' - the bug this card is about: HEAD leaked into the range instead of the pushed sha");

# --- a branch DELETION names no card at all, not HEAD's -------------------
#
# The all-zero local sha means no commit is being pushed - falling back to
# HEAD here would derive "about" from whatever local commits happen to be
# lying around, unrelated to a deletion.

my $zero = '0' x 40;
my $delete_stdin = "refs/heads/pushed $zero refs/heads/$branch $remote_sha\n";
open my $to_delete_script, '|-', "$script > '$tmp/delete.out' 2>'$tmp/delete.err'" or die $!;
print {$to_delete_script} $delete_stdin;
close $to_delete_script;
my $delete_about = slurp("$tmp/delete.out");

is( $delete_about, '', 'a branch deletion (all-zero local sha) names no card at all, not HEAD\'s' )
  or diag("about resolved to: '$delete_about' for a deletion - HEAD leaked in where there is no commit range at all");

done_testing();

__END__

=head1 NAME

1015-a-push-that-named-the-wrong-commits.t - the pre-push hook's "about"
computation names which commit is actually pushed, not just HEAD

=head1 WHY

TKT-1015. The hook computed "the cards this push is about" from
"origin/$branch..HEAD", ignoring the local ref/sha git actually passes on
stdin - so a partial push (holding back a not-yet-reviewed commit at HEAD)
still named that commit's own card and refused for an unrelated reason.

=head1 WHAT IS ASSERTED

That the hook's own about= computation, extracted verbatim rather than
retyped, names only the pushed commit's card when a synthetic pre-push
stdin line names an older local sha than HEAD - not the commit still
sitting at HEAD.

=cut
