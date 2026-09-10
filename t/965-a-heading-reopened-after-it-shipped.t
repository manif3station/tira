#!/usr/bin/env perl

# TKT-965. Seven cards' Changes entries sat under "5.83" in this repo's own
# file, a version already pushed AND installed - committed, never pushed,
# and nothing in the working tree caught it: t/03-metadata.t compares .env,
# our $VERSION and the newest Changes heading only to EACH OTHER, never to
# what origin last actually shipped. All three agreed the whole time the
# drift grew, so the suite stayed green throughout.
#
# TKT-936's own commit reproduced the identical shape live, in this same
# session, before this fix existed: real code landed under the
# already-released 5.92 heading, self-consistent and wrong.
#
# tools/changes-not-reopened is the fix: it compares the LOCAL Changes
# section for EVERY version origin's own file already names against
# origin's OWN text under that same heading, not only the newest local one -
# checking only the newest was the first version's own bug, Codex-caught,
# since a fresh legitimate heading routinely sits above an already-released
# one a top-only check would never look under. Origin has shipped each of
# those versions, so its own text under each is the ceiling - any local
# difference under the same heading is work an install will never see,
# since an install compares .env, not word count.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $TOOL = File::Spec->rel2abs('tools/changes-not-reopened');
ok( -x $TOOL, 'tools/changes-not-reopened exists and is executable' ) or BAIL_OUT('nothing to test');

my $tmp  = tempdir( CLEANUP => 1 );
my $repo = File::Spec->catdir( $tmp, 'repo' );
mkdir $repo or die "mkdir $repo: $!";

