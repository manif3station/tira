package Tira::CLI::Release;

# The one question tira.release.record asks of the machine rather than of the
# board: which version did each card's own commit ship in? (TKT-1207.)
#
# It lives here, not in Tira, because the engine invokes no shell and no
# external process - the guarantee that lets it be trusted inside another tool.
# The CLI layer looks, and hands the answer over as a plain value, which is the
# same split tira.police uses for its facts.

use strict;
use warnings;

use Tira::CLI::Serve ();

# For each ref a release.record names, the version in .env at the OLDEST commit
# whose subject begins "REF:" - the commit that introduced the fix, which is
# where this project's convention bumps VERSION - as
# { REF => { commit => SHA, version => VERSION } }. The engine compares
# --fix-version with it and refuses a difference.
#
# A ref is left out, so there is nothing to compare, when the project is not a
# git repository or is a shallow clone, no commit names the ref (a review card
# has none), or the commit has no .env or no VERSION line. A program that is
# not installed is the same: Tira::CLI::Serve::_reading answers with nothing
# rather than failing.
sub commit_versions {
    my ( $tira, $args ) = @_;
    my $root = $tira->discover_project( project => $args->{project}, start => $args->{start} );
    return {} if !Tira::CLI::Serve::_is_repository($root);

    # A shallow clone cannot say which commit is the OLDEST one for a ref - the
    # oldest it can see is merely the oldest it kept - so comparing against it
    # could refuse a legitimate release. No fact is better than a wrong one.
    my ($shallow) = @{ Tira::CLI::Serve::_reading( 'git', '-C', $root, 'rev-parse', '--is-shallow-repository' ) };
    return {} if ( $shallow // '' ) eq 'true';

    my @refs = @{ $args->{refs} // [] } ? @{ $args->{refs} } : ( $args->{ref} );
    my %found;
    for my $ref ( grep { defined && length } @refs ) {

        # --grep narrows a long history cheaply; the exact "REF:" subject test
        # is what keeps TKT-12 from claiming TKT-120's commits.
        my $lines = Tira::CLI::Serve::_reading( 'git', '-C', $root, 'log', '--format=%H%x09%s', '--fixed-strings', "--grep=$ref:" );
        my @own   = grep { $_->[1] =~ /\A\Q$ref\E:/ } map { [ split /\t/, $_, 2 ] } @{$lines};
        next if !@own;

        # git log lists newest first, so the card's first commit is the last.
        my $commit = $own[-1][0];
        next if !@{ Tira::CLI::Serve::_reading( 'git', '-C', $root, 'ls-tree', '--name-only', $commit, '--', '.env' ) };
        my ($version) = map { /\AVERSION=(\S+)/ ? $1 : () } @{ Tira::CLI::Serve::_reading( 'git', '-C', $root, 'show', "$commit:./.env" ) };
        $found{$ref} = { commit => $commit, version => $version } if defined $version;
    }
    return \%found;
}

1;
