#!/usr/bin/env perl
# TKT-1029, Q-174, his own answer: "a commit whose only diff is
# .env/Changes/VERSION never needs to name a card at all - it's release
# bookkeeping, not a code change." Reported live pushing a 9-card batch,
# 2026-09-09: every real ticket in the batch had already reached push, so
# the version-bump commit that fixes pre-push's own VERSION-changed
# refusal had no card it could legitimately name - naming an unrelated
# in-progress card instead swept that card into pre-push's card-holes
# check and wrongly blocked the release over its own incompleteness.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $tmp  = tempdir( CLEANUP => 1 );
my $repo = File::Spec->catdir( $tmp, 'repo' );
mkdir $repo or die "mkdir $repo: $!";
system( 'git', '-C', $repo, 'init', '--quiet' ) == 0 or die 'git init failed';
system( 'git', '-C', $repo, 'config', 'user.email', 'a@b.c' );
system( 'git', '-C', $repo, 'config', 'user.name',  'Test' );

# The hook finds its own project root two directories up from itself
# (tools/hooks/commit-msg -> project root), so it has to live at that same
# relative path under the test repo - t/1017's own precedent.
my $real_hook = File::Spec->rel2abs( File::Spec->catfile( qw(.developer-dashboard cli hooks commit-msg) ) );
mkdir File::Spec->catdir( $repo, 'tools' );
mkdir File::Spec->catdir( $repo, 'tools', 'hooks' );
my $hook = File::Spec->catfile( $repo, 'tools', 'hooks', 'commit-msg' );
{
    open my $in,  '<', $real_hook or die $!;
    open my $out, '>', $hook      or die $!;
    local $/;
    print {$out} <$in>;
}
chmod 0755, $hook;

mkdir File::Spec->catdir( $repo, 'lib' );