sub run_git { system( 'git', '-C', $repo, @_ ) == 0 or die "git @_ failed"; }
sub write_changes {
    my ($text) = @_;
    open my $fh, '>', File::Spec->catfile( $repo, 'Changes' ) or die $!;
    print {$fh} $text;
    close $fh;
}
sub run_tool {
    my (@args) = @_;
    my $out = `@{[ $TOOL ]} @args 2>&1`;
    return { out => $out // '', status => $? >> 8 };
}

run_git( 'init', '--quiet' );
run_git( 'config', 'user.email', 'test@example.com' );
run_git( 'config', 'user.name',  'Test' );

# --- origin: a released 5.83 with one real entry ----------------------

write_changes( <<'END' );
Revision history for Tira

5.83  2026-09-05
    - TKT-946: the one entry that genuinely shipped in 5.83.
END
run_git( 'add', 'Changes' );
run_git( 'commit', '--quiet', '-m', 'release 5.83' );
run_git( 'branch', '--quiet', 'origin/HEAD' );

my $orig_cwd;
require Cwd;
$orig_cwd = Cwd::getcwd();
chdir $repo or die $!;

# --- the bug: a later, unpushed commit adds entries under the SAME 5.83 heading -----

write_changes( <<'END' );
Revision history for Tira

5.83  2026-09-05
    - TKT-946: the one entry that genuinely shipped in 5.83.
    - TKT-627: committed after the release, never pushed, landed under the
      already-shipped heading anyway.
END
run_git( 'commit', '--quiet', '-a', '-m', 'reopen 5.83 by mistake' );

my $red = run_tool( '--base', 'origin/HEAD' );
isnt( $red->{status}, 0, 'refuses when the newest local heading names an already-released version whose own section has grown past what origin shipped' );
like( $red->{out}, qr/5\.83/, 'names the version' );
like( $red->{out}, qr/bump-version/i, 'and points at the fix' );

# --- the corrected tree: the new entry moved to its own, unreleased heading -----

write_changes( <<'END' );
Revision history for Tira

5.84  2026-09-06
    - TKT-627: moved to its own heading and the version actually bumped.

5.83  2026-09-05
    - TKT-946: the one entry that genuinely shipped in 5.83.
END
run_git( 'commit', '--quiet', '-a', '-m', 'fix: move TKT-627 to 5.84' );

my $green = run_tool( '--base', 'origin/HEAD' );
is( $green->{status}, 0, 'passes once the new entry moves to a version origin has not shipped, and 5.83 matches origin exactly again' );

# Captured here, before 5.85 is committed below - this is the commit where
# origin genuinely ships 5.84 and nothing newer, which the buried-heading
# scenario further down needs to be literally true.
my $shipped_5_84_sha = `git -C $repo rev-parse HEAD`;
chomp $shipped_5_84_sha;

# --- a version origin has not shipped at all is unwatched, the ordinary case -----

write_changes( <<'END' );
Revision history for Tira

5.85  2026-09-07
    - TKT-1000: brand new work, a version origin has never heard of.

5.84  2026-09-06
    - TKT-627: moved to its own heading and the version actually bumped.

5.83  2026-09-05
    - TKT-946: the one entry that genuinely shipped in 5.83.
END
run_git( 'commit', '--quiet', '-a', '-m', 'more work, still unreleased' );

my $ordinary = run_tool( '--base', 'origin/HEAD' );
is( $ordinary->{status}, 0, 'a heading origin has never shipped is the normal in-progress state, not a violation' );

# --- an OLDER already-released heading reopened while the NEWEST is genuinely new -----
#
# The exact shape of the original bug, and the one the first version of this
# tool (Codex-caught) missed entirely: checking only the newest local heading
# passes here, because 5.85 really is unreleased - the check never looks
# under it to see that 5.83, which origin already shipped, quietly grew.

# Pointed at the commit captured above, not at HEAD (which by now also
# carries the unreleased 5.85 committed just above) - origin genuinely
# ships only up to 5.84, so the newest LOCAL heading below really is one
# origin has never heard of, exactly as the scenario claims.
run_git( 'branch', '--quiet', '-f', 'origin/HEAD', $shipped_5_84_sha );

write_changes( <<'END' );
Revision history for Tira

5.85  2026-09-07
    - TKT-1000: brand new work, a version origin has never heard of.

5.84  2026-09-06
    - TKT-627: moved to its own heading and the version actually bumped.

5.83  2026-09-05
    - TKT-946: the one entry that genuinely shipped in 5.83.
    - TKT-2000: reopened, quietly, underneath a legitimately new heading.
END
run_git( 'commit', '--quiet', '-a', '-m', 'reopen 5.83 again, under a real new heading' );

my $buried = run_tool( '--base', 'origin/HEAD' );
isnt( $buried->{status}, 0, 'refuses an older already-released heading reopened even while the newest local heading is genuinely unreleased' );
like( $buried->{out}, qr/5\.83/, 'names the older version, not the newer one that is actually fine' );

# --- no origin ref at all: nothing to compare against, not a fault --------

my $no_origin = run_tool( '--base', 'refs/does-not-exist' );
is( $no_origin->{status}, 0, 'no base ref to compare against is not treated as a violation - there is nothing released yet' );

chdir $orig_cwd or die $!;

done_testing();

__END__

=head1 NAME

t/965-a-heading-reopened-after-it-shipped.t - a Changes heading whose own
version already shipped must not grow past what origin actually sent out

=head1 DESCRIPTION

TKT-965: seven cards' Changes entries sat under "5.83" in this repository's
own file, a version already pushed AND installed. Each was committed, none
was ever pushed, and nothing in the working tree caught it - t/03-metadata.t
compares .env, C<our $VERSION> and the newest Changes heading only to EACH
OTHER, so as long as all three agreed - which they did the entire time the
drift grew - the suite stayed green.

C<tools/changes-not-reopened> reads origin's own copy of Changes and the
local copy's section for EVERY version origin's own file already names,
not only the newest local heading - checking only the newest was the first
version's own bug, since a fresh legitimate heading routinely sits above
an already-released one a top-only check would never look under. Origin
has shipped each of those versions, so its own text under each is the
ceiling: any local difference under the same heading is refused. A heading
origin has not shipped yet is unwatched - that is every release's normal,
in-progress state - and no base ref at all (nothing released yet) is not a
fault either.

=cut