sub write_file {
    my ( $rel, $content ) = @_;
    my $path = File::Spec->catfile( $repo, split m{/}, $rel );
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub run_hook {
    my ($subject) = @_;
    my $msg_file = File::Spec->catfile( $tmp, 'msg.txt' );
    open my $mfh, '>', $msg_file or die $!;
    print {$mfh} "$subject\n";
    close $mfh;
    my $out = `cd '$repo' && '$hook' '$msg_file' 2>&1`;
    return ( $?, $out );
}

# --- baseline commit, so later ones have a HEAD to diff against -------------

write_file( 'lib/Tira.pm', "package Tira;\nour \$VERSION = '1.00';\n1;\n" );
write_file( '.env',        "VERSION=1.00\n" );
write_file( 'Changes',     "Revision history for Tira\n\n1.00  2026-01-01\n    - first\n" );
system( 'git', '-C', $repo, 'add', '.' ) == 0 or die 'git add failed';
system( 'git', '-C', $repo, 'commit', '--quiet', '--no-verify', '-m', 'TKT-9000: baseline' ) == 0
  or die 'git commit failed';

# --- a pure release-bookkeeping commit needs no card at all -----------------

write_file( 'lib/Tira.pm', "package Tira;\nour \$VERSION = '1.01';\n1;\n" );
write_file( '.env',        "VERSION=1.01\n" );
write_file( 'Changes',     "Revision history for Tira\n\n1.01  2026-01-02\n    - release\n\n1.00  2026-01-01\n    - first\n" );
system( 'git', '-C', $repo, 'add', '.env', 'Changes', 'lib/Tira.pm' ) == 0 or die 'git add failed';

my ( $status, $out ) = run_hook('Release 1.01');
is( $status, 0, 'a commit touching only .env/Changes/the VERSION line needs no card at all' )
  or diag($out);

# --- the same shape, but lib/Tira.pm changes MORE than the VERSION line -----
#
# Still requires a card - this is a real code change riding along with a
# version bump, not release bookkeeping alone.

write_file( 'lib/Tira.pm', "package Tira;\nour \$VERSION = '1.02';\nsub new { return bless {}, shift }\n1;\n" );
write_file( '.env',        "VERSION=1.02\n" );
write_file( 'Changes',     "Revision history for Tira\n\n1.02  2026-01-03\n    - added new()\n\n1.01  2026-01-02\n    - release\n\n1.00  2026-01-01\n    - first\n" );
system( 'git', '-C', $repo, 'add', '.env', 'Changes', 'lib/Tira.pm' ) == 0 or die 'git add failed';

( $status, $out ) = run_hook('Release 1.02 with a real change');
isnt( $status, 0, 'a real code change riding beside the version bump still needs a card' );
like( $out, qr/name the card/, 'with the ordinary no-card refusal' );

system( 'git', '-C', $repo, 'reset', '--quiet' );

# --- lib/Tira.pm's VERSION line alone, with NO .env change - not the -------
# exemption, just an unusual code commit that still needs a card.

write_file( 'lib/Tira.pm', "package Tira;\nour \$VERSION = '1.03';\n1;\n" );
system( 'git', '-C', $repo, 'add', 'lib/Tira.pm' ) == 0 or die 'git add failed';

( $status, $out ) = run_hook('A version bump with nothing else touched');
isnt( $status, 0, 'the VERSION line alone, with no .env change, is not the release exemption' );
like( $out, qr/name the card/, 'and still needs a card named' );

system( 'git', '-C', $repo, 'reset', '--quiet' );

# --- CODEX REVIEW: a line smuggling code past the version-line strip -------
#
# The first draft stripped any WHOLE LINE beginning with the version
# assignment, so a line shaped like a version bump plus a trailing
# statement on the same line would vanish from the comparison undetected.

write_file( 'lib/Tira.pm', "package Tira;\nour \$VERSION = '1.04'; sub sneaky { 1 }\n1;\n" );
write_file( '.env',        "VERSION=1.04\n" );
write_file( 'Changes',     "Revision history for Tira\n\n1.04  2026-01-04\n    - release\n\n1.00  2026-01-01\n    - first\n" );
system( 'git', '-C', $repo, 'add', '.env', 'Changes', 'lib/Tira.pm' ) == 0 or die 'git add failed';

( $status, $out ) = run_hook('Release 1.04 with a smuggled statement');
isnt( $status, 0, 'a statement riding on the same line as the version assignment is not exempted' );
like( $out, qr/name the card/, 'still needs a card named' );

system( 'git', '-C', $repo, 'reset', '--quiet' );

# --- CODEX REVIEW: deleting .env must not count as "saw .env" --------------
#
# git diff --cached --name-only answers the same for a deleted .env as a
# modified one - a commit that DELETES .env while only touching Changes
# must not be read as a release bump that touched .env.

unlink File::Spec->catfile( $repo, '.env' ) or die $!;
write_file( 'Changes', "Revision history for Tira\n\n1.05  2026-01-05\n    - oops\n\n1.00  2026-01-01\n    - first\n" );
system( 'git', '-C', $repo, 'add', '-A' ) == 0 or die 'git add failed';

( $status, $out ) = run_hook('Deleted .env, only touched Changes');
isnt( $status, 0, 'deleting .env is not the same as bumping it - still needs a card' );
like( $out, qr/name the card/, 'with the ordinary no-card refusal' );

done_testing();

__END__

=head1 NAME

1029-a-commit-that-outlived-its-card.t - a release-bookkeeping commit needs no card

=head1 DESCRIPTION

TKT-1029. Once every ticket in a batch has already reached C<push>, the
version-bump commit that satisfies pre-push's own "VERSION did not change"
refusal has no card left it can legitimately name - naming an unrelated
in-progress card instead swept that card into pre-push's card-holes check
and wrongly blocked the release. Michael's own answer (Q-174): exempt a
commit whose only diff is C<.env>/C<Changes>/the C<$VERSION> line in
C<lib/Tira.pm> from the commit-msg hook's "name a card" requirement
entirely - it is release bookkeeping, not a code change any card need
claim. A real code change riding alongside the bump, or a VERSION-only
change with no C<.env> update, still needs a card as before.

=cut
